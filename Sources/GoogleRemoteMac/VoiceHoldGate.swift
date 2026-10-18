// A hardware poll must never release a hold confirmed by an event.
struct VoiceHoldGate {
    enum Owner { case event, poll }
    private(set) var owner: Owner?
    private var previousPoll = false
    mutating func event(_ down: Bool) -> Bool? {
        if down {
            let started = owner == nil
            owner = .event
            return started ? true : nil
        }
        guard owner != nil else { return nil }
        owner = nil
        return false
    }
    mutating func poll(_ down: Bool) -> Bool? {
        defer { previousPoll = down }
        if down && !previousPoll && owner == nil { owner = .poll; return true }
        if !down && owner == .poll { owner = nil; return false }
        return nil
    }
    mutating func reset() { owner = nil; previousPoll = false }
}
