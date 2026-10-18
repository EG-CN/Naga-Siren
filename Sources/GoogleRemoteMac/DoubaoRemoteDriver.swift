import Foundation

@MainActor final class DoubaoRemoteDriver: RemoteSpeechDriver {
    private let route: DoubaoSettingsRouteDriver
    private let bridge = DoubaoBridge()
    private var completion: CheckedContinuation<Void, any Error>?
    private var earlyFailure: String?
    init(capture: AudioCapture) { route = DoubaoSettingsRouteDriver(capture: capture) }
    func selectVerified(_ target: VoiceInputRoute) async throws { try await route.selectVerified(target) }
    func beginAudio() throws {
        earlyFailure = nil
        bridge.finished = { [weak self] message in
            guard let self else { return }
            let failed = message.contains("超时")
            if let completion = self.completion {
                self.completion = nil
                if failed { completion.resume(throwing: DoubaoBridge.BridgeError(message)) }
                else { completion.resume() }
            } else if failed { self.earlyFailure = message }
        }
        try bridge.begin()
    }
    func feedAudio(_ pcm: [Int16]) { if !pcm.isEmpty { bridge.feed(pcm) } }
    func checkAudio() throws {
        if let earlyFailure { throw DoubaoBridge.BridgeError(earlyFailure) }
    }
    func finishAudio() async throws {
        if let earlyFailure { throw DoubaoBridge.BridgeError(earlyFailure) }
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            bridge.finish()
        }
    }
    func cancelAudio() {
        bridge.cancel()
        if let completion { self.completion = nil; completion.resume(throwing: CancellationError()) }
    }
}
