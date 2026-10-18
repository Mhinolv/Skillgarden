import CoreGraphics

/// Theater mode of a video lecture (#85). Theater hides the sidebar and removes the width cap of the player.
/// The window keeps the mode for all video lectures. A page that is not a video lecture ends it.
/// Each change returns the sidebar state to apply: true hides the sidebar, false shows it, nil keeps it.
public struct TheaterMode: Equatable, Sendable {
    public private(set) var isOn = false
    /// The sidebar state before theater started. The end of theater restores it.
    private var sidebarWasHidden = false

    /// The width cap of the player, the controls row, the transcript and the quick checks outside theater.
    /// In theater, the transcript and the quick checks keep it.
    public static let videoWidth: CGFloat = 960

    public init() {}

    /// The width cap of the player and its controls row. Nil fills the page column.
    public var playerMaxWidth: CGFloat? { isOn ? nil : Self.videoWidth }

    /// Starts or ends theater. `sidebarHidden` is the sidebar state now.
    public mutating func set(_ on: Bool, sidebarHidden: Bool) -> Bool? {
        guard on != isOn else { return nil }
        if on {
            isOn = true
            sidebarWasHidden = sidebarHidden
            return true
        }
        return end()
    }

    /// Ends theater and restores the sidebar. Escape calls it.
    public mutating func end() -> Bool? {
        guard isOn else { return nil }
        isOn = false
        return sidebarWasHidden
    }

    /// The learner showed the sidebar (View > Show Sidebar, ⌃⌘S or the toolbar button). Theater ends and the sidebar stays.
    public mutating func sidebarChanged(hidden: Bool) {
        if isOn && !hidden { isOn = false }
    }

    /// The page changed. Theater stays on for a video lecture and ends on every other page.
    public mutating func pageChanged(showsVideo: Bool) -> Bool? {
        showsVideo ? nil : end()
    }
}
