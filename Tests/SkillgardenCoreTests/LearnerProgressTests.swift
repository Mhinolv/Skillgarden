import Foundation
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
    #expect(CourseStore.currentSchemaVersion == 13)
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
