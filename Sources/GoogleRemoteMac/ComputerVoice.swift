import AppKit
import AVFoundation
import AudioToolbox
import os
@preconcurrency import ApplicationServices

@MainActor
final class ComputerVoice: ObservableObject {
    private let logger=Logger(subsystem:"local.googleremote.macprobe",category:"computer-voice")
    @Published var active = false
    @Published private(set) var draining = false
    @Published var level: Float = 0
    @Published var inputFrames = 0
    @Published var forwardedFrames = 0
    @Published var routeError = ""
    @Published private(set) var lastSession = "尚未开始电脑语音"
    private func report(_ message:String) { lastSession=message;logger.notice("\(message,privacy:.public)");changed?(message) }
    @Published private(set) var previewAvailable=false
    private var testSession=false
    private var toggleSession=false
    var toggleActive:Bool { active && toggleSession }
    var forcedToggleEnd:(()->Void)?
    private var preview:[Int16]=[]
    private var previewPlayer:AVAudioPlayer?
    private var driver:ComputerCaptureDriver?
    private var receiver: ComputerAudioReceiver?
    private let bridge = DoubaoBridge()
    private var generation=UUID()
    private var timer: Timer?
    var changed: ((String)->Void)?
    var startRefusal: (()->String?)?
    func start(force:Bool=false,toggle:Bool=false) {
        guard !active else { return }
        guard !draining else { report("上一段声音仍在传输，请稍候再开始");return }
        if !force, let reason=startRefusal?() { report("电脑语音未启动："+reason);return }
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { report("请在设置检查中允许麦克风访问，才能自动切换电脑声音"); return }
        do {
            previewPlayer?.stop();testSession=force;toggleSession=toggle;preview=[];previewAvailable=false
            let micUID=Preferences.shared.microphoneUID
            let inputs=AudioCatalog.devices(input:true)
            let chosen = micUID.isEmpty ? inputs.first(where: { $0.name.contains("MacBook") || $0.name.contains("内建") || $0.name.contains("Built-in") }) : inputs.first(where:{$0.uid==micUID})
            guard let chosen else { throw DoubaoBridge.BridgeError("电脑麦克风不可用，请在音频设置中选择") }
            guard chosen.id != (try DoubaoBridge.device()) else { throw DoubaoBridge.BridgeError("电脑麦克风不能与虚拟输出相同，避免音频反馈") }
            let devices=AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone,.external],mediaType:.audio,position:.unspecified).devices
            guard let microphone=devices.first(where:{$0.uniqueID==chosen.uid}) ?? devices.first(where:{$0.localizedName==chosen.name}) else { throw DoubaoBridge.BridgeError("系统录音接口未找到所选麦克风") }
            let session=AVCaptureSession()
            let input=try AVCaptureDeviceInput(device:microphone)
            guard session.canAddInput(input) else { throw DoubaoBridge.BridgeError("无法添加电脑麦克风") }
            session.addInput(input)
            let output=AVCaptureAudioDataOutput()
            output.audioSettings=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false]
            generation=UUID();let id=generation
            let receiver=ComputerAudioReceiver { [weak self] pcm in
                Task { @MainActor in
                    guard let self,self.generation==id,self.active else{return}
                    if self.testSession,self.preview.count<480000 {self.preview.append(contentsOf:pcm.prefix(480000-self.preview.count))}
                    self.inputFrames += pcm.count
                    self.forwardedFrames += pcm.count
                    let rms=sqrt(pcm.reduce(0.0){$0+pow(Double($1)/32768,2)}/Double(max(1,pcm.count)))
                    self.level=Float(min(1,rms*8));self.bridge.feed(pcm)
                }
            }
            output.setSampleBufferDelegate(receiver,queue:DispatchQueue(label:"naga.computer.audio"))
            guard session.canAddOutput(output) else { throw DoubaoBridge.BridgeError("无法创建电脑录音输出") }
            session.addOutput(output)
            do { try bridge.begin(sendKey:false) } catch { throw DoubaoBridge.BridgeError("虚拟音频转发启动失败：\(error.localizedDescription)") }
            bridge.finished = { [weak self] message in
                guard let self,self.generation==id else{return}
                self.cancel();self.report(message)
            }
            inputFrames=0;forwardedFrames=0;routeError=""
            let driver=ComputerCaptureDriver(session)
            self.driver=driver;self.receiver=receiver;active=true
            driver.start { [weak self] running in
                Task { @MainActor in
                    guard let self,self.generation==id,self.active else{return}
                    if !running {self.cancel();self.report("电脑录音通道启动失败");return}
                }
            }
            Feedback.shared.sound(start:true);report(toggle ? "电脑麦克风 → 豆包 · 再按一次快捷键结束":"电脑麦克风 → 豆包 · 松开快捷键结束")
            timer=Timer.scheduledTimer(withTimeInterval:Double(Preferences.shared.maximumSeconds),repeats:false) { [weak self] _ in MainActor.assumeIsolated { self?.stop(endExternal:true) } }
        } catch { cancel();report(error.localizedDescription) }
    }
    func stop(endExternal:Bool=false) {
        guard active else { return }
        if endExternal && !testSession {
            if toggleSession {forcedToggleEnd?()}
            else {DoubaoBridge.cancelExternalHold()}
        }
        Feedback.shared.sound(start:false)
        generation=UUID();let id=generation;timer?.invalidate();driver?.stop();driver=nil;receiver=nil;active=false;draining=true;level=0
        previewAvailable = testSession && !preview.isEmpty
        let received=inputFrames;let forwarded=forwardedFrames
        bridge.finished = { [weak self] message in
            guard let self,self.generation==id else{return}
            self.draining=false
            if message.contains("超时"){self.report(message);return}
            self.report(forwarded > 0 ? "电脑会话结束 · 采集 \(received) / 转发 \(forwarded) 样本" : "电脑会话没有有效音频 · 采集 \(received) / 转发 \(forwarded) 样本")
        }
        bridge.finish()
    }
    func playPreview(){
        guard !active,!preview.isEmpty else{return}
        do{previewPlayer=try AVAudioPlayer(data:waveData(preview));previewPlayer?.play();report("正在试听电脑麦克风测试（仅内存）")}
        catch{report("试听失败：\(error.localizedDescription)")}
    }
    func cancel(endExternal:Bool=true) {
        if endExternal && active && !testSession {
            if toggleSession {forcedToggleEnd?()}
            else {DoubaoBridge.cancelExternalHold()}
        }
        generation=UUID();timer?.invalidate()
        driver?.stop();driver=nil;receiver=nil;bridge.cancel();bridge.finished=nil;previewPlayer?.stop();preview=[];previewAvailable=false;active=false;draining=false;level=0
    }

}

// AVCaptureSession's blocking start/stop operations run exclusively on this queue.
// Configuration is finished before ownership is transferred to the driver.
private final class ComputerCaptureDriver:@unchecked Sendable {
    private let session:AVCaptureSession
    private let queue=DispatchQueue(label:"naga.computer.capture.lifecycle")
    init(_ session:AVCaptureSession){self.session=session}
    func start(_ completion:@escaping @Sendable (Bool)->Void){queue.async{self.session.startRunning();completion(self.session.isRunning)}}
    func stop(){queue.async{self.session.stopRunning()}}
}

private final class ComputerAudioReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let receive: @Sendable ([Int16])->Void
    init(receive:@escaping @Sendable ([Int16])->Void) { self.receive=receive }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        guard let block=CMSampleBufferGetDataBuffer(sampleBuffer) else{return}
        let length=CMBlockBufferGetDataLength(block)
        guard length>0,length%2==0 else{return}
        var pcm=[Int16](repeating:0,count:length/2)
        let status=pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:length,destination:$0.baseAddress!) }
        if status==kCMBlockBufferNoErr { receive(pcm) }
    }
}

@MainActor
final class VoiceKeyMonitor: ObservableObject {
    @Published private(set) var diagnostics=[String]()
    private var holdGate=VoiceHoldGate()
    private var sequence=0
    private var epoch=UUID()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var physicalTimer: Timer?
    @Published private(set) var healthSummary="尚未启动"
    private var callbackCount=0
    private var pollCount=0
    private var configuredCount=0
    private var toggleDown=false
    private var toggleOn=false
    var held: ((Bool)->Void)?
    var toggled: ((Bool)->Void)?
    var stopAll: (()->Void)?
    private let logger=Logger(subsystem:"local.googleremote.macprobe",category:"voice-listener")
    var active: Bool { CGPreflightListenEventAccess() && tap.map{CGEvent.tapIsEnabled(tap:$0)} == true }
    var permissionSummary: String { "监听授权：\(CGPreflightListenEventAccess() ? "允许":"未允许") · 端口：\(tap.map{CGEvent.tapIsEnabled(tap:$0)} == true ? "启用":"未启用") · \(healthSummary)" }
    private func note(_ text:String) {
        sequence += 1
        diagnostics.append("#\(sequence) "+Date().formatted(date:.omitted,time:.standard)+" "+text)
        logger.notice("配置键事件：\(text,privacy:.public)")
        if diagnostics.count>12 {diagnostics.removeFirst()}
    }
    func start() {
        // A non-nil port can already be invalid. Re-enabling that object cannot
        // recover listening; discard it so the normal creation path runs.
        if let tap {
            let sourceHealthy=source.map { CFRunLoopSourceIsValid($0) && CFRunLoopContainsSource(CFRunLoopGetMain(),$0,.commonModes) } ?? false
            if !CFMachPortIsValid(tap) || !sourceHealthy { logger.error("监听端口或运行循环源失效，重建");stop() }
            else {
                if !CGEvent.tapIsEnabled(tap:tap) { CGEvent.tapEnable(tap:tap,enable:true) }
                if !CGEvent.tapIsEnabled(tap:tap) { logger.error("监听重新启用失败，重建");stop() }
            }
        }
        if physicalTimer == nil {
            let timer=Timer(timeInterval:0.02,repeats:true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollPhysicalVoiceKeys() }
            }
            RunLoop.main.add(timer,forMode:.common)
            physicalTimer=timer
        }
        if tap != nil { return }
        let mask=(1 << CGEventType.flagsChanged.rawValue)|(1 << CGEventType.keyDown.rawValue)|(1 << CGEventType.keyUp.rawValue)
        let context=Unmanaged.passUnretained(self).toOpaque()
        tap=CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,options:.listenOnly,eventsOfInterest:CGEventMask(mask),callback:{ _,type,event,context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let monitor=Unmanaged<VoiceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.callbackCount += 1
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.logger.error("系统停用了监听，正在重新启用")
                    if let tap=monitor.tap { CGEvent.tapEnable(tap:tap,enable:true) }
                } else if let copy=event.copy() {
                    let id=monitor.epoch
                    Task { @MainActor in guard monitor.epoch==id else{return};monitor.receive(type,copy) }
                }
            }
            return Unmanaged.passUnretained(event)
        },userInfo:context)
        if let tap { source=CFMachPortCreateRunLoopSource(nil,tap,0);CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes);CGEvent.tapEnable(tap:tap,enable:true) }
        logger.notice("监听创建结果：\(self.active)")
    }
    private func receive(_ type:CGEventType,_ event:CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap { CGEvent.tapEnable(tap:tap,enable:true) };return }
        guard event.getIntegerValueField(.eventSourceUserData) != 0x4E414741 else { return }
        let key=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown,key==53 { holdGate.reset();toggleOn=false;stopAll?();return }
        let p=Preferences.shared
        if key==p.holdShortcut.keyCode || key==p.toggleShortcut.keyCode {
            configuredCount += 1
            logger.notice("配置键原始信息：key=\(key)，flags=\(event.flags.rawValue)，来源PID=\(event.getIntegerValueField(.eventSourceUnixProcessID))")
        }
        if type == .flagsChanged,!Self.isModifier(p.holdShortcut.keyCode),holdGate.owner != nil,event.flags.rawValue & p.holdShortcut.modifiers != p.holdShortcut.modifiers {
            _=holdGate.event(false);note("事件：组合键修饰键松开");held?(false)
        }
        if key==p.holdShortcut.keyCode {
            let down=type == .flagsChanged ? Self.modifierDown(key,raw:event.flags.rawValue,required:p.holdShortcut.modifiers) : type == .keyDown && event.flags.rawValue & p.holdShortcut.modifiers == p.holdShortcut.modifiers
            if down && toggleOn {
                // A real hold-key press ends toggle mode; do not start a second
                // session while its synthetic hold is draining.
                toggleOn=false;toggled?(false);return
            }
            note("事件：按住键"+(down ? "按下":"松开"))
            _ = holdGate.event(down)
            // A missed release must not suppress the next real press. ComputerVoice
            // is idempotent while active; every physical press can recover a stale latch.
            held?(down)
        }
        if key==p.toggleShortcut.keyCode {
            let down=type == .flagsChanged ? Self.modifierDown(key,raw:event.flags.rawValue,required:p.toggleShortcut.modifiers) : type == .keyDown && event.flags.rawValue & p.toggleShortcut.modifiers == p.toggleShortcut.modifiers
            note("事件：开关键"+(down ? "按下":"松开"))
            if down && !toggleDown { toggleOn.toggle();toggled?(toggleOn) }
            toggleDown=down
        } else if key != p.toggleShortcut.keyCode,toggleOn,type == .keyDown { toggleOn=false;toggled?(false) }
    }
    private static func modifierDown(_ key:UInt16,raw:UInt64,required:UInt64)->Bool {
        VoiceModifierState.isDown(key,flags:raw,required:required)
    }
    private static func isModifier(_ key:UInt16)->Bool {
        [54,55,56,60,58,61,59,62,63].contains(key)
    }
    // Read only the two configured modifier keys from hardware state. Session
    // event taps can miss them when an input method consumes its global shortcut.
    private func pollPhysicalVoiceKeys() {
        pollCount += 1
        if pollCount == 1 || pollCount % 250 == 0 {
            healthSummary="回调 \(callbackCount) · 配置键 \(configuredCount) · 轮询 \(pollCount)"
            if pollCount<=500 {logger.notice("监听健康：\(self.healthSummary,privacy:.public)")}
        }
        let p=Preferences.shared
        if Self.isModifier(p.holdShortcut.keyCode) {
            let down=CGEventSource.keyState(.hidSystemState,key:CGKeyCode(p.holdShortcut.keyCode))
            if let transition=holdGate.poll(down) {note("硬件轮询："+(transition ? "按下":"松开"));held?(transition)}
        }

    }
    func resetToggleState(){toggleOn=false;toggleDown=false}
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        epoch=UUID();physicalTimer?.invalidate();physicalTimer=nil
        source=nil;tap=nil;holdGate.reset();toggleOn=false;toggleDown=false
        callbackCount=0;pollCount=0;configuredCount=0;healthSummary="尚未启动"
    }
}
