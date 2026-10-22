import Foundation
import SQLite3
import Testing
@testable import SkillgardenCore

@MainActor private func withRoot(_ body: @MainActor (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ProgressTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func lecture(_ id: String, _ type: LectureType = .article, order: Int, state: PublicationState = .published) -> Lecture {
    Lecture(id: id, title: id.capitalized, type: type, order: order, state: state)
}

private let course = Course(id: "c", title: "Course", state: .published, sections: [
    CourseSection(id: "s1", title: "One", order: 0, state: .published, lectures: [
        lecture("video", .video, order: 0), lecture("a", order: 1), lecture("b", order: 2),
        lecture("d", order: 3), lecture("e", order: 4), lecture("draft", order: 5, state: .draft),
    ]),
    CourseSection(id: "s2", title: "Two", order: 1, state: .published),
])

@MainActor @Test func markCompleteTogglesStateAndSectionPercent() async throws {
    try await withRoot { root in
        try CourseStore(root: root).saveCourse(course)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("c")
        let section = try #require(library.selectedCourse?.learnerSections.first)
        #expect(library.sectionProgress(section) == SectionProgress(section: section, progress: [:]))
        #expect(library.sectionProgress(section).percent == 0)

        library.selectDestination(.lecture(sectionID: "s1", lectureID: "a"))
        await library.toggleSelectedLectureComplete()
        #expect(library.isSelectedLectureComplete)
        #expect(library.isComplete("a"))
        #expect(library.sectionProgress(section).completed == 1)
        #expect(library.sectionProgress(section).percent == 20)

        library.selectDestination(.lecture(sectionID: "s1", lectureID: "b"))
        await library.toggleSelectedLectureComplete()
        #expect(library.sectionProgress(section).percent == 40)
        // A second click is the undo.
        await library.toggleSelectedLectureComplete()
        #expect(!library.isSelectedLectureComplete)
        #expect(library.sectionProgress(section).percent == 20)

        // The state is saved: a new model reads it.
        let reopened = LibraryModel(root: root)
        await reopened.reload()
        reopened.selectCourse("c")
        #expect(reopened.isComplete("a"))
        #expect(!reopened.isComplete("b"))
        #expect(reopened.sectionProgress(section).percent == 20)
    }
}

@Test func sectionPercentRoundsDownAndIgnoresHiddenLectures() {
    let three = CourseSection(id: "s", title: "S", order: 0, lectures: [lecture("x", order: 0), lecture("y", order: 1), lecture("z", order: 2)])
    let done = LectureProgress(completed: true)
    #expect(SectionProgress(section: three, progress: ["x": done]).percent == 33)
    #expect(SectionProgress(section: three, progress: ["x": done, "y": done]).percent == 66)
    #expect(SectionProgress(section: three, progress: ["x": done, "y": done, "z": done]).percent == 100)
    // Progress of a lecture that is not in the section does not count.
    #expect(SectionProgress(section: three, progress: ["gone": done, "x": LectureProgress(resumeSeconds: 9)]).completed == 0)
    let empty = CourseSection(id: "e", title: "E", order: 0)
    #expect(SectionProgress(section: empty, progress: ["x": done]).percent == nil)
    #expect(SectionProgress(section: empty, progress: [:]).fraction == 0)
    // Draft lectures are not learner lectures.
    let learner = course.learnerSections[0]
    #expect(SectionProgress(section: learner, progress: ["draft": done]).total == 5)
    #expect(SectionProgress(section: learner, progress: ["draft": done]).completed == 0)
}

@Test func steppingStonesMarkTheFirstIncompleteLectureAsNext() {
    let states = { (done: Set<String>) in SteppingStone.states(lectureIDs: ["a", "b", "c", "d"]) { done.contains($0) } }
    #expect(states([]) == [.next, .todo, .todo, .todo])
    #expect(states(["a"]) == [.done, .next, .todo, .todo])
    // A lecture after a gap can be done. Only the first incomplete lecture is next.
    #expect(states(["a", "c"]) == [.done, .next, .done, .todo])
    #expect(states(["b", "c", "d"]) == [.next, .done, .done, .done])
    #expect(states(["a", "b", "c", "d"]) == [.done, .done, .done, .done])
    #expect(SteppingStone.states(lectureIDs: []) { _ in false }.isEmpty)
}

@Test func steppingStonesLabelCountsDoneLectures() {
    #expect(SteppingStone.accessibilityLabel(Array(repeating: .done, count: 7) + [.next] + Array(repeating: .todo, count: 8))
            == "7 of 16 lectures complete")
    #expect(SteppingStone.accessibilityLabel([.next]) == "0 of 1 lecture complete")
    #expect(SteppingStone.accessibilityLabel([.done, .missed]) == "1 of 2 lectures complete")
    #expect(SteppingStone.accessibilityLabel([]) == "0 of 0 lectures complete")
}

@MainActor @Test func libraryStonesUseLearnerLecturesOfTheSelectedCourse() async throws {
    try await withRoot { root in
        try CourseStore(root: root).saveCourse(course)
        let library = LibraryModel(root: root)
        await library.reload()
        #expect(library.steppingStones().isEmpty)
        library.selectCourse("c")
        // The draft lecture has no stone.
        #expect(library.steppingStones() == [.next, .todo, .todo, .todo, .todo])
        library.selectDestination(.lecture(sectionID: "s1", lectureID: "video"))
        await library.toggleSelectedLectureComplete()
        #expect(library.steppingStones() == [.done, .next, .todo, .todo, .todo])
        let section = try #require(library.selectedCourse?.learnerSections.first)
        #expect(library.steppingStones(in: section) == library.steppingStones())
        let empty = try #require(library.selectedCourse?.learnerSections.last)
        #expect(library.steppingStones(in: empty).isEmpty)
    }
}

@MainActor @Test func outlineOpensOnlyTheSectionOfTheSelectionOrOfTheNextLecture() async throws {
    try await withRoot { root in
        let three = Course(id: "t", title: "Three", state: .published, sections: [
            CourseSection(id: "s1", title: "One", order: 0, state: .published, lectures: [lecture("a", order: 0)]),
            CourseSection(id: "s2", title: "Two", order: 1, state: .published, lectures: [lecture("b", order: 0), lecture("c", order: 1)]),
            CourseSection(id: "s3", title: "Three", order: 2, state: .published, lectures: [lecture("d", order: 0)]),
        ])
        try CourseStore(root: root).saveCourse(three)
        let library = LibraryModel(root: root)
        await library.reload()
        #expect(library.outlineOpenSectionID == nil)
        library.selectCourse("t")
        // A new course opens the section of the first lecture.
        #expect(library.outlineOpenSectionID == "s1")

        library.selectDestination(.lecture(sectionID: "s1", lectureID: "a"))
        await library.toggleSelectedLectureComplete()
        // The selection decides, also if the section is done.
        #expect(library.outlineOpenSectionID == "s1")
        library.selectDestination(.section(sectionID: "s3"))
        #expect(library.outlineOpenSectionID == "s3")
        library.selectDestination(.lecture(sectionID: "s2", lectureID: "c"))
        #expect(library.outlineOpenSectionID == "s2")

        // On the overview and with no selection, the section of the next lecture opens.
        library.selectDestination(.overview)
        #expect(library.outlineOpenSectionID == "s2")
        library.selectDestination(nil)
        #expect(library.outlineOpenSectionID == "s2")

        // If every lecture is done, the first section opens.
        for (section, id) in [("s2", "b"), ("s2", "c"), ("s3", "d")] {
            library.selectDestination(.lecture(sectionID: section, lectureID: id))
            await library.toggleSelectedLectureComplete()
        }
        library.selectDestination(.overview)
        #expect(library.outlineOpenSectionID == "s1")
    }
}

/// #77: the outline rings the header of the section that the course card stone marks next. The selection does not move it.
@MainActor @Test func outlineRingsTheHeaderOfTheNextSectionOnly() async throws {
    try await withRoot { root in
        let four = Course(id: "f", title: "Four", state: .published, sections: [
            CourseSection(id: "s1", title: "One", order: 0, state: .published, lectures: [lecture("a", order: 0)]),
            CourseSection(id: "empty", title: "Empty", order: 1, state: .published, lectures: [lecture("x", order: 0, state: .draft)]),
            CourseSection(id: "s2", title: "Two", order: 2, state: .published, lectures: [lecture("b", order: 0), lecture("c", order: 1)]),
            CourseSection(id: "s3", title: "Three", order: 3, state: .published, lectures: [lecture("d", order: 0)]),
        ])
        try CourseStore(root: root).saveCourse(four)
        let library = LibraryModel(root: root)
        await library.reload()
        #expect(library.outlineNextSectionID == nil)
        library.selectCourse("f")
        #expect(library.outlineNextSectionID == "s1")

        library.selectDestination(.lecture(sectionID: "s1", lectureID: "a"))
        await library.toggleSelectedLectureComplete()
        // The empty section has no stone, so the ring skips it. The selection of a done section does not move the ring.
        #expect(library.outlineNextSectionID == "s2")
        library.selectDestination(.lecture(sectionID: "s3", lectureID: "d"))
        await library.toggleSelectedLectureComplete()
        #expect(library.outlineNextSectionID == "s2")
        let course = try #require(library.selectedCourse)
        let stones = library.summary(of: course).stones
        let stoneSections = course.learnerSections.filter { !$0.lectures.isEmpty }.map(\.id)
        #expect(stones.indices.filter { stones[$0].isNext }.map { stoneSections[$0] } == ["s2"])

        // If all sections are done, no header has the ring.
        for id in ["b", "c"] {
            library.selectDestination(.lecture(sectionID: "s2", lectureID: id))
            await library.toggleSelectedLectureComplete()
        }
        #expect(library.outlineNextSectionID == nil)
    }
}

@Test func resumeStartIgnoresTheFirstAndLastFiveSeconds() {
    #expect(PlaybackResume.startSeconds(saved: 0, duration: 120) == 0)
    #expect(PlaybackResume.startSeconds(saved: 4.9, duration: 120) == 0)
    #expect(PlaybackResume.startSeconds(saved: 5, duration: 120) == 5)
    #expect(PlaybackResume.startSeconds(saved: 42, duration: 120) == 42)
    #expect(PlaybackResume.startSeconds(saved: 115, duration: 120) == 115)
    #expect(PlaybackResume.startSeconds(saved: 115.1, duration: 120) == 0)
    #expect(PlaybackResume.startSeconds(saved: 200, duration: 120) == 0)
    #expect(PlaybackResume.startSeconds(saved: 42, duration: nil) == 42)
    #expect(PlaybackResume.startSeconds(saved: 6, duration: 8) == 0)
    #expect(PlaybackResume.startSeconds(saved: .nan, duration: 120) == 0)
    #expect(PlaybackResume.startSeconds(saved: .infinity, duration: nil) == 0)
    #expect(PlaybackResume.startSeconds(saved: 42, duration: .nan) == 42)
}

@MainActor @Test func savedPlaybackPositionRestoresOnReopen() async throws {
    try await withRoot { root in
        try CourseStore(root: root).saveCourse(course)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("c")
        library.selectDestination(.lecture(sectionID: "s1", lectureID: "video"))
        #expect(library.startSeconds(forLecture: "video", duration: 120) == 0)
        library.saveResumePosition(37.5, lectureID: "video")
        // A position save keeps the complete flag, and a complete toggle keeps the position.
        await library.toggleSelectedLectureComplete()
        library.saveResumePosition(42.5, lectureID: "video")
        await library.waitForWrites()

        let reopened = LibraryModel(root: root)
        await reopened.reload()
        reopened.selectCourse("c")
        #expect(reopened.startSeconds(forLecture: "video", duration: 120) == 42.5)
        #expect(reopened.startSeconds(forLecture: "video", duration: 45) == 0)
        #expect(reopened.isComplete("video"))
        #expect(try CourseStore(root: root).progress(courseID: "c", lectureID: "video") == LectureProgress(completed: true, resumeSeconds: 42.5))
    }
}

@MainActor @Test func resumeOpensTheLastOpenedLecture() async throws {
    try await withRoot { root in
        try CourseStore(root: root).saveCourse(course)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("c")
        #expect(library.resumeDestination == nil)
        library.selectDestination(.lecture(sectionID: "s1", lectureID: "a"))
        library.goToNextLecture()
        library.selectDestination(.section(sectionID: "s1"))
        #expect(library.resumeLecture?.id == "b")
        await library.waitForWrites()

        let reopened = LibraryModel(root: root)
        await reopened.reload()
        reopened.selectCourse("c")
        #expect(reopened.destination == .overview)
        #expect(reopened.resumeLecture?.title == "B")
        reopened.resume()
        #expect(reopened.destination == .lecture(sectionID: "s1", lectureID: "b"))

        // If the last opened lecture leaves the outline, the landing page shows no Resume.
        var moved = course
        moved.sections[0].lectures.removeAll { $0.id == "b" }
        try CourseStore(root: root).saveCourse(moved)
        await reopened.reload()
        #expect(reopened.resumeDestination == nil)
        reopened.resume()
        #expect(reopened.destination == .overview)
    }
}

@MainActor @Test func learnerProgressAndResumeSurviveRepublish() async throws {
    try await withRoot { root in
        let store = try CourseStore(root: root)
        try store.saveCourse(course)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("c")
        library.selectDestination(.lecture(sectionID: "s1", lectureID: "video"))
        await library.toggleSelectedLectureComplete()
        library.saveResumePosition(30, lectureID: "video")
        await library.waitForWrites()

        try store.saveCourse(course)
        #expect(try store.progress(courseID: "c", lectureID: "video") == LectureProgress(completed: true, resumeSeconds: 30))
        #expect(try store.lastOpenedLectures() == ["c": "video"])
        await library.reload()
        #expect(library.isComplete("video"))
        #expect(library.resumeLecture?.id == "video")
    }
}

@Test func dataSavedBeforeTheProgressMigrationStillLoads() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ProgressTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(4)))
    #expect(try old.schemaVersion == 4)
    try old.saveCourse(course)
    try old.saveProgress(LectureProgress(completed: true, resumeSeconds: 12), courseID: "c", lectureID: "a")

    let upgraded = try CourseStore(root: root)
    #expect(try upgraded.schemaVersion == CourseStore.currentSchemaVersion)
    #expect(CourseStore.currentSchemaVersion == 14)
    #expect(try upgraded.loadCourse(id: "c", includeDrafts: true) == course)
    #expect(try upgraded.allProgress() == ["c": ["a": LectureProgress(completed: true, resumeSeconds: 12)]])
    #expect(try upgraded.lastOpenedLectures().isEmpty)
    try upgraded.saveLastOpenedLecture(courseID: "c", lectureID: "a")
    try upgraded.saveLastOpenedLecture(courseID: "c", lectureID: "b")
    #expect(try upgraded.lastOpenedLectures() == ["c": "b"])
}

@Test func storeProgressWritesKeepTheOtherField() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ProgressTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CourseStore(root: root)
    try store.saveResumePosition(10, courseID: "c", lectureID: "v")
    #expect(try store.progress(courseID: "c", lectureID: "v") == LectureProgress(completed: false, resumeSeconds: 10))
    try store.setCompleted(true, courseID: "c", lectureID: "v")
    try store.saveResumePosition(20, courseID: "c", lectureID: "v")
    #expect(try store.progress(courseID: "c", lectureID: "v") == LectureProgress(completed: true, resumeSeconds: 20))
    try store.setCompleted(false, courseID: "c", lectureID: "v")
    #expect(try store.progress(courseID: "c", lectureID: "v") == LectureProgress(completed: false, resumeSeconds: 20))
    try store.saveResumePosition(-3, courseID: "c", lectureID: "v")
    try store.saveResumePosition(.nan, courseID: "c", lectureID: "w")
    #expect(try store.allProgress()["c"]?.mapValues(\.resumeSeconds) == ["v": 0, "w": 0])
}

/// Another connection holds a write lock on the library database, so each store write fails after the busy timeout.
/// The returned closure releases the lock.
@MainActor
private func lockStore(_ library: LibraryModel) -> () -> Void {
    var handle: OpaquePointer?
    #expect(sqlite3_open_v2(library.root.appending(path: "library.sqlite").path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
    return {
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
    }
}

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// The fixture course with its quiz section published. The learner is on the "welcome" video, and no write waits.
@MainActor private func fixtureLibrary(root: URL) async throws -> (LibraryModel, String) {
    let courseID = try #require(try SnapshotPlan.seedStore(for: .quizQuestion, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    await library.waitForWrites()
    return (library, courseID)
}

private let quizAnswers: [QuizAction] = [.selectNumber(1), .submit, .next, .selectNumber(2), .submit, .next, .selectNumber(2), .submit, .next]

// #210: a write that the store refuses must not look saved. The automatic complete of a video and the quiz result go back.
@MainActor @Test func refusedProgressWritesDoNotLookSaved() async throws {
    try await withRoot { root in
        let (library, courseID) = try await fixtureLibrary(root: root)
        let unlock = lockStore(library)
        #expect(library.autoCompleteVideo(lectureID: "welcome"))
        await library.waitForWrites()
        unlock()
        #expect(!library.isComplete("welcome"))

        library.selectDestination(.lecture(sectionID: "practice", lectureID: "check"))
        await library.waitForWrites()
        let relock = lockStore(library)
        for action in quizAnswers { library.performQuizAction(action) }
        await library.waitForWrites()
        relock()
        #expect(library.quizResults[courseID]?["check"] == nil)
        #expect(try CourseStore(root: root).allQuizResults().isEmpty)
    }
}

// #210: a refused completion shows the strip and "Mark as Complete". "Try Again" saves it once.
@MainActor @Test func refusedCompletionShowsTheStripAndTryAgainSavesIt() async throws {
    try await withRoot { root in
        let (library, courseID) = try await fixtureLibrary(root: root)
        let unlock = lockStore(library)
        await library.toggleSelectedLectureComplete()
        #expect(!library.isComplete("welcome") && library.autoCompletes("welcome"))
        #expect(library.progressSaveFailureText == "Skillgarden couldn't save that this lecture is complete.")
        // Another failure keeps the strip and the state.
        library.retryProgressSaves()
        await library.waitForWrites()
        #expect(!library.isComplete("welcome"))
        #expect(library.failedProgressSaves.count == 1)
        unlock()

        library.retryProgressSaves()
        // A second click before the result writes nothing more.
        library.retryProgressSaves()
        await library.waitForWrites()
        #expect(library.isComplete("welcome") && library.progressSaveFailureText == nil)
        #expect(try CourseStore(root: root).progress(courseID: courseID, lectureID: "welcome")?.completed == true)
        // No failure: "Try Again" does nothing.
        library.retryProgressSaves()
        await library.waitForWrites()
        #expect(library.isComplete("welcome"))
    }
}

// #210: refused resume ticks show one strip and playback state stays. A quiz failure too gives the shared text.
// A later resume save that succeeds hides its part. A restart shows only the saved state.
@MainActor @Test func refusedResumeAndQuizWritesShareOneStrip() async throws {
    try await withRoot { root in
        let (library, courseID) = try await fixtureLibrary(root: root)
        let unlock = lockStore(library)
        library.saveResumePosition(10, lectureID: "welcome")
        library.saveResumePosition(20, lectureID: "welcome")
        await library.waitForWrites()
        #expect(library.failedProgressSaves.map(\.kind) == [.resumePosition])
        #expect(library.progressSaveFailureText == "Skillgarden couldn't save your place in this video.")
        #expect(library.startSeconds(forLecture: "welcome", duration: nil) == 20)

        library.selectDestination(.lecture(sectionID: "practice", lectureID: "check"))
        for action in quizAnswers { library.performQuizAction(action) }
        await library.waitForWrites()
        #expect(library.progressSaveFailureText == "Skillgarden couldn't save some of your progress.")
        // The results screen of the attempt stays.
        #expect(library.selectedQuizAttempt?.showsResults == true)
        unlock()

        // A restart shows only the saved state and no strip.
        let reopened = LibraryModel(root: root)
        await reopened.reload()
        reopened.selectCourse(courseID)
        #expect(reopened.failedProgressSaves.isEmpty)
        #expect(reopened.quizResults[courseID]?["check"] == nil)
        #expect(reopened.startSeconds(forLecture: "welcome", duration: nil) == 0)

        library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
        library.saveResumePosition(30, lectureID: "welcome")
        await library.waitForWrites()
        #expect(library.progressSaveFailureText == "Skillgarden couldn't save your quiz result.")
        library.retryProgressSaves()
        await library.waitForWrites()
        #expect(library.progressSaveFailureText == nil)
        let expected = QuizResult(correct: 1, total: 3, weakSkills: ["Order course sections", "Check a lecture objective"])
        #expect(library.quizResults[courseID]?["check"] == expected)
        #expect(try CourseStore(root: root).allQuizResults() == [courseID: ["check": expected]])
        #expect(try CourseStore(root: root).progress(courseID: courseID, lectureID: "welcome")?.resumeSeconds == 30)
    }
}

@Test func progressSaveFailureTextNamesOneWriteOrAll() {
    let key = { (kind: ProgressSaveKey.Kind, lecture: String) in ProgressSaveKey(kind: kind, courseID: "c", lectureID: lecture) }
    #expect(ProgressSaveKey.failureText([]) == nil)
    #expect(ProgressSaveKey.failureText([key(.completion, "a")]) == "Skillgarden couldn't save that this lecture is complete.")
    #expect(ProgressSaveKey.failureText([key(.resumePosition, "a")]) == "Skillgarden couldn't save your place in this video.")
    #expect(ProgressSaveKey.failureText([key(.quizResult, "a")]) == "Skillgarden couldn't save your quiz result.")
    // Two writes of the same kind on two lectures also use the shared text.
    #expect(ProgressSaveKey.failureText([key(.completion, "a"), key(.completion, "b")])
            == "Skillgarden couldn't save some of your progress.")
}
