import Foundation
import Testing
@testable import SkillgardenCore

// MARK: Play ticks (#79)

/// Feeds play ticks and returns the times at which the rule completes the lecture.
private func completions(_ ticks: [(Double, Bool)], duration: Double? = 100) -> [Double] {
    var rule = VideoAutoComplete()
    return ticks.filter { rule.tick(seconds: $0.0, duration: duration, isPlaying: $0.1) }.map(\.0)
}

@Test func playPastNinetyPercentCompletesOnce() {
    let ticks = stride(from: 88.0, through: 92, by: 0.25).map { ($0, true) }
    #expect(completions(ticks) == [90])
    #expect(completions([(89.9, true), (90.1, true), (95, true)]) == [90.1])
}

@Test func playThatStaysUnderNinetyPercentDoesNotComplete() {
    #expect(completions(stride(from: 0.0, through: 89.75, by: 0.25).map { ($0, true) }).isEmpty)
}

@Test func seekPastNinetyPercentDoesNotComplete() {
    // A jump larger than the play step is a seek.
    #expect(completions([(10, true), (95, true), (95.25, true)]).isEmpty)
    // The first tick after the player opens at 95% has no previous tick.
    #expect(completions([(95, true), (95.25, true)]).isEmpty)
    // A tick while paused starts the count again.
    #expect(completions([(89.9, false), (90.1, true)]).isEmpty)
    #expect(completions([(89.8, true), (89.9, false), (90.1, true)]).isEmpty)
    // Backward steps do not count.
    #expect(completions([(99, true), (91, true)]).isEmpty)
}

@Test func seekResetForgetsThePreviousTick() {
    var rule = VideoAutoComplete()
    let before = rule.tick(seconds: 89.9, duration: 100, isPlaying: true)
    rule.reset()
    let after = [rule.tick(seconds: 90.1, duration: 100, isPlaying: true), rule.tick(seconds: 90.3, duration: 100, isPlaying: true)]
    #expect(!before)
    #expect(after == [false, false])
}

@Test func playPastTheMarkAgainAfterASeekBackCompletesAgain() {
    #expect(completions([(89.9, true), (90.1, true), (50, true), (89.9, true), (90.2, true)]) == [90.1, 90.2])
}

@Test func autoCompleteEdgeDurations() {
    #expect(completions([(0.8, true), (0.95, true)], duration: 1) == [0.95])
    #expect(completions([(89.9, true), (90.1, true)], duration: nil).isEmpty)
    #expect(completions([(89.9, true), (90.1, true)], duration: 0).isEmpty)
    #expect(completions([(89.9, true), (90.1, true)], duration: .nan).isEmpty)
    #expect(completions([(89.9, true), (90.1, true)], duration: .infinity).isEmpty)
    #expect(completions([(89.9, true), (.nan, true), (90.1, true)]).isEmpty)
    // A play step of exactly `maxPlayStep` counts. A larger step does not.
    #expect(completions([(88, true), (90, true)]) == [90])
    #expect(completions([(87.9, true), (90, true)]).isEmpty)
    #expect(completions([(35_999, true), (36_000, true)], duration: 40_000) == [36_000])
}

// MARK: Library model and store

@MainActor private func withRoot(_ body: @MainActor (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AutoCompleteTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private let course = Course(id: "c", title: "Course", state: .published, sections: [
    CourseSection(id: "s", title: "Section", order: 0, state: .published, lectures: [
        Lecture(id: "v", title: "Video", type: .video, order: 0, state: .published),
        Lecture(id: "w", title: "Second video", type: .video, order: 1, state: .published),
        Lecture(id: "a", title: "Article", type: .article, order: 2, state: .published),
    ]),
])

@MainActor @Test func autoCompleteMarksTheSelectedVideoCompleteAndSavesIt() async throws {
    try await withRoot { root in
        try CourseStore(root: root).saveCourse(course)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("c")
        library.selectDestination(.lecture(sectionID: "s", lectureID: "v"))
        #expect(library.autoCompletes("v"))
        // A lecture that is not selected and a lecture that is not a video do not change.
        #expect(!library.autoCompleteVideo(lectureID: "w"))
        #expect(!library.isComplete("w"))
        #expect(library.autoCompleteVideo(lectureID: "v"))
        #expect(library.isComplete("v"))
        // A second call does nothing because the lecture is complete.
        #expect(!library.autoCompleteVideo(lectureID: "v"))
        library.selectDestination(.lecture(sectionID: "s", lectureID: "a"))
        #expect(!library.autoCompleteVideo(lectureID: "a"))
        #expect(!library.isComplete("a"))
        await library.waitForWrites()
        #expect(try CourseStore(root: root).allProgress() == ["c": ["v": LectureProgress(completed: true)]])
    }
}

@MainActor @Test func manualIncompleteStopsAutoCompleteAndManualCompleteRestoresIt() async throws {
    try await withRoot { root in
        try CourseStore(root: root).saveCourse(course)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("c")
        library.selectDestination(.lecture(sectionID: "s", lectureID: "v"))
        library.autoCompleteVideo(lectureID: "v")
        await library.toggleSelectedLectureComplete()
        #expect(!library.isComplete("v"))
        #expect(!library.autoCompletes("v"))
        #expect(!library.autoCompleteVideo(lectureID: "v"))
        #expect(!library.isComplete("v"))
        await library.waitForWrites()

        // The opt-out survives a reopen and a republish.
        try CourseStore(root: root).saveCourse(course)
        let reopened = LibraryModel(root: root)
        await reopened.reload()
        reopened.selectCourse("c")
        reopened.selectDestination(.lecture(sectionID: "s", lectureID: "v"))
        #expect(!reopened.autoCompletes("v"))
        #expect(!reopened.autoCompleteVideo(lectureID: "v"))
        #expect(!reopened.isComplete("v"))

        // Mark as Complete by hand clears the opt-out. The Completed button still works.
        await reopened.toggleSelectedLectureComplete()
        #expect(reopened.isComplete("v"))
        #expect(reopened.autoCompletes("v"))
        await reopened.toggleSelectedLectureComplete()
        await reopened.toggleSelectedLectureComplete()
        #expect(reopened.isComplete("v") && reopened.autoCompletes("v"))
        await reopened.toggleSelectedLectureComplete()
        await reopened.waitForWrites()
        #expect(try CourseStore(root: root).progress(courseID: "c", lectureID: "v")
            == LectureProgress(completed: false, autoCompleteOff: true))
    }
}

@Test func storeHandWritesKeepTheResumePositionAndSetTheOptOut() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AutoCompleteTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CourseStore(root: root)
    try store.setCompletedByHand(false, courseID: "c", lectureID: "new")
    #expect(try store.progress(courseID: "c", lectureID: "new") == LectureProgress(completed: false, autoCompleteOff: true))
    try store.saveResumePosition(20, courseID: "c", lectureID: "v")
    try store.setCompletedByHand(false, courseID: "c", lectureID: "v")
    #expect(try store.progress(courseID: "c", lectureID: "v") == LectureProgress(resumeSeconds: 20, autoCompleteOff: true))
    // The automatic write keeps the opt-out. Only a hand write changes it.
    try store.setCompleted(true, courseID: "c", lectureID: "v")
    try store.saveResumePosition(25, courseID: "c", lectureID: "v")
    #expect(try store.progress(courseID: "c", lectureID: "v") == LectureProgress(completed: true, resumeSeconds: 25, autoCompleteOff: true))
    try store.setCompletedByHand(true, courseID: "c", lectureID: "v")
    #expect(try store.allProgress()["c"]?["v"] == LectureProgress(completed: true, resumeSeconds: 25))
    try store.setCompletedByHand(false, courseID: "c", lectureID: "v")
    try store.saveProgress(LectureProgress(completed: true, resumeSeconds: 3), courseID: "c", lectureID: "v")
    #expect(try store.allProgress()["c"]?["v"] == LectureProgress(completed: true, resumeSeconds: 3, autoCompleteOff: true))
}

@Test func progressSavedBeforeSchemaVersion10KeepsAutoCompleteOn() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AutoCompleteTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(9)))
    #expect(try old.schemaVersion == 9)
    try old.saveCourse(course)
    try old.setCompleted(true, courseID: "c", lectureID: "v")
    try old.saveResumePosition(12, courseID: "c", lectureID: "w")
    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == 10)
    #expect(try store.allProgress() == ["c": ["v": LectureProgress(completed: true), "w": LectureProgress(resumeSeconds: 12)]])
}

@Test func lectureProgressJSONWithoutTheOptOutDecodes() throws {
    let old = try JSONDecoder().decode(LectureProgress.self, from: Data(#"{"completed":true,"resumeSeconds":4}"#.utf8))
    #expect(old == LectureProgress(completed: true, resumeSeconds: 4))
    let new = LectureProgress(completed: false, resumeSeconds: 1, autoCompleteOff: true)
    #expect(try JSONDecoder().decode(LectureProgress.self, from: JSONEncoder().encode(new)) == new)
}
