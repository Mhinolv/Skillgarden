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
    #expect(CourseStore.currentSchemaVersion == 5)
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
