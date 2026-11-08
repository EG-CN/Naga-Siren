import AppKit
import ApplicationServices
import os

@MainActor
final class DoubaoSettingsRouteDriver: VoiceRouteDriver {
    private weak var capture: AudioCapture?
    private let settingsID = "com.bytedance.inputmethod.doubaoime.settings"
    private let settingsURL = URL(fileURLWithPath:"/Library/Input Methods/DoubaoIme.app/Contents/Applications/DoubaoImeSettings.app")
    private let logger = Logger(subsystem:"local.googleremote.macprobe",category:"doubao-route")
    private var settings: NSRunningApplication?
    private var previousApplication: NSRunningApplication?
    private var launchedSettings = false
    private var ownsSettingsUI = false
    private var preparedBackground = false
    private var preserveSettingsUI = false
    private var transitionDeadline:ContinuousClock.Instant?
    private func checkDeadline() throws {if let transitionDeadline,ContinuousClock.now>=transitionDeadline {throw Failure(message:"豆包设置切换超时，已停止接管")}}
    init(capture:AudioCapture) { self.capture=capture;Self.startIdleWatchdog() }
    struct Failure:LocalizedError {
        let message:String
        var errorDescription:String? { message }
    }
    func stopNewSessions(){
        capture?.stopVoiceInputs()
        transitionDeadline=nil
        if previousApplication == nil { previousApplication=NSWorkspace.shared.frontmostApplication }
    }
    func endOwnedSession() async throws {
        try await capture?.endOwnedForRoute()
        transitionDeadline=ContinuousClock.now.advanced(by:.seconds(10))
    }
    func startNewSessions() async throws {
        finishUI()
        logger.notice("设置界面收尾完成，启用遥控器；电脑语音由豆包原生处理")
        try await capture?.startVoiceInputs()
    }

    // Remote transactions are serialized by AudioCapture with lifecycle changes.
    // Capture focus afresh for each switch and always close our settings UI.
    func selectVerified(_ route:VoiceInputRoute) async throws {
        SettingsWindowPresenter.hideForVoice()
        DiagnosticLog.record("route.request",fields:["target":route == .virtual ? "virtual":"builtin"])
        transitionDeadline=ContinuousClock.now.advanced(by:.seconds(10))
        previousApplication=NSWorkspace.shared.frontmostApplication
        defer { finishUI() }
        // 预读与切换入口共用一次遍历，减少 AX 全树扫描次数。
        let list=try await mainNodes()
        if try routeIn(list) != route { try await selectRoute(route,known:list) }
        guard try await selectedRoute() == route else {
            throw Failure(message:"豆包麦克风选择未确认")
        }
    }
    private func routeIn(_ list:[AXUIElement]) throws -> VoiceInputRoute {
        let d=try devices()
        let matches=buttons(list).filter{let s=text($0);return s==d.virtual || s==d.builtIn || s.hasPrefix("自动检测（")}
        guard matches.count==1 else{throw Failure(message:"豆包麦克风控件不唯一，未执行切换")}
        let selected=text(matches[0])
        logger.notice("读回豆包麦克风：\(selected,privacy:.public)")
        if selected==d.virtual{DiagnosticLog.record("route.readback",fields:["route":"virtual"]);return .virtual}
        if selected==d.builtIn {DiagnosticLog.record("route.readback",fields:["route":"builtin"]);return .builtIn}
        if selected.hasPrefix("自动检测（") {return .systemDefault}
        throw Failure(message:"豆包当前选择了其他设备：\(selected)")
    }
    func selectedRoute() async throws -> VoiceInputRoute {
        try routeIn(try await mainNodes())
    }

    private func devices() throws -> (virtual:String,builtIn:String) {
        let inputs=AudioCatalog.devices(input:true)
        let builtIn=inputs.filter{$0.name.contains("MacBook Air")}
        guard builtIn.count==1 else {
            throw Failure(message:"未能唯一找到 MacBook Air 内置麦克风")
        }
        return ("MiRemoteV 2ch",builtIn[0].name)
    }
    private func appElement() async throws -> AXUIElement {
        try checkDeadline()
        guard AXIsProcessTrusted() else { throw Failure(message:"自动切换豆包麦克风需要小娜迦的辅助功能权限") }
        if !ownsSettingsUI {
            ownsSettingsUI = true
            Self.activeTransactions += 1
            Self.lastRouteActivity = ContinuousClock.now
            let front = NSWorkspace.shared.frontmostApplication
            preserveSettingsUI = false
            if previousApplication == nil { previousApplication = front }
            DiagnosticLog.record("settings.transaction.begin", fields:["preserveUserWindow":String(preserveSettingsUI)])
        }
        if settings == nil || settings?.isTerminated == true {
            settings=NSRunningApplication.runningApplications(withBundleIdentifier:settingsID).first
            if settings == nil {
                launchedSettings=true
                let config=NSWorkspace.OpenConfiguration();config.activates=false;config.hides=true
                let pid:pid_t = try await withCheckedThrowingContinuation { continuation in
                    let result=SettingsLaunchResult(continuation)
                    Task { @MainActor in
                        try? await Task.sleep(for:.seconds(3))
                        result.finish(.failure(Failure(message:"打开豆包设置超时")))
                    }
                    NSWorkspace.shared.openApplication(at:settingsURL,configuration:config) { app,error in
                        let pid=app?.processIdentifier
                        let message=error?.localizedDescription ?? "未知错误"
                        Task { @MainActor in
                            if let pid {result.finish(.success(pid))}
                            else {result.finish(.failure(Failure(message:"无法打开豆包输入法设置：\(message)")))}
                        }
                    }
                }
                settings=NSRunningApplication(processIdentifier:pid)
            }
        }
        guard let settings else { throw Failure(message:"豆包设置进程不可用") }
        let app=AXUIElementCreateApplication(settings.processIdentifier)
        AXUIElementSetMessagingTimeout(app,0.6)
        return app
    }
    private func value(_ node:AXUIElement,_ attribute:String)->CFTypeRef? {
        if let transitionDeadline,ContinuousClock.now>=transitionDeadline{return nil}
        var result:CFTypeRef?
        guard AXUIElementCopyAttributeValue(node,attribute as CFString,&result) == .success else{return nil}
        return result
    }
    private func text(_ node:AXUIElement)->String {
        for key in [kAXTitleAttribute,kAXValueAttribute,kAXDescriptionAttribute,kAXIdentifierAttribute] {
            if let s=value(node,key) as? String,!s.isEmpty{return s}
        }
        return ""
    }
    private func nodes(_ root:AXUIElement) throws -> [AXUIElement] {
        try checkDeadline()
        // 直接从主窗口子树开始：应用根节点还会带出整个菜单栏，纯属浪费。
        var pending:[(AXUIElement,Int)]
        if let windows=value(root,kAXWindowsAttribute) as? [AXUIElement],let first=windows.first {pending=[(first,0)]}
        else {pending=[(root,0)]}
        var result=[AXUIElement]()
        let deadline=ContinuousClock.now.advanced(by:.seconds(4))
        while let (node,depth)=pending.popLast() {
            try checkDeadline()
            guard result.count<300,ContinuousClock.now<deadline else{throw Failure(message:"豆包设置界面读取超时或结构过大")}
            result.append(node)
            if depth<12,let children=value(node,kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf:children.map{($0,depth+1)})
            }
        }
        return result
    }
    private func press(_ node:AXUIElement) throws {
        try checkDeadline()
        guard AXUIElementPerformAction(node,kAXPressAction as CFString) == .success else {
            throw Failure(message:"豆包设置控件不支持自动操作，请保持设置窗口可用")
        }
    }
    private func buttons(_ list:[AXUIElement])->[AXUIElement] {
        list.filter{value($0,kAXRoleAttribute) as? String == kAXButtonRole}
    }
    private func closePicker(_ list:[AXUIElement]) throws -> Bool {
        let close=buttons(list).filter{text($0) == "onboarding_close_icon" || (value($0,kAXIdentifierAttribute) as? String) == "onboarding_close_icon"}
        if close.count==1 {try press(close[0]);return true}
        return false
    }
    private func mainNodes() async throws -> [AXUIElement] {
        let root=try await appElement()
        for _ in 0..<10 {
            try checkDeadline()
            // The helper window may materialize late after a relaunch; minimize
            // it the moment it exists to keep the on-screen flash as short as
            // possible. Re-minimizing is idempotent.
            minimizeSettingsWindows()
            var list=try nodes(root)
            if list.contains(where:{text($0)=="选择麦克风"}) {
                guard try closePicker(list) else {throw Failure(message:"请关闭豆包的麦克风选择列表后重试")}
                try await Task.sleep(for:.milliseconds(80));list=try nodes(root)
            }
            let d=try devices()
            if buttons(list).contains(where:{let s=text($0);return s==d.virtual || s==d.builtIn || s.hasPrefix("自动检测（")}) {
                return list
            }
            let voice=buttons(list).filter{text($0)=="语音输入"}
            if voice.count==1 {try press(voice[0])}
            try await Task.sleep(for:.milliseconds(120))
        }
        throw Failure(message:"未找到豆包麦克风选择控件，设置界面可能已变化")
    }
    func selectRoute(_ route:VoiceInputRoute) async throws { try await selectRoute(route,known:nil) }
    func selectRoute(_ route:VoiceInputRoute,known:[AXUIElement]?=nil) async throws {
        if route == .virtual,AudioCatalog.devices(input:true).filter({$0.name == "MiRemoteV 2ch"}).count != 1 {
            throw Failure(message:"未能唯一找到 MiRemoteV 2ch，保留电脑麦克风")
        }
        let d=try devices()
        let list:[AXUIElement]
        if let known {list=known}else{list=try await mainNodes()}
        let selector=buttons(list).filter{let s=text($0);return s==d.virtual || s==d.builtIn || s.hasPrefix("自动检测（")}
        guard selector.count==1 else{throw Failure(message:"豆包麦克风控件不唯一")}
        try press(selector[0])
        let root=try await appElement(),target=route == .virtual ? d.virtual:d.builtIn
        for _ in 0..<12 {
            try checkDeadline()
            let options=try nodes(root)
            guard options.contains(where:{text($0)=="选择麦克风"}) else {
                try await Task.sleep(for:.milliseconds(100));continue
            }
            let candidates=buttons(options).filter{text($0)==target}
            // The settings summary may also contain the same name; an AX button
            // inside the picker must be unique unless it is already selected.
            if candidates.count==1 {
                minimizeSettingsWindows()
                try press(candidates[0])
                try await Task.sleep(for:.milliseconds(100))
                let after=try nodes(root)
                _ = try closePicker(after)
                logger.notice("已请求选择豆包麦克风：\(target,privacy:.public)")
                return
            }
            throw Failure(message:"麦克风列表中目标设备不唯一或不存在：\(target)")
        }
        throw Failure(message:"豆包麦克风列表未响应")
    }
    // Minimized windows remain AX-readable for the automation, but they strand
    // a thumbnail in the Dock. So the helper stays alive (fast repeated
    // switches) while voice activity continues, and is terminated once it has
    // been idle for a while, which clears the Dock thumbnail again.
    private func minimizeSettingsWindows() {
        guard let settings else {return}
        let root=AXUIElementCreateApplication(settings.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.6)
        var minimized=0
        if let windows=value(root,kAXWindowsAttribute) as? [AXUIElement] {
            for window in windows {
                if AXUIElementSetAttributeValue(window,kAXMinimizedAttribute as CFString,kCFBooleanTrue) == .success {minimized += 1}
            }
        }
        if !preparedBackground {
            preparedBackground=true
            DiagnosticLog.record("settings.background",fields:["minimizedWindows":String(minimized)])
        }
    }
    // 常驻看门狗：按包名现查现杀（不依赖缓存引用），防止缩略图常驻。
    // 豆包自家可能随时拉起设置助手，所以用周期巡检而不是一次性定时。
    // 关键：生命周期与遥控会话各有一个驱动实例，看门狗和活动时钟必须全实例共享，
    // 否则一个实例的旧时钟会把另一个实例刚用完的豆包设置杀掉。
    private static var watchdogTask:Task<Void,Never>?
    private static var lastRouteActivity=ContinuousClock.now
    private static var activeTransactions=0
    private static func startIdleWatchdog(){
        guard watchdogTask==nil else {return}
        watchdogTask=Task {
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30))
                guard activeTransactions==0 else {continue}
                guard ContinuousClock.now >= lastRouteActivity.advanced(by:.seconds(90)) else {continue}
                // 用户正盯着设置窗口时不杀。
                let bundleID = "com.bytedance.inputmethod.doubaoime.settings"
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID else {continue}
                guard let settings=NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first else {continue}
                settings.terminate()
                try? await Task.sleep(for:.seconds(1))
                if !settings.isTerminated {settings.terminate()}
                try? await Task.sleep(for:.seconds(1))
                if !settings.isTerminated {kill(settings.processIdentifier,SIGTERM)}
                DiagnosticLog.record("settings.idle.terminate",fields:["pid":String(settings.processIdentifier)])
            }
        }
    }
    func finishUI(){
        transitionDeadline=nil
        if ownsSettingsUI && !preserveSettingsUI {
            minimizeSettingsWindows()
            DiagnosticLog.record("settings.transaction.finish",fields:["minimized":"true","launched":String(launchedSettings)])
        }
        preparedBackground=false
        ownsSettingsUI=false
        preserveSettingsUI=false
        launchedSettings=false
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == settingsID,
           let previousApplication,!previousApplication.isTerminated {previousApplication.activate(options:[])}
        previousApplication=nil
        Self.activeTransactions = max(0,Self.activeTransactions-1)
        Self.lastRouteActivity = ContinuousClock.now
    }
}

@MainActor private final class SettingsLaunchResult {
    private var continuation:CheckedContinuation<pid_t,any Error>?
    init(_ continuation:CheckedContinuation<pid_t,any Error>){self.continuation=continuation}
    func finish(_ result:Result<pid_t,any Error>){guard let continuation else{return};self.continuation=nil;continuation.resume(with:result)}
}
