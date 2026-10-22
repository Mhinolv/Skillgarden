import Testing
@testable import SkillgardenCore

/// #104: Left Arrow skips back 10 seconds and Right Arrow skips forward 10 seconds.
@Test func videoSkipArrowsStepTenSeconds() {
    #expect(VideoSkip.step == 10)
    #expect(VideoSkip.delta(keyCode: VideoSkip.leftArrowKeyCode, hasModifiers: false) == -10)
    #expect(VideoSkip.delta(keyCode: VideoSkip.rightArrowKeyCode, hasModifiers: false) == 10)
    #expect(VideoSkip.target(current: 42, delta: -10, duration: 120) == 32)
    #expect(VideoSkip.target(current: 42, delta: 10, duration: 120) == 52)
}

/// #104: an arrow with a modifier (⌥⌘← and ⌥⌘→ of the Go menu) and other keys do not skip.
@Test func videoSkipIgnoresModifiersAndOtherKeys() {
    #expect(VideoSkip.delta(keyCode: VideoSkip.leftArrowKeyCode, hasModifiers: true) == nil)
    #expect(VideoSkip.delta(keyCode: VideoSkip.rightArrowKeyCode, hasModifiers: true) == nil)
    #expect(VideoSkip.delta(keyCode: 125, hasModifiers: false) == nil) // Down Arrow
    #expect(VideoSkip.delta(keyCode: 126, hasModifiers: false) == nil) // Up Arrow
    #expect(VideoSkip.delta(keyCode: 49, hasModifiers: false) == nil) // Space
}

/// #104: the time stays within 0 and the video duration.
@Test func videoSkipClampsToTheVideo() {
    // Near the start, Left Arrow stops at 0.
    #expect(VideoSkip.target(current: 4, delta: -10, duration: 120) == 0)
    #expect(VideoSkip.target(current: 0, delta: -10, duration: 120) == 0)
    // Near the end, Right Arrow stops at the duration.
    #expect(VideoSkip.target(current: 115, delta: 10, duration: 120) == 120)
    // At the end, Right Arrow keeps the time.
    #expect(VideoSkip.target(current: 120, delta: 10, duration: 120) == 120)
    #expect(VideoSkip.target(current: 120, delta: -10, duration: 120) == 110)
    // A video shorter than one step.
    #expect(VideoSkip.target(current: 3, delta: 10, duration: 5) == 5)
    #expect(VideoSkip.target(current: 3, delta: -10, duration: 5) == 0)
}

/// #104: an unknown duration clamps at 0 only. A bad current time counts as 0.
@Test func videoSkipWithAnUnknownDurationOrTime() {
    #expect(VideoSkip.target(current: 30, delta: 10, duration: nil) == 40)
    #expect(VideoSkip.target(current: 30, delta: 10, duration: .nan) == 40)
    #expect(VideoSkip.target(current: 30, delta: 10, duration: 0) == 40)
    #expect(VideoSkip.target(current: 5, delta: -10, duration: nil) == 0)
    #expect(VideoSkip.target(current: .nan, delta: 10, duration: 120) == 10)
    #expect(VideoSkip.target(current: -3, delta: -10, duration: 120) == 0)
    #expect(VideoSkip.target(current: 130, delta: -10, duration: 120) == 120)
}

/// #177 and #186: full screen uses the #104 rules. Modifiers, other keys, a sheet, a text field and a window that is not key
/// return the event.
@Test func videoSkipFullScreenKeepsTheKeyRules() {
    let right = VideoSkip.rightArrowKeyCode
    #expect(VideoSkip.delta(keyCode: right, hasModifiers: true, in: .init(isPage: false, playerIsFullScreen: true)) == nil)
    #expect(VideoSkip.delta(keyCode: 53, hasModifiers: false, in: .init(isPage: false, playerIsFullScreen: true)) == nil) // Escape
    #expect(VideoSkip.delta(keyCode: 49, hasModifiers: false, in: .init(isPage: false, playerIsFullScreen: true)) == nil) // Space
    #expect(VideoSkip.delta(keyCode: right, hasModifiers: false, in: .init(isPage: false, playerIsFullScreen: true, hasSheet: true)) == nil)
    #expect(VideoSkip.delta(keyCode: right, hasModifiers: false, in: .init(isPage: false, playerIsFullScreen: true, keepsArrows: true)) == nil)
    #expect(VideoSkip.delta(keyCode: right, hasModifiers: false, in: .init(isPage: false, playerIsFullScreen: true, isKey: false)) == nil)
    // Another window while the page player is not in full screen (before the delegate sets the state, or after the exit) does not skip.
    #expect(VideoSkip.delta(keyCode: right, hasModifiers: false, in: .init(isPage: false)) == nil)
}

/// #186: the full-screen state comes from the `AVPlayerViewDelegate` callbacks, not from a view search.
/// The real AVKit full-screen window does not show the page player to a view search, so the delegate state alone skips.
@Test func videoSkipArrowsInFullScreenFromTheDelegateState() {
    let fullScreen = VideoSkip.EventWindow(isPage: false, playerIsFullScreen: true)
    #expect(VideoSkip.delta(keyCode: VideoSkip.leftArrowKeyCode, hasModifiers: false, in: fullScreen) == -10)
    #expect(VideoSkip.delta(keyCode: VideoSkip.rightArrowKeyCode, hasModifiers: false, in: fullScreen) == 10)
}

/// #104 and #177: the lecture page window keeps the same rules outside full screen.
@Test func videoSkipPageWindowRules() {
    let left = VideoSkip.leftArrowKeyCode
    #expect(VideoSkip.delta(keyCode: left, hasModifiers: false, in: .init(isPage: true)) == -10)
    #expect(VideoSkip.delta(keyCode: left, hasModifiers: true, in: .init(isPage: true)) == nil)
    #expect(VideoSkip.delta(keyCode: left, hasModifiers: false, in: .init(isPage: true, isKey: false)) == nil)
    #expect(VideoSkip.delta(keyCode: left, hasModifiers: false, in: .init(isPage: true, hasSheet: true)) == nil)
    #expect(VideoSkip.delta(keyCode: left, hasModifiers: false, in: .init(isPage: true, keepsArrows: true)) == nil)
}

/// #236: after Play from the sidebar, the player has the keyboard. Space plays and pauses, and the arrows skip.
@Test func videoPlayGivesThePlayerTheKeyboard() {
    for current in [VideoKeyFocus.Holder.sidebar, .other, .player] {
        let holder = VideoKeyFocus.holder(afterPlayStartsWith: current)
        #expect(holder == .player)
        let window = VideoSkip.EventWindow(isPage: true, keepsArrows: holder.keepsArrows)
        #expect(VideoSkip.delta(keyCode: VideoSkip.leftArrowKeyCode, hasModifiers: false, in: window) == -10)
        #expect(VideoSkip.delta(keyCode: VideoSkip.rightArrowKeyCode, hasModifiers: false, in: window) == 10)
    }
}

/// #236, #128 and #181: a Q&A or notes field keeps the focus when playback starts, so Space types a space.
@Test func videoPlayKeepsTheTextFieldFocus() {
    let holder = VideoKeyFocus.holder(afterPlayStartsWith: .textField)
    #expect(holder == .textField)
    #expect(VideoSkip.delta(keyCode: VideoSkip.leftArrowKeyCode, hasModifiers: false,
                            in: .init(isPage: true, keepsArrows: holder.keepsArrows)) == nil)
    #expect(VideoKeyFocus.Holder.sidebar.keepsArrows)
    #expect(!VideoKeyFocus.Holder.player.keepsArrows)
    #expect(!VideoKeyFocus.Holder.other.keepsArrows)
}
