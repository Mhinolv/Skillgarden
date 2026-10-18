/// The "Up next" countdown of a video lecture (#99). At the video end it opens the next outline lecture.
/// If the quick-check card opens with an unanswered check, the countdown waits for the last answer or "Close".
/// Cancel, Escape, a play or a seek stops it.
public struct UpNextCountdown: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off
        /// The video ended and the quick-check card is open. The countdown starts after the last answer or "Close".
        case waitsForQuickChecks
        /// The overlay shows. The value is the number of seconds left.
        case counts(Int)
    }

    /// The overlay shows "Starts in 5", then 4, 3, 2 and 1.
    public static let seconds = 5

    public private(set) var phase = Phase.off

    public init() {}

    /// Nil when the overlay does not show.
    public var secondsLeft: Int? {
        if case let .counts(seconds) = phase { seconds } else { nil }
    }

    public var showsOverlay: Bool { secondsLeft != nil }

    /// "Starts in 5". Nil when the overlay does not show.
    public var startsLabel: String? { secondsLeft.map { "Starts in \($0)" } }

    /// The video played to the end. `autoPlays` is false when the setting is off or no next lecture exists.
    /// `waitsForQuickChecks` is true when the quick-check card opens with an unanswered check.
    public mutating func videoEnded(autoPlays: Bool, waitsForQuickChecks: Bool) {
        guard autoPlays else { phase = .off; return }
        phase = waitsForQuickChecks ? .waitsForQuickChecks : .counts(Self.seconds)
    }

    /// The learner answered the last check or closed the card. Returns true if the countdown starts.
    @discardableResult
    public mutating func quickChecksDone() -> Bool {
        guard phase == .waitsForQuickChecks else { return false }
        phase = .counts(Self.seconds)
        return true
    }

    /// One second passed. Returns true when the countdown reaches 0: open the next lecture.
    public mutating func tick() -> Bool {
        guard let secondsLeft else { return false }
        if secondsLeft > 1 {
            phase = .counts(secondsLeft - 1)
            return false
        }
        phase = .off
        return true
    }

    /// "Play Now". Returns true if the overlay showed: open the next lecture.
    public mutating func playNow() -> Bool {
        guard showsOverlay else { return false }
        phase = .off
        return true
    }

    /// Cancel, Escape, a play or a seek. The page stays.
    public mutating func cancel() {
        phase = .off
    }
}
