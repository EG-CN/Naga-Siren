import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class Feedback {
    static let shared=Feedback()
    private var player:AVAudioPlayer?
    func sound(start:Bool,preview:Bool=false){
        let p=Preferences.shared
        guard p.sounds || preview else{return}
        // Synthesized soft glass chime; no external audio asset.
        let count=Int(16000*0.13)
        let notes=start ? [659.25,987.77]:[987.77,659.25]
        let pcm=(0..<count).map{ i -> Int16 in
            let t=Double(i)/16000
            let envelope=pow(sin(Double.pi*Double(i)/Double(count)),2)*exp(-t*12)
            let note=notes[i<count/2 ? 0:1]
            return Int16(sin(2*Double.pi*note*t)*envelope*2800)
        }
        player=try? AVAudioPlayer(data:waveData(pcm));player?.volume=Float(p.volume);player?.play()
    }
}
struct GlassCard<Content:View>:View{
    let title:String
    @ViewBuilder var content:Content
    var body:some View{
        VStack(alignment:.leading,spacing:14){if !title.isEmpty{Text(title).font(.headline)};content}
            .frame(maxWidth:.infinity,alignment:.leading).padding(20)
            .clipShape(RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(.white.opacity(0.18),lineWidth:1))
    }
}
struct ShortcutRecorder:NSViewRepresentable{
    @Binding var shortcut:VoiceShortcut
    var allowModifierOnly=true
    func makeNSView(context:Context)->KeyField{let field=KeyField();field.changed={shortcut=$0};field.allowModifierOnly=allowModifierOnly;field.isEditable=false;field.isSelectable=false;field.isBezeled=false;field.drawsBackground=false;return field}
    func updateNSView(_ field:KeyField,context:Context){field.allowModifierOnly=allowModifierOnly;field.stringValue=shortcut.label+"  · 点击录入";field.changed={shortcut=$0}}
    final class KeyField:NSTextField{
        var changed:((VoiceShortcut)->Void)?
        var allowModifierOnly=true
        private var pendingModifier:NSEvent?
        override var acceptsFirstResponder:Bool{true}
        override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);stringValue="请按快捷键…"}
        override func keyDown(with event:NSEvent){if event.keyCode==53{window?.makeFirstResponder(nil);return};record(event)}
        override func flagsChanged(with event:NSEvent){
            guard allowModifierOnly else{return}
            if !event.modifierFlags.intersection([.command,.option,.control,.shift,.function]).isEmpty {pendingModifier=event}
            else if let pending=pendingModifier {pendingModifier=nil;record(pending)}
        }
        private func record(_ event:NSEvent){
            pendingModifier=nil
            let flags=event.modifierFlags.intersection([.command,.option,.control,.shift,.function])
            let names:[UInt16:String]=[54:"右 ⌘",55:"左 ⌘",58:"左 ⌥",61:"右 ⌥",59:"左 ⌃",62:"右 ⌃",56:"左 ⇧",60:"右 ⇧",63:"fn",49:"空格",36:"回车"]
            var label=names[event.keyCode] ?? (event.charactersIgnoringModifiers?.uppercased() ?? "键 \(event.keyCode)")
            if names[event.keyCode]==nil{label=(flags.contains(.control) ? "⌃":"")+(flags.contains(.option) ? "⌥":"")+(flags.contains(.shift) ? "⇧":"")+(flags.contains(.command) ? "⌘":"")+label}
            changed?(VoiceShortcut(keyCode:event.keyCode,modifiers:UInt64(flags.rawValue),label:label));window?.makeFirstResponder(nil)
        }
    }
}
