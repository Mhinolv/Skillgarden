import Foundation
import Testing
@testable import SkillgardenCore

/// A course with two sections: video "one", draft "hidden", video "two", then article "read" in the next section.
/// "one" has `recommended_next` "read", so a test can see that auto-play ignores it.
@MainActor private func autoPlayLibrary() async throws -> (LibraryModel, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "AutoPlayTests-\(UUID())")
    let store = try CourseStore(root: root)
    try store.saveCourse(Course(id: "c", title: "Course", state: .published, sections: [
        CourseSection(id: "s1", title: "One", order: 0, state: .published, lectures: [
            Lecture(id: "one", title: "One", type: .video, order: 0, state: .published, recommendedNext: "read"),
            Lecture(id: "hidden", title: "Hidden", type: .video, order: 1),
            Lecture(id: "two", title: "Two", type: .video, order: 2, state: .published),
        ]),
        CourseSection(id: "s2", title: "Two", order: 1, state: .published, lectures: [
            Lecture(id: "read", title: "Read", type: .article, order: 0, state: .published),
        ]),
    ]))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("c")
    return (library, root)
}

/// #99: the video end opens `nextLecture` in outline order, not `recommended_next`. A next video starts at once.
@MainActor @Test func autoPlayOpensTheNextOutlineLectureAndStartsANextVideo() async throws {
    let (library, root) = try await autoPlayLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    library.selectDestination(.lecture(sectionID: "s1", lectureID: "one"))
    let next = library.nextLecture
    #expect(next == .lecture(sectionID: "s1", lectureID: "two"))
    #expect(library.nextLectureTitle == "Two")
    #expect(library.playNextLecture())
    #expect(library.destination == next)
    // The new video page starts its player one time only.
    #expect(!library.takeAutoPlay(lectureID: "one"))
    #expect(library.takeAutoPlay(lectureID: "two"))
    #expect(!library.takeAutoPlay(lectureID: "two"))
}

/// #99: a next lecture that is not a video opens its page only.
@MainActor @Test func autoPlayOpensANextArticlePageOnly() async throws {
    let (library, root) = try await autoPlayLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    library.selectDestination(.lecture(sectionID: "s1", lectureID: "two"))
    #expect(library.playNextLecture())
    #expect(library.destination == .lecture(sectionID: "s2", lectureID: "read"))
    #expect(!library.takeAutoPlay(lectureID: "read"))
}

/// #99: with no next lecture, the page stays.
@MainActor @Test func autoPlayStaysOnTheLastLecture() async throws {
    let (library, root) = try await autoPlayLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let last = CourseDestination.lecture(sectionID: "s2", lectureID: "read")
    library.selectDestination(last)
    #expect(library.nextLecture == nil)
    #expect(library.nextLectureTitle == nil)
    #expect(!library.playNextLecture())
    #expect(library.destination == last)
}

/// #99: Next, ⌥⌘→ and an outline click do not start the player. Another open clears a waiting auto-play.
@MainActor @Test func autoPlayStartsOnlyAfterAVideoEnd() async throws {
    let (library, root) = try await autoPlayLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    library.selectDestination(.lecture(sectionID: "s1", lectureID: "one"))
    library.goToNextLecture()
    #expect(!library.takeAutoPlay(lectureID: "two"))
    library.goToPreviousLecture()
    #expect(library.playNextLecture())
    library.goToPreviousLecture()
    library.goToNextLecture()
    #expect(!library.takeAutoPlay(lectureID: "two"))
    library.selectDestination(.lecture(sectionID: "s1", lectureID: "one"))
    #expect(library.playNextLecture())
    library.selectCourse(nil)
    library.selectCourse("c")
    #expect(!library.takeAutoPlay(lectureID: "two"))
}

/// #99: the overlay counts 5, 4, 3, 2, 1, then opens the next lecture.
@Test func upNextCountsFiveSecondsThenOpensTheNextLecture() {
    var upNext = UpNextCountdown()
    #expect(!upNext.showsOverlay)
    let tickWhenOff = upNext.tick()
    #expect(!tickWhenOff)
    upNext.videoEnded(autoPlays: true, waitsForQuickChecks: false)
    var labels: [String] = []
    var opens = false
    while let label = upNext.startsLabel {
        labels.append(label)
        opens = upNext.tick()
    }
    #expect(labels == ["Starts in 5", "Starts in 4", "Starts in 3", "Starts in 2", "Starts in 1"])
    #expect(opens)
    #expect(upNext.phase == .off)
}

/// The results of `quickChecksDone()`, `playNow()` and `tick()` in that order.
private func tryEachStep(_ upNext: inout UpNextCountdown) -> [Bool] {
    [upNext.quickChecksDone(), upNext.playNow(), upNext.tick()]
}

/// #99: with Auto-play off or no next lecture, the video end shows no overlay.
@Test func upNextShowsNothingWhenAutoPlayIsOff() {
    for waits in [false, true] {
        var upNext = UpNextCountdown()
        upNext.videoEnded(autoPlays: false, waitsForQuickChecks: waits)
        #expect(upNext.phase == .off)
        #expect(tryEachStep(&upNext) == [false, false, false])
    }
}

/// #99 owner decision: open quick checks hold the countdown until the last answer or "Close".
@Test func upNextWaitsForTheQuickChecks() {
    var upNext = UpNextCountdown()
    upNext.videoEnded(autoPlays: true, waitsForQuickChecks: true)
    #expect(upNext.phase == .waitsForQuickChecks)
    #expect(!upNext.showsOverlay)
    let early = [upNext.tick(), upNext.playNow()]
    #expect(early == [false, false])
    #expect(upNext.phase == .waitsForQuickChecks)
    let done = upNext.quickChecksDone()
    #expect(done)
    #expect(upNext.secondsLeft == UpNextCountdown.seconds)
    // A second answer or "Close" does not start the countdown again.
    let later = [upNext.tick(), upNext.quickChecksDone()]
    #expect(later == [false, false])
    #expect(upNext.secondsLeft == 4)
}

/// #99: "Play Now" opens the next lecture at once. Cancel, a play or a seek hides the overlay and keeps the page.
@Test func upNextPlayNowAndCancel() {
    var upNext = UpNextCountdown()
    upNext.videoEnded(autoPlays: true, waitsForQuickChecks: false)
    _ = upNext.tick()
    let opens = upNext.playNow()
    #expect(opens)
    #expect(upNext.phase == .off)
    for waits in [false, true] {
        upNext.videoEnded(autoPlays: true, waitsForQuickChecks: waits)
        upNext.cancel()
        #expect(upNext.phase == .off)
        #expect(tryEachStep(&upNext) == [false, false, false])
    }
    // The next video end starts the countdown again.
    upNext.videoEnded(autoPlays: true, waitsForQuickChecks: false)
    #expect(upNext.secondsLeft == 5)
}

@Test func quickCheckSessionIsAnsweredAfterEachCheck() {
    let checks = [
        QuickCheck(id: 0, prompt: "A", choices: [QuizChoice(id: "a", text: "A")], correctChoiceID: "a"),
        QuickCheck(id: 1, prompt: "B", choices: [QuizChoice(id: "b", text: "B")], correctChoiceID: "b"),
    ]
    var session = QuickCheckSession(checks: checks)
    #expect(!session.isAnswered)
    session.answer(checkID: 0, choiceID: "a")
    #expect(!session.isAnswered)
    session.answer(checkID: 1, choiceID: "b")
    #expect(session.isAnswered)
    session.tryAgain(checkID: 0)
    #expect(!session.isAnswered)
}

/// #99: the Settings choice is on by default and stays after the app starts again.
@Test func autoPlaySettingIsOnByDefaultAndKeepsTheSavedChoice() {
    #expect(Skillgarden.autoPlayKey == "AutoPlay")
    #expect(Skillgarden.autoPlay(savedValue: nil))
    #expect(Skillgarden.autoPlay(savedValue: "off"))
    #expect(Skillgarden.autoPlay(savedValue: true))
    #expect(!Skillgarden.autoPlay(savedValue: false))
    #expect(!Skillgarden.autoPlay(savedValue: kCFBooleanFalse))
}
