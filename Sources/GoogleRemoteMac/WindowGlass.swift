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
            SettingsWindowPresenter.register(window)
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

// Menu-bar apps can retain a hidden or minimized settings window. Restore the
// actual settings window after SwiftUI has processed its openWindow action.
@MainActor enum SettingsWindowPresenter {
    private static var window: NSWindow?
    static var createWindow: (() -> NSWindow?)?
    private static var requested = false
    private static var userOpened = false
    static func register(_ settingsWindow:NSWindow) {
        window=settingsWindow
        if requested { present() }
        else if !userOpened { DispatchQueue.main.async { if !userOpened { settingsWindow.orderOut(nil) } } }
    }
    static func requestOpen() {
        requested=true
        userOpened=true
        DiagnosticLog.record("settings.window.request")
        DispatchQueue.main.async { present() }
    }
    static func hideForVoice() {
        requested=false
        userOpened=false
        window?.orderOut(nil)
        DiagnosticLog.record("settings.window.background")
    }
    private static func present() {
        guard requested else { return }
        if window == nil { window=createWindow?() }
        guard let window else { return }
        requested=false
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps:true)
        window.makeKeyAndOrderFront(nil)
        DiagnosticLog.record("settings.window.presented",fields:["visible":String(window.isVisible),"miniaturized":String(window.isMiniaturized)])
    }
}
