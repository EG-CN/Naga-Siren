import SwiftUI
import AppKit

// Keep the actual compositor-backed effect inside the content hierarchy.
// Keep content independent; only the background effect changes opacity.
struct WindowGlass:NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context:Context)->GlassView {
        let view=GlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue=reduceTransparency ? 1:0.70
        return view
    }
    func updateNSView(_ view:GlassView,context:Context) {
        view.reduceTransparency=reduceTransparency
        view.alphaValue=reduceTransparency ? 1:0.70
        view.configureWindow()
        view.report(reduceTransparency:reduceTransparency)
    }
    final class GlassView:NSVisualEffectView {
        var reduceTransparency=false
        private var reported=false
        override func hitTest(_ point:NSPoint)->NSView?{nil}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();configureWindow();report(reduceTransparency:reduceTransparency)}
        func configureWindow(){
            guard let window else{return}
            window.isOpaque=false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent=true
        }
        func report(reduceTransparency:Bool){
            guard window != nil,!reported else{return}
            reported=true
            DiagnosticLog.record("window.glass.ready",fields:["inContentTree":"true","behindWindow":String(blendingMode == .behindWindow),"alpha":String(Double(alphaValue)),"reduceTransparency":String(reduceTransparency)])
        }
    }
}

struct TransparentWindowContent:ViewModifier {
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 15.0,*) {
            content.containerBackground(.clear,for:.window)
        } else {content}
    }
}
