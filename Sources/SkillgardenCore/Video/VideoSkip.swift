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

    /// The window of an arrow key event, as a video lecture page sees it (#104, #177).
    public struct EventWindow: Sendable, Equatable {
        /// The event window is the window of the lecture page.
        public var isPage: Bool
        /// The event window hosts the `AVPlayerView` of this page, for example the AVKit full-screen window (#85).
        public var hostsPlayer: Bool
        public var isKey: Bool
        public var hasSheet: Bool
        /// The first responder of the event window keeps the arrows: a text field or the sidebar.
        public var keepsArrows: Bool

        public init(isPage: Bool, hostsPlayer: Bool = false, isKey: Bool = true, hasSheet: Bool = false, keepsArrows: Bool = false) {
            self.isPage = isPage
            self.hostsPlayer = hostsPlayer
            self.isKey = isKey
            self.hasSheet = hasSheet
            self.keepsArrows = keepsArrows
        }
    }

    /// The skip of a key event in `window`. Nil returns the event to AppKit.
    /// The page window and the AVKit full-screen window of the page player both skip (#177).
    public static func delta(keyCode: UInt16, hasModifiers: Bool, in window: EventWindow) -> Double? {
        guard window.isPage || window.hostsPlayer, window.isKey, !window.hasSheet, !window.keepsArrows else { return nil }
        return delta(keyCode: keyCode, hasModifiers: hasModifiers)
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
