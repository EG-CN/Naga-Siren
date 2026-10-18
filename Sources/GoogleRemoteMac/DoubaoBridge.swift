import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import os
@preconcurrency import ApplicationServices

@MainActor
final class DoubaoBridge {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var held = false
    private var heldShortcut:VoiceShortcut?
    private var heldSource:CGEventSource?
    private let logger=Logger(subsystem:"local.googleremote.macprobe",category:"doubao-bridge")
    private var generation = UUID()
    private var watchdog: Timer?
    private var scheduledSamples=0
    private var playbackStarted=ProcessInfo.processInfo.systemUptime
    var finished: ((String) -> Void)?
    private var format: AVAudioFormat? { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) }
    static func device() throws -> AudioDeviceID {
        let chosen = Preferences.shared.outputUID
        let outputs = AudioCatalog.devices(input: false)
        if !chosen.isEmpty {
            guard let output = outputs.first(where: { $0.uid == chosen }) else { throw BridgeError("所选音频输出设备已离线，请在设置中重新选择") }
            return output.id
        }
        guard let output = outputs.first(where: { $0.name == "MiRemoteV 2ch" }) else { throw BridgeError("未找到 MiRemoteV 2ch，请在设置中选择虚拟音频输出") }
        return output.id
    }
    struct BridgeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    func begin(sendKey: Bool = true) throws {
        cancel()
        guard AXIsProcessTrusted() else { throw BridgeError("请先允许辅助功能权限，以触发豆包语音键") }
        let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
        guard let unit = engine.outputNode.audioUnit, let format else { throw BridgeError("无法初始化虚拟音频输出") }
        var device = try Self.device()
        let code = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard code == noErr else { throw BridgeError("无法连接 MiRemoteV 2ch：\(code)") }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        self.engine = engine; self.player = player
        scheduledSamples=0;playbackStarted=ProcessInfo.processInfo.systemUptime
        // Let Doubao open its selected microphone before the first spoken samples.
        if sendKey, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) {
            silence.frameLength = 4800
            if let base = silence.floatChannelData?[0] { base.initialize(repeating: 0, count: 4800) }
            player.scheduleBuffer(silence)
            scheduledSamples += 4800
        }
        player.play()
        if sendKey {
            heldShortcut=Preferences.shared.holdShortcut
            heldSource=CGEventSource(stateID:.privateState)
            guard key(down: true) else { cancel(); throw BridgeError("无法发送豆包语音快捷键") }
            held = true
            DiagnosticLog.record("bridge.key.down",fields:["posted":"true"])
            logger.notice("已投递自有语音键按下")
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: Double(Preferences.shared.maximumSeconds + 5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(); self?.finished?("豆包传声超时，已释放快捷键") }
        }
    }
    func feed(_ samples: [Int16]) {
        guard let player, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, value) in samples.enumerated() { channel[i] = Float(value) / 32768 }
        player.scheduleBuffer(buffer)
        scheduledSamples += samples.count
    }
    func finish() {
        guard let player, let format,
              let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600) else { cancel(); finished?("音频通道已关闭"); return }
        end.frameLength = 1600
        if let base = end.floatChannelData?[0] { base.initialize(repeating: 0, count: 1600) }
        let id = generation
        watchdog?.invalidate()
        let remaining=Double(scheduledSamples+1600)/16000-(ProcessInfo.processInfo.systemUptime-playbackStarted)
        watchdog=Timer.scheduledTimer(withTimeInterval:max(3,remaining+3),repeats:false){[weak self]_ in
            MainActor.assumeIsolated{guard let self,self.generation==id else{return};self.cancel();self.finished?("音频尾部传输超时，已释放快捷键，请检查虚拟音频设备")}
        }
        player.scheduleBuffer(end, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.cancel(); self.finished?("遥控器声音已交给豆包，由豆包识别并输入")
            }
        }
    }
    func cancel() {
        generation = UUID(); watchdog?.invalidate(); watchdog = nil
        if held { let posted=key(down:false);DiagnosticLog.record("bridge.key.up",fields:["posted":String(posted)]);logger.notice("已投递自有语音键松开：\(posted)") }
        held = false;heldShortcut=nil;heldSource=nil; player?.stop(); engine?.stop(); player = nil; engine = nil
    }
    static func cancelExternalHold(){
        let escape=VoiceShortcut(keyCode:53,modifiers:0,label:"Esc")
        _ = postShortcut(escape,down:true);_ = postShortcut(escape,down:false)
    }
    private func key(down:Bool)->Bool {
        guard let heldShortcut,let heldSource else{return false}
        return Self.postShortcut(heldShortcut,down:down,source:heldSource)
    }
    private static func postShortcut(_ shortcut:VoiceShortcut,down:Bool,source suppliedSource:CGEventSource?=nil)->Bool {
        guard AXIsProcessTrusted(),let source=suppliedSource ?? CGEventSource(stateID:.privateState),
              let event=CGEvent(keyboardEventSource:source,virtualKey:shortcut.keyCode,keyDown:down) else{return false}
        if [54,55,56,60,58,61,59,62,63].contains(shortcut.keyCode){event.type = .flagsChanged}
        let sideMask:UInt64=[54:0x10,55:0x8,58:0x20,61:0x40,59:0x1,62:0x2000,56:0x2,60:0x4][shortcut.keyCode] ?? 0
        event.flags=down ? CGEventFlags(rawValue:shortcut.modifiers|sideMask):[]
        event.setIntegerValueField(.eventSourceUserData,value:0x4E414741);event.post(tap:.cghidEventTap)
        return true
    }

}
