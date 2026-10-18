import AppKit
import SwiftUI
@MainActor
final class VoiceHUD {
    private var panel:NSPanel?
    private weak var capture:AudioCapture?
    private var timer:Timer?
    private var lastStatus=""
    private var errorUntil=Date.distantPast
    private var showingError=false
    private var errorMessage=""
    init(_ capture:AudioCapture){
        self.capture=capture
        timer=Timer.scheduledTimer(withTimeInterval:0.15,repeats:true){[weak self]_ in MainActor.assumeIsolated{self?.refresh()}}
        if let timer{RunLoop.main.add(timer,forMode:.common)}
    }
    private func refresh(){
        guard let capture else{return}
        if capture.status != lastStatus {
            lastStatus=capture.status
            if ["失败","未启动","没有声音","没有收到","不可用","超时","未允许"].contains(where:{capture.status.contains($0)}) {errorUntil=Date().addingTimeInterval(5)}
        }
        let errorVisible=Date()<errorUntil && !capture.armed && !capture.computer.active && !capture.recognizing
        let visible=Preferences.shared.showHUD && (capture.armed || capture.computer.active || capture.recognizing || errorVisible)
        guard visible else{panel?.orderOut(nil);return}
        if panel==nil{
            let panel=NonFocusPanel(contentRect:NSRect(x:0,y:0,width:330,height:76),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.ignoresMouseEvents=true
            panel.contentView=NSHostingView(rootView:HUDContent(capture:capture,computer:capture.computer));self.panel=panel
        }
        if errorVisible,(!showingError || errorMessage != capture.status) {panel?.contentView=NSHostingView(rootView:FailureHUD(message:capture.status));errorMessage=capture.status}
        else if !errorVisible,showingError {panel?.contentView=NSHostingView(rootView:HUDContent(capture:capture,computer:capture.computer))}
        showingError=errorVisible
        if let screen=NSScreen.main{panel?.setFrameOrigin(NSPoint(x:screen.visibleFrame.midX-165,y:screen.visibleFrame.minY+48))}
        panel?.orderFrontRegardless()
    }
}
final class NonFocusPanel:NSPanel{override var canBecomeKey:Bool{false};override var canBecomeMain:Bool{false}}
struct HUDContent:View{
    @ObservedObject var capture:AudioCapture
    @ObservedObject var computer:ComputerVoice
    var body:some View{
        HStack(spacing:14){Image(systemName:"water.waves").font(.title2).foregroundStyle(.teal);VStack(alignment:.leading,spacing:6){Text(computer.active ? "电脑麦克风":capture.recognizing ? "识别中":"遥控器").font(.callout.weight(.semibold));ProgressView(value:Double(computer.active ? computer.level:capture.level)).tint(.teal)};Text("小娜迦").font(.caption).foregroundStyle(.secondary)}.padding(18).frame(width:330,height:76).background(.ultraThinMaterial,in:Capsule()).overlay(Capsule().stroke(.white.opacity(0.25),lineWidth:1))
    }
}

private struct FailureHUD:View {
    let message:String
    var body:some View {HStack(spacing:12){Image(systemName:"exclamationmark.circle").foregroundStyle(.orange);Text(message).font(.callout).lineLimit(2)}.padding(18).frame(width:330,height:76).background(.ultraThinMaterial,in:Capsule())}
}
