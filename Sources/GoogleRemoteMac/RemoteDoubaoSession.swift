import Foundation

// Only remote speech owns this transaction. Native Doubao speech uses the
// built-in microphone directly and never depends on our keyboard listener.
@MainActor protocol RemoteSpeechDriver: AnyObject {
    func selectVerified(_ route: VoiceInputRoute) async throws
    func beginAudio() throws
    func feedAudio(_ pcm: [Int16])
    func finishAudio() async throws
    func cancelAudio()
    func checkAudio() throws
}

@MainActor final class RemoteDoubaoSession {
    private let driver: any RemoteSpeechDriver
    private var worker: Task<Void, Never>?
    private var buffered = [Int16]()
    private var streaming = false
    private var ending = false
    private var cancelled = false
    private var failure: String?
    private var capacity = 0
    private var sessionID=UUID()
    private var receivedSamples=0
    private var started=ContinuousClock.now
    var active: Bool { worker != nil }
    var completed: ((String, Bool) -> Void)?

    init(driver: any RemoteSpeechDriver) { self.driver = driver }

    func begin(maxSamples: Int) {
        guard worker == nil else { return }
        buffered = []; streaming = false; ending = false; cancelled = false
        failure = nil; capacity = maxSamples
        sessionID=UUID();receivedSamples=0;started = .now
        DiagnosticLog.record("remote.begin",session:sessionID)
        worker = Task { await run() }
    }
    func feed(_ pcm: [Int16]) {
        guard active, !ending, !cancelled else { return }
        receivedSamples += pcm.count
        if streaming { driver.feedAudio(pcm) }
        else if buffered.count + pcm.count <= capacity { buffered.append(contentsOf: pcm) }
        else { DiagnosticLog.record("remote.buffer.full",session:sessionID);failure = "遥控器音频缓存已满"; ending = true; cancelled = true }
    }
    func finish() { if active {DiagnosticLog.record("remote.release",session:sessionID,fields:["samples":String(receivedSamples),"preparing":String(!streaming)])};ending = true }
    func cancel() { if active {DiagnosticLog.record("remote.cancel",session:sessionID)};cancelled = true; ending = true; driver.cancelAudio() }
    func waitUntilFinished() async { await worker?.value }

    private func elapsedMilliseconds()->String {let d=started.duration(to:.now).components;return String(d.seconds*1000+d.attoseconds/1_000_000_000_000_000)}

    private func run() async {
        var message = "遥控器声音已交给豆包，已恢复电脑麦克风"
        var restored = false
        do {
            if !cancelled { try await driver.selectVerified(.virtual)
                DiagnosticLog.record("remote.virtual.ready",session:sessionID,fields:["elapsedMs":elapsedMilliseconds(),"bufferedSamples":String(buffered.count)])
            }
            if !cancelled, !buffered.isEmpty || !ending {
                try driver.beginAudio()
                DiagnosticLog.record("remote.audio.begin",session:sessionID)
                streaming = true
                driver.feedAudio(buffered); buffered = []
                while !ending && !cancelled {
                    try driver.checkAudio()
                    try await Task.sleep(for: .milliseconds(20))
                }
                streaming = false
                if cancelled { driver.cancelAudio() }
                else { try await driver.finishAudio();DiagnosticLog.record("remote.audio.drained",session:sessionID) }
            }
            if cancelled { message = failure ?? "遥控器录音已停止" }
        } catch { DiagnosticLog.record("remote.error",session:sessionID,fields:["domain":(error as NSError).domain,"code":String((error as NSError).code)]);message = "遥控器语音未完成：\(error.localizedDescription)" }
        streaming = false; driver.cancelAudio(); buffered = []
        // Restore even if selection, shortcut posting or playback failed.
        do { try await driver.selectVerified(.builtIn); restored = true }
        catch {DiagnosticLog.record("remote.restore.error",session:sessionID,fields:["domain":(error as NSError).domain,"code":String((error as NSError).code)]);message += "；恢复电脑麦克风失败：\(error.localizedDescription)" }
        DiagnosticLog.record("remote.complete",session:sessionID,fields:["restored":String(restored),"cancelled":String(cancelled),"samples":String(receivedSamples),"elapsedMs":elapsedMilliseconds()])
        worker = nil
        completed?(message, restored)
    }
}
