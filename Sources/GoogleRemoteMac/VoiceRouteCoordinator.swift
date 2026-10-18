import Foundation
import Combine

enum VoiceInputRoute: Equatable {
    case virtual, builtIn, systemDefault
    var description: String { switch self {case .virtual:return "MiRemoteV 2ch";case .builtIn:return "MacBook Air 麦克风";case .systemDefault:return "系统默认麦克风"} }
}

enum VoiceRouteState: Equatable {
    case unknown, switching(VoiceInputRoute), ready, paused, failed(String)
    var description: String {
        switch self {
        case .unknown: return "尚未检查豆包麦克风"
        case .switching(let route): return "正在切换到\(route.description)…"
        case .ready: return "遥控器已就绪 · 豆包原生语音使用电脑麦克风"
        case .paused: return "已暂停，豆包使用电脑麦克风"
        case .failed(let message): return message
        }
    }
}

// The adapter bounds each asynchronous operation and waits for external voice
// sessions to become idle before changing Doubao's own microphone selection.
@MainActor protocol VoiceRouteDriver: AnyObject {
    func selectedRoute() async throws -> VoiceInputRoute
    func selectRoute(_ route: VoiceInputRoute) async throws
    func stopNewSessions()
    func endOwnedSession() async throws
    func startNewSessions() async throws
}

@MainActor final class VoiceRouteCoordinator: ObservableObject {
    @Published private(set) var state: VoiceRouteState = .unknown
    @Published private(set) var wantsEnabled = false
    @Published private(set) var quitting = false
    private let driver: any VoiceRouteDriver
    private var revision: UInt64 = 0
    private var worker: Task<Void, Never>?

    init(driver: any VoiceRouteDriver) { self.driver = driver }

    func request(enabled: Bool) {
        guard !quitting || !enabled else { return }
        DiagnosticLog.record("lifecycle.request",fields:["enabled":String(enabled),"quitting":String(quitting)])
        wantsEnabled = enabled
        revision &+= 1
        driver.stopNewSessions()
        state = .switching(.builtIn)
        if worker == nil { worker = Task { await reconcile() } }
    }

    func waitUntilSettled() async { await worker?.value }

    func prepareToQuit() async -> Bool {
        quitting = true
        request(enabled: false)
        await waitUntilSettled()
        let restored = state == .paused
        // A failed quit leaves the app available to retry or resume explicitly.
        if !restored { quitting = false }
        DiagnosticLog.record("app.quit",fields:["restored":String(restored)])
        return restored
    }

    func cancelQuit() { quitting = false }

    private func reconcile() async {
        defer { worker = nil }
        while true {
            let id = revision
            let enabled = wantsEnabled
            let target: VoiceInputRoute = .builtIn
            var sessionEnded = false
            do {
                try await driver.endOwnedSession()
                sessionEnded = true
                if id != revision { continue }
                let before = try await driver.selectedRoute()
                if id != revision { continue }
                if before != target {
                    try await driver.selectRoute(target)
                    if id != revision { continue }
                }
                let actual = try await driver.selectedRoute()
                if id != revision { continue }
                guard actual == target else {
                    throw RouteFailure(message: "豆包麦克风选择未确认，请重试")
                }
                if enabled {
                    try await driver.startNewSessions()
                    if id != revision {driver.stopNewSessions();continue}
                    DiagnosticLog.record("lifecycle.ready",fields:["route":"builtin"])
                    state = .ready
                } else {
                    DiagnosticLog.record("lifecycle.paused",fields:["route":"builtin"])
                    state = .paused
                }
                return
            } catch {
                if id != revision { continue }
                driver.stopNewSessions()
                DiagnosticLog.record("lifecycle.error",fields:["domain":(error as NSError).domain,"code":String((error as NSError).code)])
                let reason = error.localizedDescription
                // Once preparation succeeded, a failed activation must not
                // strand Doubao on a silent virtual microphone. Compensation
                // is attempted once, verified, and never reported as ready.
                var recovery = ""
                if enabled && sessionEnded {
                    recovery = await restoreBuiltInAfterFailure(revision: id)
                    if id != revision { continue }
                }
                state = .failed("语音切换未完成：\(reason)\(recovery)")
                return
            }
        }
    }

    private struct RouteFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func restoreBuiltInAfterFailure(revision id: UInt64) async -> String {
        do {
            let actual = try await driver.selectedRoute()
            guard id == revision else { return "" }
            if actual == .builtIn { return "；豆包仍使用电脑麦克风" }
            // Only undo a confirmed virtual route. An unrecognized or system
            // default route is not evidence that this activation changed it.
            guard actual == .virtual else { return "；未改动豆包当前麦克风" }
            try await driver.selectRoute(.builtIn)
            guard id == revision else { return "" }
            let restored = try await driver.selectedRoute()
            guard id == revision else { return "" }
            guard restored == .builtIn else {
                return "；恢复电脑麦克风未确认，请在豆包设置中检查"
            }
            return "；已恢复豆包电脑麦克风"
        } catch {
            return "；恢复电脑麦克风失败：\(error.localizedDescription)"
        }
    }

}
