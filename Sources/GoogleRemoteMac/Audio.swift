import Foundation
import AVFoundation
import Speech
import CoreGraphics
import AppKit
import os
import Combine

struct ADPCMDecoder {
    static let steps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
        143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
        494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
        1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,]
    static let indices = [-1,-1,-1,-1,2,4,6,8]
    var predictor = 0
    var index = 0
    var previousInput = 0.0
    var previousOutput = 0.0
    var initialized = false
    mutating func reset(_ value: Int = 0, _ step: Int = 0) {
        predictor = min(32767, max(-32768, value)); index = min(88, max(0, step))
        previousInput = 0; previousOutput = 0; initialized = false
    }
    mutating func decode(_ bytes: [UInt8]) -> [Int16] {
        var result: [Int16] = []; result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            for nibble in [Int(byte >> 4), Int(byte & 15)] {
                let step = Self.steps[index]
                var delta = step >> 3
                if nibble & 1 != 0 { delta += step >> 2 }
                if nibble & 2 != 0 { delta += step >> 1 }
                if nibble & 4 != 0 { delta += step }
                predictor = min(32767, max(-32768, predictor + (nibble & 8 != 0 ? -delta : delta)))
                index = min(88, max(0, index + Self.indices[nibble & 7]))
                result.append(Int16(predictor))
            }
        }
        return result
    }
    mutating func centered(_ samples: [Int16]) -> [Int16] {
        let alpha = exp(-2 * Double.pi * 20 / 16000)
        return samples.map { value in
            let x = Double(value)
            if !initialized { previousInput = x; initialized = true }
            let y = x - previousInput + alpha * previousOutput
            previousInput = x; previousOutput = y
            return Int16(min(32767, max(-32768, Int(y.rounded()))))
        }
    }
}

func waveData(_ samples: [Int16]) -> Data {
    var data = Data()
    func word(_ n: UInt16) { data.append(UInt8(n & 255)); data.append(UInt8(n >> 8)) }
    func long(_ n: UInt32) { word(UInt16(n & 65535)); word(UInt16(n >> 16)) }
    data.append(contentsOf: "RIFF".utf8); long(UInt32(36 + samples.count * 2))
    data.append(contentsOf: "WAVEfmt ".utf8); long(16); word(1); word(1)
    long(16000); long(32000); word(2); word(16)
    data.append(contentsOf: "data".utf8); long(UInt32(samples.count * 2))
    for value in samples { word(UInt16(bitPattern: value)) }
    return data
}

@MainActor
final class AudioCapture: ObservableObject {
    @Published var armed = false
    @Published var sampleCount = 0
    @Published var status = "连接后点击开始录音验证，再按遥控器语音键"
    @Published var transcript = ""
    @Published var recognizing = false
    @Published var automatic = false
    @Published var useDoubao = true
    let computer = ComputerVoice()
    let keys = VoiceKeyMonitor()
    private var hud:VoiceHUD?
    @Published var sourceName = "待机"
    @Published var level:Float = 0
    init() {
        computer.startRefusal = { [weak self] in
            guard let self else{return "语音控制器未就绪"}
            if !self.automatic{return "自动语音已暂停"}
            if Preferences.shared.shortcutsConflict{return "两种语音快捷键相同，请修改其中一个"}
            if !self.useDoubao{return "当前不是豆包模式"}
            if self.armed{return "遥控器正在录音"}
            if self.recognizing{return "上一段声音仍在处理"}
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier{return "小娜迦设置窗口仍在前台，请先点击目标输入框"}
            return nil
        }
        computer.changed = { [weak self] text in self?.status=text;self?.sourceName=self?.computer.active == true ? "电脑麦克风":"待机" }
        keys.held = { [weak self] down in
            guard let self else{return}
            // The toggle session owns a synthetic hold. Its release is handled
            // by stop/cancel, never by a hardware poll of the hold shortcut.
            if self.computer.toggleActive { return }
            if down { self.computer.start() } else { self.computer.stop() }
        }
        keys.toggled = { [weak self] down in
            guard let self else{return}
            if down {
                if self.computer.active { self.keys.resetToggleState();return }
                self.computer.start(toggle:true)
                if !self.computer.active { self.keys.resetToggleState() }
            } else { self.computer.stop() }
        }
        computer.forcedToggleEnd = { [weak self] in self?.keys.resetToggleState() }
        keys.stopAll = { [weak self] in self?.emergencyStop(cancelExternal:false) }
        hud=VoiceHUD(self)
    }
    func emergencyStop(cancelExternal:Bool=true){
        DiagnosticLog.record("voice.emergencyStop",fields:["remote":String(armed),"draining":String(recognizing)])
        Logger(subsystem:"local.googleremote.macprobe",category:"voice-stop").notice("停止入口：电脑=\(self.computer.active)，开关=\(self.computer.toggleActive)，遥控器=\(self.armed)，尾部=\(self.recognizing)")
        computer.cancel(endExternal:cancelExternal);shutdown();status="声音采集已停止";sourceName="待机"
    }
    @Published var routeStatus="尚未检查豆包麦克风"
    @Published var routeChanging=false
    private var routeObserver:AnyCancellable?
    private lazy var routeDriver=DoubaoSettingsRouteDriver(capture:self)
    lazy var routeControl:VoiceRouteCoordinator = {
        let control=VoiceRouteCoordinator(driver:routeDriver)
        routeObserver=control.$state.sink { [weak self] state in
            guard let self else{return}
            self.routeStatus=state.description
            if case .switching = state {self.routeChanging=true}
            else {self.routeChanging=false;self.routeDriver.finishUI()}
            self.status=state.description
        }
        return control
    }()
    private var voiceInputRevision:UInt64=0
    func stopVoiceInputs(){voiceInputRevision &+= 1;automatic=false;keys.stop();remoteSpeech.cancel()}
    func endOwnedForRoute() async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(4))
        if computer.active && !computer.toggleActive {
            while CGEventSource.keyState(.hidSystemState,key:CGKeyCode(Preferences.shared.holdShortcut.keyCode)) {
                guard ContinuousClock.now<deadline else {throw DoubaoSettingsRouteDriver.Failure(message:"请先松开语音快捷键，再切换麦克风")}
                try await Task.sleep(for:.milliseconds(40))
            }
        }
        computer.stop()
        if armed {finish()}
        await remoteSpeech.waitUntilFinished()
        while computer.draining || recognizing {
            guard ContinuousClock.now<deadline else {
                emergencyStop(cancelExternal:false)
                throw DoubaoSettingsRouteDriver.Failure(message:"语音尾部传输超时，请重试切换")
            }
            try await Task.sleep(for:.milliseconds(40))
        }
        sourceName="待机";keys.resetToggleState()
    }
    func startVoiceInputs() async throws {
        let activation=voiceInputRevision
        guard activation==voiceInputRevision,routeControl.wantsEnabled,!routeControl.quitting else{throw CancellationError()}
        keys.stop() // Native Command/Option always go directly to Doubao.
        automatic=true
    }
    func prepareToQuit() async -> Bool {await routeControl.prepareToQuit()}
    private var sleeping=false
    private var resumeVoiceAfterSleep=false
    func suspendForSleep(){sleeping=true;resumeVoiceAfterSleep=routeControl.wantsEnabled;enableAutomatic(false)}
    func resumeAfterSleep(){sleeping=false;enableAutomatic(resumeVoiceAfterSleep)}
    func requestMicrophone(){ AVCaptureDevice.requestAccess(for:.audio) { @Sendable _ in } }
    func requestMonitoring(){ _=CGRequestListenEventAccess() }
    func requestSpeech(){ SFSpeechRecognizer.requestAuthorization { @Sendable _ in } }
    private lazy var remoteSpeech:RemoteDoubaoSession = {
        let session=RemoteDoubaoSession(driver:DoubaoRemoteDriver(capture:self))
        session.completed = { [weak self] message,restored in
            guard let self else{return}
            if self.armed { self.shutdown() }
            self.recognizing=false;self.status=message
            if !restored {self.automatic=false;self.routeStatus=message}
        }
        return session
    }()
    private let delivery = TextDelivery()
    private var automaticSession = false
    private var inputWarning: String?
    func requestInputPermission() { delivery.requestPermission() }
    func enableAutomatic(_ enabled: Bool) { routeControl.request(enabled:enabled) }
    var sendDeviceCommand:((Data)->Void)?
    private var toggleGate=RemoteModeGate()
    private var extendTimer:Timer?
    var frameSize = 160
    private var decoder = ADPCMDecoder()
    private var pending: [UInt8] = []
    private var sync: (Int, Int)?
    private var samples: [Int16] = []
    private var player: AVAudioPlayer?
    private var limit: Timer?
    private var finishTimer: Timer?
    private var task: SFSpeechRecognitionTask?
    private var recognitionID = UUID()
    private var recognitionTimer: Timer?
    private var maxSamples: Int { 16000 * Preferences.shared.maximumSeconds }
    var duration: Double { Double(sampleCount) / 16000 }
    var summary: String {
        guard !samples.isEmpty else { return "尚无解码声音" }
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        let rms = sqrt(samples.reduce(0.0) { $0 + pow(Double($1), 2) } / Double(samples.count))
        let clipped = samples.filter { abs(Int($0)) >= 32760 }.count
        return String(format: "%.2f 秒 · 峰值 %d · RMS %.0f · 削波 %.2f%%", duration, peak, rms, Double(clipped) * 100 / Double(samples.count))
    }
    func arm() {
        guard !remoteSpeech.active else {status="遥控器语音仍在收尾，请稍候";return}
        automaticSession = false; cancelRecognition(); player?.stop(); finishTimer?.invalidate(); limit?.invalidate()
        samples = []; sampleCount = 0; pending = []; sync = nil; decoder.reset()
        transcript = ""; armed = true; status = "等待语音数据，请按住遥控器语音键说话；最长 \(Preferences.shared.maximumSeconds) 秒"
        limit = Timer.scheduledTimer(withTimeInterval: Double(Preferences.shared.maximumSeconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }
    func control(_ data: Data) {
        if automatic,Preferences.shared.recordingMode=="toggle" {
            if data.first == 4,!toggleGate.active,(computer.active || computer.draining || recognizing) {
                status="当前语音会话未结束，请稍后再按遥控器";return
            }
            for effect in toggleGate.control(data) {
                switch effect {
                case .consume(let payload):consumeControl(payload)
                case .write(let payload):sendDeviceCommand?(payload)
                case .finish:finish()
                }
            }
        } else { consumeControl(data) }
    }
    private func consumeControl(_ data: Data) {
        let p = Array(data)
        if automatic, p.first == 4, !armed {
            guard !recognizing && !computer.active && !computer.draining else { status = "上一段仍在识别，请稍后再说"; return }
            guard p.count >= 4, p[2] == 2 else { status = "遥控器音频格式不支持"; return }
            inputWarning = useDoubao ? nil : delivery.capture()
            arm(); automaticSession = true;sourceName="遥控器"
            Feedback.shared.sound(start:true)
            if Preferences.shared.recordingMode=="toggle" {
                extendTimer=Timer.scheduledTimer(withTimeInterval:20,repeats:true){[weak self]_ in MainActor.assumeIsolated{if self?.armed==true{self?.sendDeviceCommand?(Data([0x0c,0]))}}}
            }
            if useDoubao {
                remoteSpeech.begin(maxSamples:maxSamples)
            }
        }
        guard armed else { return }
        if p.first == 4 {
            guard p.count >= 4, p[2] == 2 else { finish(); status = "收到不支持的音频开始格式"; return }
            finishTimer?.invalidate()
            decoder.reset(); pending = []; sync = nil
        } else if p.first == 10, p.count >= 7 {
            sync = (Int(Int16(bitPattern: UInt16(p[4]) << 8 | UInt16(p[5]))), Int(p[6]))
        } else if p.first == 0 {
            finishTimer?.invalidate()
            finishTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
    }
    func audio(_ data: Data) {
        guard armed, (1...512).contains(frameSize) else { return }
        pending.append(contentsOf: data)
        while pending.count >= frameSize {
            if let sync { decoder.reset(sync.0, sync.1); self.sync = nil }
            let frame = Array(pending.prefix(frameSize)); pending.removeFirst(frameSize)
            let decoded = decoder.decode(frame)
            let pcm = decoder.centered(decoded)
            if automaticSession && useDoubao { remoteSpeech.feed(pcm) }
            let rms=sqrt(pcm.reduce(0.0){$0+pow(Double($1)/32768,2)}/Double(max(1,pcm.count)))
            level=Float(min(1,rms*8))
            let remaining = maxSamples - samples.count
            samples.append(contentsOf: pcm.prefix(max(0, remaining)))
            sampleCount = samples.count; status = "正在解码遥控器音频"
            if samples.count >= maxSamples { finish(); return }
        }
    }
    func finish() {
        guard armed else { return }
        let shouldRecognize = automaticSession
        extendTimer?.invalidate();extendTimer=nil
        if shouldRecognize,Preferences.shared.recordingMode=="toggle",toggleGate.active {
            sendDeviceCommand?(Data([0x0d,toggleGate.stream]));toggleGate.reset()
        }
        if shouldRecognize { Feedback.shared.sound(start:false) }
        automaticSession = false
        armed = false; limit?.invalidate(); finishTimer?.invalidate(); pending = []; sync = nil
        status = samples.isEmpty ? "没有收到可解码音频，请重新开始后按语音键" : "声音已解码，请试听确认清晰度，再点击转成文字"
        if shouldRecognize && useDoubao {
            if remoteSpeech.active {
                recognizing = true; status = "正在结束遥控器语音并恢复电脑麦克风"; remoteSpeech.finish()
            } else { recognizing=false }
        } else if shouldRecognize && !samples.isEmpty { recognize(deliver:true) }
        sourceName="待机";level=0
    }
    func play() {
        guard !armed, !samples.isEmpty else { return }
        do { player = try AVAudioPlayer(data: waveData(samples)); player?.prepareToPlay(); player?.play(); status = "正在试听解码声音" }
        catch { status = "试听失败：\(error.localizedDescription)" }
    }
    func cancelRecognition() {
        recognitionID = UUID(); task?.cancel(); task = nil; recognitionTimer?.invalidate(); recognizing = false
    }
    func recognize(deliver: Bool = false) {
        guard !armed, !samples.isEmpty, !recognizing else { return }
        player?.stop(); cancelRecognition(); recognizing = true
        let id = recognitionID
        SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] authorization in
            Task { @MainActor in
                guard let self, self.recognitionID == id else { return }
                guard authorization == .authorized else { self.recognizing = false; self.status = "请在系统设置中允许语音识别后重试"; return }
                self.startRecognition(id, deliver: deliver)
            }
        }
    }
    private func startRecognition(_ id: UUID, deliver: Bool) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            recognizing = false; status = "系统中文语音识别当前不可用"; return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            recognizing = false; status = "系统暂不支持本机中文识别；请先在系统设置启用中文听写并下载语言资源"; return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.contextualStrings = Preferences.shared.commonWords.split(separator:"\n").prefix(100).map(String.init)
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { recognizing = false; status = "无法创建识别音频缓冲"; return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, value) in samples.enumerated() { channel[i] = Float(value) / 32768 }
        transcript = ""; status = "正在本机识别中文语音"
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.recognitionID == id else { return }
                if let text { self.transcript = text }
                if final || message != nil {
                    self.recognizing = false; self.recognitionTimer?.invalidate(); self.task = nil
                    if final {
                        self.status = deliver ? (self.inputWarning ?? self.delivery.deliver(self.transcript)) : "文字识别完成"
                    } else { self.status = "识别未完成：\(message ?? "未知错误")" }
                }
            }
        }
        request.append(buffer); request.endAudio()
        recognitionTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.recognitionID == id, self.recognizing else { return }; self.cancelRecognition(); self.status = "识别超时，可试听后重试" }
        }
    }
    func shutdown() { extendTimer?.invalidate();extendTimer=nil;if toggleGate.active {sendDeviceCommand?(Data([0x0d,toggleGate.stream]))};toggleGate.reset();remoteSpeech.cancel(); automaticSession = false; if armed { finish() }; player?.stop(); cancelRecognition() }
}

