/// The keyboard focus when a video lecture starts to play (#236).
/// Play (click or Space), Up next auto-play and a transcript line click give the player the keyboard.
/// Space then plays and pauses, and Left Arrow and Right Arrow skip 10 seconds (#104).
public enum VideoKeyFocus {
    /// The view that has the keyboard focus of the lecture window.
    public enum Holder: Sendable, Equatable {
        /// The sidebar outline (an `NSTableView`).
        case sidebar
        /// The Q&A question field or a notes field (#128, #181).
        case textField
        /// The AVKit player view.
        case player
        /// A button, the page or no view.
        case other

        /// A text field and the sidebar keep the arrows, so the page does not skip (#104).
        public var keepsArrows: Bool { self == .sidebar || self == .textField }
    }

    /// The holder after playback starts. A text field keeps the focus, so Space types a space (#128, #181).
    public static func holder(afterPlayStartsWith current: Holder) -> Holder {
        current == .textField ? .textField : .player
    }
}
