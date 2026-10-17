import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func lecture(_ id: String, _ order: Int, next: String? = nil, state: PublicationState = .published) -> Lecture {
    Lecture(id: id, title: id.uppercased(), type: .article, objective: "Objective \(id)", order: order, state: state,
            recommendedNext: next)
}

/// Section a: a1 → a2 (recommends b2), a3 is draft. Section b: b1, b2 (recommends missing). Section c is draft.
private func navigationCourse() -> Course {
    Course(id: "c", title: "Course", state: .published, sections: [
        CourseSection(id: "a", title: "A", objective: "Section A", order: 0, state: .published, lectures: [
            lecture("a1", 0), lecture("a2", 1, next: "b2"), lecture("a3", 2, state: .draft),
        ]),
        CourseSection(id: "b", title: "B", order: 1, state: .published, lectures: [
            lecture("b1", 0, next: ""), lecture("b2", 1, next: "missing"), lecture("b3", 2, next: "a3"),
            lecture("b4", 3, next: "b4"), lecture("b5", 4, next: "  "),
        ]),
        CourseSection(id: "draft", title: "Draft", order: 2, lectures: [lecture("d1", 0, state: .published)]),
    ])
}

@Test func learnerOutlineHidesDraftSectionsAndLectures() {
    let course = navigationCourse()
    #expect(course.learnerSections.map(\.id) == ["a", "b"])
    #expect(course.learnerSections[0].lectures.map(\.id) == ["a1", "a2"])
    #expect(course.learnerLectures.map(\.lecture.id) == ["a1", "a2", "b1", "b2", "b3", "b4", "b5"])
    #expect(course.sectionNumber(of: "b") == 2)
    #expect(course.sectionNumber(of: "draft") == nil)
    #expect(course.lectureNumber(of: "a1") == 1)
    #expect(course.lectureNumber(of: "b1") == 3)
    #expect(course.lectureNumber(of: "a3") == nil)
    #expect(course.lectureNumber(of: "d1") == nil)
}

@Test func previousAndNextCrossSectionsAndStopAtTheEnds() {
    let course = navigationCourse()
    #expect(course.adjacentLecture(to: "a1", offset: -1) == nil)
    #expect(course.adjacentLecture(to: "a1", offset: 1) == .lecture(sectionID: "a", lectureID: "a2"))
    #expect(course.adjacentLecture(to: "a2", offset: 1) == .lecture(sectionID: "b", lectureID: "b1"))
    #expect(course.adjacentLecture(to: "b1", offset: -1) == .lecture(sectionID: "a", lectureID: "a2"))
    #expect(course.adjacentLecture(to: "b5", offset: 1) == nil)
    #expect(course.adjacentLecture(to: "a3", offset: 1) == nil)
    #expect(Course(id: "empty", title: "Empty").adjacentLecture(to: "x", offset: 1) == nil)
}

@Test func nudgeUsesRecommendedNextThenFallsBackToUpNext() {
    let course = navigationCourse()
    // recommended_next set and visible: the target, also in another section.
    #expect(course.nudge(for: "a2") == LectureNudge(kind: .recommended, sectionID: "b", lecture: lecture("b2", 1, next: "missing")))
    #expect(course.nudge(for: "a2")?.destination == .lecture(sectionID: "b", lectureID: "b2"))
    // recommended_next absent or empty: the next lecture in order, across sections.
    #expect(course.nudge(for: "a1")?.kind == .upNext)
    #expect(course.nudge(for: "a1")?.lecture.id == "a2")
    #expect(course.nudge(for: "b1")?.kind == .upNext)
    #expect(course.nudge(for: "b1")?.lecture.id == "b2")
    // Missing, draft or self targets hide the card.
    #expect(course.nudge(for: "b2") == nil)
    #expect(course.nudge(for: "b3") == nil)
    #expect(course.nudge(for: "b4") == nil)
    // The last lecture has no up-next lecture. A blank recommended_next counts as empty.
    #expect(course.nudge(for: "b5") == nil)
    // A lecture that the learner cannot see has no nudge.
    #expect(course.nudge(for: "a3") == nil)
    #expect(course.nudge(for: "d1") == nil)
}

@MainActor @Test func libraryNavigatesSectionsLecturesAndTheNudge() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "NavigationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var course = navigationCourse()
    try CourseStore(root: root).saveCourse(course)
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("c")
    #expect(library.selectedCourse?.sections.map(\.id) == ["a", "b"])

    library.selectDestination(.section(sectionID: "a"))
    #expect(library.destination == .section(sectionID: "a"))
    #expect(library.selectedSection?.objective == "Section A")
    #expect(library.selectedLecture == nil)
    #expect(library.previousLecture == nil && library.nextLecture == nil && library.nudge == nil)
    library.selectDestination(.section(sectionID: "draft"))
    #expect(library.destination == .section(sectionID: "a"))
    library.selectDestination(.lecture(sectionID: "a", lectureID: "a3"))
    #expect(library.destination == .section(sectionID: "a"))

    library.selectDestination(.lecture(sectionID: "a", lectureID: "a1"))
    #expect(library.selectedSection?.id == "a")
    #expect(library.selectedLecture?.objective == "Objective a1")
    #expect(library.previousLecture == nil)
    library.goToPreviousLecture()
    #expect(library.destination == .lecture(sectionID: "a", lectureID: "a1"))
    library.goToNextLecture()
    #expect(library.destination == .lecture(sectionID: "a", lectureID: "a2"))
    #expect(library.nudge?.kind == .recommended)
    library.goToNudge()
    #expect(library.destination == .lecture(sectionID: "b", lectureID: "b2"))
    #expect(library.nudge == nil)
    library.goToNudge()
    #expect(library.destination == .lecture(sectionID: "b", lectureID: "b2"))
    library.goToPreviousLecture()
    #expect(library.destination == .lecture(sectionID: "b", lectureID: "b1"))
    library.selectDestination(.lecture(sectionID: "b", lectureID: "b5"))
    library.goToNextLecture()
    #expect(library.destination == .lecture(sectionID: "b", lectureID: "b5"))

    // A section that becomes draft sends the learner back to the overview on reload.
    library.selectDestination(.section(sectionID: "b"))
    course.sections[1].state = .draft
    try CourseStore(root: root).saveCourse(course)
    await library.reload()
    #expect(library.destination == .overview)
    #expect(library.headerImage(forSection: "a") == nil)
}

@MainActor @Test func publishedSampleCourseKeepsManifestOrderObjectivesAndHeaderImages() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "NavigationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appending(path: "course")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    // Publish the "practice" section and move "plan" after it with a larger `order`.
    let file = folder.appending(path: "skillgarden.yaml")
    var text = try String(contentsOf: file, encoding: .utf8)
    for (old, new) in [("    state: draft\n    order: 1\n", "    state: published\n    order: 1\n"),
                       ("    state: published\n    order: 0\n", "    state: published\n    order: 5\n")] {
        #expect(text.contains(old))
        text = text.replacingOccurrences(of: old, with: new)
    }
    try text.write(to: file, atomically: true, encoding: .utf8)
    let root = base.appending(path: "library")
    _ = try CoursePublisher.publish(courseFolder: folder, root: root)

    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("sample-course")
    let course = try #require(library.selectedCourse)
    #expect(course.learnerSections.map(\.id) == ["practice", "plan"])
    #expect(course.learnerSections.map(\.objective) == ["Apply the course plan", "Identify the course structure"])
    // The draft lecture "apply" is not in the learner outline.
    #expect(course.learnerSections[0].lectures.map(\.id) == ["check"])
    #expect(course.learnerLectures.map(\.lecture.id) == ["check", "welcome", "read"])
    #expect(course.learnerLectures.map(\.lecture.objective).allSatisfy { !$0.isEmpty })

    let image = try #require(library.headerImage(forSection: "plan"))
    #expect(image.alt == "Two course sections")
    #expect(image.url.lastPathComponent == "section.svg")
    #expect(FileManager.default.fileExists(atPath: image.url.path))

    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    #expect(library.nudge == LectureNudge(kind: .recommended, sectionID: "plan", lecture: course.learnerSections[1].lectures[1]))
    library.goToNudge()
    #expect(library.selectedLecture?.id == "read")
    #expect(library.nudge == nil)
    #expect(library.nextLecture == nil)
}
