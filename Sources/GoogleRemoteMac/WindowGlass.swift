import SwiftUI
import AppKit

// 实色窗口底：「浅水」主题要求全程不透明，不再使用系统材质模糊。
// 结构保持：视图挂上窗口后完成 SettingsWindowPresenter 注册。
struct WindowGlass:NSViewRepresentable {
    func makeNSView(context:Context)->GlassView {
        let view=GlassView()
        return view
    }
    func updateNSView(_ view:GlassView,context:Context) {
        view.configureWindow()
        view.report()
    }
    final class GlassView:NSView {
        private var reported=false
        override func hitTest(_ point:NSPoint)->NSView?{nil}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();configureWindow();report()}
        override func draw(_ dirtyRect:NSRect){
            NSColor(calibratedRed:0x0D/255,green:0x15/255,blue:0x26/255,alpha:1).setFill()
            dirtyRect.fill()
        }
        func configureWindow(){
            guard let window else{return}
            SettingsWindowPresenter.register(window)
            window.isOpaque=true
            window.backgroundColor=NSColor(calibratedRed:0x0D/255,green:0x15/255,blue:0x26/255,alpha:1)
            window.titlebarAppearsTransparent=true
        }
        func report(){
            guard window != nil,!reported else{return}
            reported=true
            DiagnosticLog.record("window.background.ready",fields:["solid":"true","opaque":String(window?.isOpaque ?? false)])
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
        // A minimized settings window would strand its thumbnail in the Dock
        // with no app icon to restore from, so the window cannot miniaturize.
        settingsWindow.styleMask.remove(.miniaturizable)
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
