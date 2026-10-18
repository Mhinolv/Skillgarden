/// The Left Arrow and Right Arrow skip on a video lecture page (#104).
/// Left Arrow moves playback back 10 seconds. Right Arrow moves it forward 10 seconds.
public enum VideoSkip {
    /// The length of one skip in seconds.
    public static let step: Double = 10

    /// The key code of Left Arrow.
    public static let leftArrowKeyCode: UInt16 = 123
    /// The key code of Right Arrow.
    public static let rightArrowKeyCode: UInt16 = 124

    /// The skip of a key: −10 for Left Arrow and +10 for Right Arrow.
    /// Nil for other keys and for an arrow with a modifier, so ⌥⌘← and ⌥⌘→ stay with the Go menu.
    public static func delta(keyCode: UInt16, hasModifiers: Bool) -> Double? {
        guard !hasModifiers else { return nil }
        switch keyCode {
        case leftArrowKeyCode: return -step
        case rightArrowKeyCode: return step
        default: return nil
        }
    }

    /// The seek time of a skip, clamped to `0...duration`.
    /// A nil, zero or unknown duration clamps at 0 only.
    public static func target(current: Double, delta: Double, duration: Double?) -> Double {
        let start = current.isFinite ? max(current, 0) : 0
        var seconds = max(start + delta, 0)
        if let duration, duration.isFinite, duration > 0 { seconds = min(seconds, duration) }
        return seconds
    }
}
