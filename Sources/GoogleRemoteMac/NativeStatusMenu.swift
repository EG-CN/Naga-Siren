import AppKit

@MainActor final class NativeStatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private weak var probe: RemoteProbe?
    init(probe:RemoteProbe) {
        self.probe=probe
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        super.init()
        item.button?.image=NSImage(systemSymbolName:"water.waves",accessibilityDescription:"小娜迦")
        item.button?.image?.isTemplate=true
        item.button?.toolTip="小娜迦"
        let menu=NSMenu()
        menu.delegate=self
        item.menu=menu
        rebuild(menu)
        DiagnosticLog.record("menubar.native.ready")
    }
    func menuNeedsUpdate(_ menu:NSMenu) {
        DiagnosticLog.record("menubar.open")
        rebuild(menu)
    }
    private func rebuild(_ menu:NSMenu) {
        menu.removeAllItems()
        let status=NSMenuItem(title:probe?.voiceReady == true ? "小娜迦 · 遥控器已就绪":"小娜迦 · 等待遥控器",action:nil,keyEquivalent:"")
        status.isEnabled=false
        menu.addItem(status)
        menu.addItem(.separator())
        add("打开设置…",#selector(openSettings),to:menu)
        let enabled=probe?.capture.routeControl.wantsEnabled == true
        add(enabled ? "暂停语音":"恢复语音",#selector(toggleVoice),to:menu)
        add("停止当前语音",#selector(stopVoice),to:menu)
        menu.addItem(.separator())
        add("退出小娜迦",#selector(quit),to:menu)
    }
    private func add(_ title:String,_ action:Selector,to menu:NSMenu) {
        let entry=NSMenuItem(title:title,action:action,keyEquivalent:"")
        entry.target=self
        menu.addItem(entry)
    }
    @objc private func openSettings() { SettingsWindowPresenter.requestOpen() }
    @objc private func toggleVoice() {
        guard let capture=probe?.capture,!capture.routeChanging else {return}
        capture.enableAutomatic(!capture.routeControl.wantsEnabled)
    }
    @objc private func stopVoice() { probe?.capture.emergencyStop() }
    @objc private func quit() { NSApp.terminate(nil) }
}
