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
