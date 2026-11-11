import Foundation

/// Tracks whether a delivered lookup still belongs to the current refresh.
public struct LocalLyricsRefreshState {
    public private(set) var sessionToken: UUID?
    public private(set) var generation = 0
    public enum Phase { case idle, waitingForActivation, loading }
    public private(set) var phase = Phase.idle
    public var inFlight: Bool { phase != .idle }
    public private(set) var lastCompleted: Date?

    public init() {}

    @discardableResult
    public mutating func receiveActivation(_ token: UUID?) -> Bool {
        guard sessionToken != token || (phase == .waitingForActivation && token != nil) else { return false }
        sessionToken = token
        invalidate()
        return true
    }

    public mutating func invalidate() {
        generation += 1
        phase = .idle
        lastCompleted = nil
    }

    public mutating func waitForActivation() {
        guard phase != .waitingForActivation else { return }
        invalidate()
        phase = .waitingForActivation
    }

    public mutating func begin() -> Int {
        generation += 1
        phase = .loading
        return generation
    }

    @discardableResult
    public mutating func accept(_ stage: LocalLyricsRefreshStage, generation: Int, now: Date = Date()) -> Bool {
        guard self.generation == generation, phase == .loading else { return false }
        if stage == .cancelled { invalidate(); return true }
        phase = stage == .complete ? .idle : .loading
        if stage == .complete { lastCompleted = now }
        return true
    }
}
