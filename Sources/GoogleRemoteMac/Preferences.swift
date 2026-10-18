import SwiftUI
import CoreAudio

struct VoiceShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var label: String
    static let hold = VoiceShortcut(keyCode: 54, modifiers: 1 << 20, label: "右 ⌘")
    static let toggle = VoiceShortcut(keyCode: 61, modifiers: 1 << 19, label: "右 ⌥")
}
struct AudioEndpoint: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    @Published var showMenu = true { didSet { save() } }
    @Published var showHUD = true { didSet { save() } }
    @Published var sounds = false { didSet { save() } }
    @Published var volume = 0.35 { didSet { save() } }
    @Published var recordingMode = "hold" { didSet { save() } }
    @Published var maximumSeconds = 120 { didSet { save() } }
    @Published var outputUID = "" { didSet { save() } }
    @Published var microphoneUID = "" { didSet { save() } }
    @Published var commonWords = "Vibe Coding\nCodex\nDeepSeek\nWorkBuddy\nChromecast\nGitHub" { didSet { save() } }
    @Published var holdShortcut = VoiceShortcut.hold { didSet { save() } }
    @Published var toggleShortcut = VoiceShortcut.toggle { didSet { save() } }
    var shortcutsConflict:Bool {holdShortcut.keyCode==toggleShortcut.keyCode && holdShortcut.modifiers==toggleShortcut.modifiers}
    private init() {
        guard let data = UserDefaults.standard.data(forKey: "naga.preferences"), let d = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        showMenu=d.showMenu; showHUD=d.showHUD; sounds=d.sounds; volume=d.volume
        recordingMode=d.recordingMode; maximumSeconds=d.maximumSeconds
        outputUID=d.outputUID; microphoneUID=d.microphoneUID; commonWords=d.commonWords
        holdShortcut=d.holdShortcut; toggleShortcut=d.toggleShortcut
    }
    private struct Saved: Codable {
        let showMenu: Bool; let showHUD: Bool; let sounds: Bool; let volume: Double
        let recordingMode: String; let maximumSeconds: Int; let outputUID: String; let microphoneUID: String; let commonWords: String
        let holdShortcut: VoiceShortcut; let toggleShortcut: VoiceShortcut
    }
    private func save() {
        let value=Saved(showMenu:showMenu,showHUD:showHUD,sounds:sounds,volume:volume,recordingMode:recordingMode,maximumSeconds:maximumSeconds,outputUID:outputUID,microphoneUID:microphoneUID,commonWords:commonWords,holdShortcut:holdShortcut,toggleShortcut:toggleShortcut)
        if let data=try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey:"naga.preferences") }
    }
}
enum AudioCatalog {
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var raw: Unmanaged<CFString>?; var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&raw)==noErr else { return nil }
        return raw?.takeUnretainedValue() as String?
    }
    static func devices(input: Bool) -> [AudioEndpoint] {
        var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size)==noErr,size>0 else { return [] }
        var ids=[AudioDeviceID](repeating:0,count:Int(size)/4)
        let result=ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,$0.baseAddress!) }
        guard result==noErr else { return [] }
        return ids.compactMap { id in
            var stream=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:input ? kAudioDevicePropertyScopeInput:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
            var count:UInt32=0
            guard AudioObjectGetPropertyDataSize(id,&stream,0,nil,&count)==noErr,count>0,
                  let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName) else { return nil }
            return AudioEndpoint(id:id,uid:uid,name:name)
        }
    }
}
