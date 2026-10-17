import Foundation
import Testing
@testable import SkillgardenCore

@MainActor @Test func libraryLoadsPublishedCoursesAndOrderedOutline() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LibraryTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CourseStore(root: root)
    try store.saveCourse(Course(id: "draft", title: "Hidden"))
    let lectures = LectureType.allCases.enumerated().reversed().map { index, type in
        Lecture(id: type.rawValue, title: type.rawValue, type: type, order: index, state: .published)
    }
    try store.saveCourse(Course(id: "z", title: "Zoo", state: .published, sections: [
        CourseSection(id: "last", title: "Last", order: Int.max, state: .published),
        CourseSection(id: "first", title: "First", order: Int.min, state: .published, lectures: lectures),
        CourseSection(id: "draft", title: "Hidden", order: 0),
    ]))
    try store.saveCourse(Course(id: "a", title: "Apple", state: .published))
    let library = LibraryModel(root: root)
    await library.reload()
    #expect(library.courses.map(\.id) == ["a", "z"])
    #expect(library.selectedCourse == nil)
    #expect(library.errorMessage == nil)
    #expect(!library.isLoading)
    library.selectCourse("z")
    #expect(library.destination == .overview)
    #expect(library.selectedCourse?.sections.map(\.id) == ["first", "last"])
    #expect(library.selectedCourse?.sections.first?.lectures.map(\.type) == LectureType.allCases)
    for type in LectureType.allCases {
        library.selectDestination(.lecture(sectionID: "first", lectureID: type.rawValue))
        #expect(library.selectedLecture?.type == type)
    }
    library.selectDestination(.lecture(sectionID: "draft", lectureID: "hidden"))
    #expect(library.selectedLecture?.type == LectureType.allCases.last)
    library.selectCourse("a")
    #expect(library.destination == .overview)
    #expect(library.selectedLecture == nil)
    #expect(library.selectedCourse?.sections.isEmpty == true)
    library.selectCourse("draft")
    #expect(library.selectedCourse == nil)
    #expect(library.destination == nil)
}

@MainActor @Test func libraryReloadReconcilesSelectionAndPublishedState() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LibraryTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CourseStore(root: root)
    var course = Course(id: "c", title: "Course", state: .published, sections: [
        CourseSection(id: "s", title: "Section", order: 0, state: .published, lectures: [
            Lecture(id: "l", title: "Lecture", type: .article, order: 0, state: .published),
        ]),
    ])
    try store.saveCourse(course)
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("c")
    let destination = CourseDestination.lecture(sectionID: "s", lectureID: "l")
    library.selectDestination(destination)
    await library.reload()
    #expect(library.destination == destination)
    library.selectCourse("c")
    #expect(library.destination == destination)
    course.sections[0].lectures[0].state = .draft
    try store.saveCourse(course)
    await library.reload()
    #expect(library.destination == .overview)
    #expect(library.selectedCourse?.sections.first?.lectures.isEmpty == true)
    course.state = .draft
    try store.saveCourse(course)
    await library.reload()
    #expect(library.courses.isEmpty)
    #expect(library.selectedCourseID == nil)
    #expect(library.destination == nil)
    library.selectDestination(.overview)
    #expect(library.destination == nil)
}

@MainActor @Test func libraryErrorCanRetryWithInjectedRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LibraryTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("file".utf8).write(to: root)
    let library = LibraryModel(root: root)
    await library.reload()
    #expect(library.errorMessage != nil)
    #expect(library.courses.isEmpty)
    #expect(!library.isLoading)
    try FileManager.default.removeItem(at: root)
    await library.reload()
    #expect(library.errorMessage == nil)
    #expect(library.courses.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "library.sqlite").path))
    let store = try CourseStore(root: root)
    try store.saveCourse(Course(id: "new", title: "New", state: .published))
    await library.reload()
    library.selectCourse("new")
    try FileManager.default.removeItem(at: root.appending(path: "library.sqlite"))
    try Data("invalid".utf8).write(to: root.appending(path: "library.sqlite"))
    await library.reload()
    #expect(library.errorMessage != nil)
    #expect(library.selectedCourseID == nil)
    #expect(library.destination == nil)
    #expect(library.courses.isEmpty)
}
