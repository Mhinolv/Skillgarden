import CoreGraphics

/// The clip of the video player at the top of the lecture page (#55).
/// The page scrolls under the transparent title bar. The black player must not cover the window title or the toolbar.
public enum PlayerClip {
    /// The height at the top of the player that is above `visibleTop`, from 0 to `height`.
    /// The values use window coordinates that go down. `visibleTop` is the bottom edge of the toolbar.
    public static func hiddenTop(playerMinY: CGFloat, height: CGFloat, visibleTop: CGFloat) -> CGFloat {
        guard height > 0, playerMinY.isFinite, visibleTop.isFinite else { return 0 }
        return min(max(visibleTop - playerMinY, 0), height)
    }
}
