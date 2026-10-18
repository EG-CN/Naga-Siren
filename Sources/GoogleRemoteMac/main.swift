import SwiftUI
import CoreBluetooth
import os

@MainActor
final class RemoteProbe: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    let capture = AudioCapture()
    let mappings=MappingStore()
    lazy var buttons:RemoteButtons = {let value=RemoteButtons(mappings);value.pauseVoice = { [weak self] in self?.capture.enableAutomatic(false) };return value}()
    @Published var status = "点击扫描，然后选择你的谷歌遥控器"
    @Published var devices: [CBPeripheral] = []
    @Published var events: [String] = []
    @Published var packets = 0
    @Published var bytes = 0
    @Published var connected = false
    @Published var scanning = false
    @Published var voiceReady = false
    private var remembered: UUID?
    private var autoReconnect = true
    private var sleepObservers:[NSObjectProtocol]=[]
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = 3
    override init() {
        super.init()
        DiagnosticLog.record("app.initialized")
        AppLifecycle.capture = capture
        AppLifecycle.cleanup = { [weak self] in self?.buttons.stop();self?.stop() }
        capture.sendDeviceCommand = { [weak self] data in
            guard let self,let selected=self.selected,let tx=self.tx,self.voiceReady else{return}
            selected.writeValue(data,for:tx,type:tx.properties.contains(.write) ? .withResponse:.withoutResponse)
        }
        capture.useDoubao = true
        if AppLifecycle.hasFinishedLaunching {capture.enableAutomatic(true)}
        let notifications=NSWorkspace.shared.notificationCenter
        sleepObservers.append(notifications.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self]_ in
            MainActor.assumeIsolated{self?.capture.suspendForSleep()}
        })
        sleepObservers.append(notifications.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self]_ in
            MainActor.assumeIsolated{
                guard let self else{return};self.capture.resumeAfterSleep()
                if self.autoReconnect && !self.connected {self.resume()}
            }
        })
        Task { @MainActor [weak self] in self?.resume() }
    }
    private func retry(_ message: String) {
        resetConnection()
        status = message + "，等待遥控器唤醒后自动重连"
        guard autoReconnect else { return }
        retryTimer?.invalidate()
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.autoReconnect else { return }; self.resume() }
        }
    }
    private var central: CBCentralManager!
    private var selected: CBPeripheral?
    private var tx: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var control: CBCharacteristic?
    private var timeout: Timer?
    private var subscriptions = Set<String>()
    private var negotiating = false
    private var capsTimer: Timer?
    private var scanRequested = false
    private let serviceID = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private let txID = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private let audioID = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private let controlID = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    func log(_ message: String) { events.append(message); if events.count > 160 { events.removeFirst(events.count - 160) } }
    func resume() {
        remembered = UserDefaults.standard.string(forKey: "remoteID").flatMap(UUID.init(uuidString:))
        scan()
    }
    func scan() {
        autoReconnect = true; retryTimer?.invalidate(); resetConnection(); devices = []; scanRequested = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central.state == .poweredOn { beginScan() }
        else { status = "等待系统蓝牙就绪" }
    }
    private func beginScan() {
        guard central.state == .poweredOn else { status = "请开启蓝牙并允许本应用访问蓝牙"; return }
        scanRequested = false; scanning = true; status = "扫描中，请唤醒遥控器；首次使用可先在系统蓝牙中配对"
        let existing = central.retrieveConnectedPeripherals(withServices: [serviceID, CBUUID(string: "1812"), CBUUID(string: "180F")])
        for peripheral in existing {
            let name = (peripheral.name ?? "").lowercased()
            if name.contains("chromecast") || name.contains("google") {
                if !devices.contains(where: { $0.identifier == peripheral.identifier }) { devices.append(peripheral) }
            }
        }
        log("从系统已连接设备中找到 \(devices.count) 个谷歌遥控器候选")
        if let remembered {
            let known = central.retrievePeripherals(withIdentifiers: [remembered])
            if let peripheral = known.first {
                devices = [peripheral]; self.remembered = nil; connect(peripheral); return
            }
        }
        central.scanForPeripherals(withServices: nil)
        log("正在补充扫描；发现设备后需点击它旁边的连接按钮")
        timeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }
                self.central.stopScan(); self.scanning = false
                if self.autoReconnect, self.remembered != nil { self.retry("暂未发现上次遥控器") }
                else { self.status = "请先连接一次遥控器，后续启动会自动连接" } }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { if scanRequested { beginScan() } }
        else {
            resetConnection(); scanRequested = autoReconnect
            status = central.state == .unauthorized ? "蓝牙访问未授权，请在系统设置中允许" : "等待系统蓝牙开启"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().contains("chromecast") || name.lowercased().contains("google") else { return }
        if !devices.contains(where: { $0.identifier == peripheral.identifier }) { devices.append(peripheral); log("发现谷歌遥控器候选") }
        if peripheral.identifier == remembered { remembered = nil; connect(peripheral) }
    }
    func connect(_ peripheral: CBPeripheral) {
        autoReconnect = true; retryTimer?.invalidate(); resetConnection(); selected = peripheral; peripheral.delegate = self; packets = 0; bytes = 0
        status = "正在连接 \(peripheral.name ?? "遥控器")"; log("用户已选择设备，开始连接"); central.connect(peripheral)
        timeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, !self.connected else { return }; self.retry("连接暂未完成") }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === selected else { central.cancelPeripheralConnection(peripheral); return }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "remoteID"); retryDelay = 3; timeout?.invalidate(); log("应用蓝牙连接成功"); connected = true; status = "已连接，正在发现语音服务"; peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected else { return }; retry("连接失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected else { return }; retry("遥控器已断开")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === selected else { return }
        guard error == nil else { retry("服务发现失败"); return }
        for service in peripheral.services ?? [] {
            log("发现服务：\(service.uuid.uuidString)")
            if service.uuid == serviceID || service.uuid == CBUUID(string: "1812") { peripheral.discoverCharacteristics(nil, for: service) }
        }
        if !(peripheral.services ?? []).contains(where: { $0.uuid == serviceID }) { status = "系统未暴露 ATVV 语音服务；需进一步验证兼容性" }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === selected else { return }
        guard error == nil else { log("特征发现失败：\(service.uuid)"); return }
        for c in service.characteristics ?? [] {
            log("发现特征：\(c.uuid.uuidString)")
            if c.uuid == txID { tx = c }
            if c.uuid == audioID { audio = c }
            if c.uuid == controlID { control = c }
            if c.uuid == audioID || c.uuid == controlID || (service.uuid == CBUUID(string: "1812") && c.uuid == CBUUID(string: "2A4D")) {
                if c.properties.contains(.notify) || c.properties.contains(.indicate) { peripheral.setNotifyValue(true, for: c) }
            }
        }
        negotiateIfReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected else { return }
        if error != nil { log("订阅失败：\(characteristic.uuid)"); return }
        if characteristic.isNotifying { subscriptions.insert(characteristic.uuid.uuidString); log("已订阅：\(characteristic.uuid)") }
        negotiateIfReady()
    }
    private func negotiateIfReady() {
        guard !negotiating, let selected, let tx, audio != nil, control != nil,
              subscriptions.contains(audioID.uuidString), subscriptions.contains(controlID.uuidString) else { return }
        guard tx.properties.contains(.write) || tx.properties.contains(.writeWithoutResponse) else { status = "语音控制特征不可写"; return }
        negotiating = true; status = "正在协商语音能力"
        selected.writeValue(Data([0x0a,1,0,0,2,3]), for: tx, type: tx.properties.contains(.write) ? .withResponse : .withoutResponse)
        capsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, !self.voiceReady else { return }; self.retry("语音能力协商超时") }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected else { return }
        if error != nil { status = "语音控制写入失败"; log("能力请求未成功") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard peripheral === selected, error == nil, let data = c.value else { return }
        if c.uuid == audioID { packets += 1; bytes += data.count; if voiceReady { capture.audio(data) }; return }
        if c.uuid == controlID {
            let p = Array(data)
            if p.first == 0x0b {
                voiceReady = p.count == 9 && p[1] == 1 && p[2] == 0 && p[3] & 2 != 0 && p[4] == 3 && (1...512).contains(Int(p[5]) * 256 + Int(p[6]))
                if voiceReady { capture.frameSize = Int(p[5]) * 256 + Int(p[6]) }
                capsTimer?.invalidate(); status = voiceReady ? "语音能力已确认，请按住 Assistant 键说话并观察音频包数" : "收到能力响应，但格式暂不支持"
            }
            if voiceReady { capture.control(data) }
            log("语音控制：\(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        } else if c.service?.uuid == CBUUID(string: "1812") {
            // Log only the known Google 8-byte button layout, never arbitrary HID content.
            let p = Array(data)
            if p.count == 8 && p.dropFirst().allSatisfy({ $0 == 0 }) {
                let names: [UInt8:String] = [0:"松开",1:"电源",3:"上",4:"下",5:"左",6:"右",7:"确定",8:"静音",10:"首页",11:"返回",12:"音量加",13:"音量减",14:"YouTube",15:"Netflix",17:"输入源"]
                if let name = names[p[0]] { log("遥控器按键：\(name)") }
            }
        }
    }
    func stop() {
        autoReconnect = false; retryTimer?.invalidate(); resetConnection()
    }
    private func resetConnection() {
        capture.shutdown(); scanRequested = false; timeout?.invalidate(); capsTimer?.invalidate(); central?.stopScan()
        if let selected { selected.delegate = nil; central?.cancelPeripheralConnection(selected) }
        selected = nil; tx = nil; audio = nil; control = nil; subscriptions.removeAll(); negotiating = false
        connected = false; scanning = false; voiceReady = false
        status = "已停止"
    }
}

struct ContentView: View {
    @ObservedObject var probe: RemoteProbe
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("谷歌遥控器 · Mac 连接验证").font(.title2.bold())
            Text("豆包版 0.6 · 启动自动连接 · 遥控器传声给豆包输入法").foregroundStyle(.secondary)
            Text(probe.status).textSelection(.enabled)
            HStack {
                Button("查找已连接 / 扫描遥控器") { probe.scan() }.disabled(probe.scanning || probe.connected)
                Button("停止 / 断开") { probe.stop() }
                Spacer()
                Text("音频：\(probe.packets) 包 / \(probe.bytes) 字节").monospacedDigit()
            }
            ForEach(probe.devices, id: \.identifier) { device in
                HStack { Text(device.name ?? "Google Remote"); Text(probe.voiceReady ? "语音已就绪" : "连接后会记住此遥控器").font(.caption).foregroundStyle(.secondary); Spacer(); Button("连接") { probe.connect(device) }.disabled(probe.connected) }
            }
            AudioPanel(capture: probe.capture, available: probe.voiceReady)
            Text("接收状态").font(.headline)
            ScrollView { Text(probe.events.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .padding(10).clipShape(RoundedRectangle(cornerRadius: 8))
            Text("音频不落盘，最长 60 秒。豆包模式将声音送入豆包输入法，按豆包当前设置进行识别；Apple 模式仅本机识别。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 670, minHeight: 500)
        
    }
}
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    static var hasFinishedLaunching=false
    func applicationDidFinishLaunching(_ notification:Notification){
        Self.hasFinishedLaunching=true
        Logger(subsystem:"local.googleremote.macprobe",category:"app-startup").notice("应用启动完成，开始协调语音路由")
        Self.capture?.enableAutomatic(true)
    }
    static weak var capture: AudioCapture?
    static var cleanup: (() -> Void)?
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let capture = Self.capture else { return .terminateNow }
        terminationPending = true
        Task { @MainActor in
            let restored = await capture.prepareToQuit()
            var allowExit = restored
            if !restored {
                let alert = NSAlert()
                alert.messageText = "尚未恢复豆包的麦克风设置"
                alert.informativeText = "取消退出后可以重试。若仍然退出，豆包可能继续选择虚拟麦克风，需要手动改回内置麦克风。\n\n" + capture.routeStatus
                alert.alertStyle = .warning
                alert.addButton(withTitle: "取消退出")
                alert.addButton(withTitle: "仍然退出")
                allowExit = alert.runModal() == .alertSecondButtonReturn
            }
            if allowExit { Self.performCleanup() }
            self.terminationPending = false
            sender.reply(toApplicationShouldTerminate: allowExit)
        }
        return .terminateLater
    }
    private static func performCleanup() { let action = cleanup;cleanup = nil;action?() }
    func applicationWillTerminate(_ notification: Notification) { Self.performCleanup() }
}
@main
struct GoogleRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var probe = RemoteProbe()
    @ObservedObject private var preferences = Preferences.shared
    var body: some Scene {
        WindowGroup("小娜迦", id: "main") { NagaSettingsView(probe: probe,capture:probe.capture) }
        MenuBarExtra("小娜迦", systemImage: "water.waves",isInserted:Binding(get:{preferences.showMenu},set:{ value in
                guard preferences.showMenu != value else{return}
                Task { @MainActor in if preferences.showMenu != value { preferences.showMenu=value } }
            })) { NagaMenu(probe:probe,capture:probe.capture) }.menuBarExtraStyle(.window)
    }
}
struct DailyMenu: View {
    @ObservedObject var probe: RemoteProbe
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(probe.status)
        Button("打开窗口") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Button("连接上次遥控器") { probe.resume() }
        Button("暂停自动输入") { probe.capture.enableAutomatic(false) }
        Button("退出") { NSApplication.shared.terminate(nil) }
    }
}
