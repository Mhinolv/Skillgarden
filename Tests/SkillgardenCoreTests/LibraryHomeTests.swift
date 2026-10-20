import Foundation
import Testing
@testable import SkillgardenCore

private func lecture(_ id: String, order: Int, state: PublicationState = .published) -> Lecture {
    Lecture(id: id, title: id.capitalized, type: .article, order: order, state: state)
}

private func course(_ id: String, lectures: [Lecture] = []) -> Course {
    Course(id: id, title: id.capitalized, state: .published, sections: [
        CourseSection(id: "s1", title: "One", order: 0, state: .published, lectures: Array(lectures.prefix(2))),
        CourseSection(id: "s2", title: "Two", order: 1, state: .published, lectures: Array(lectures.dropFirst(2))),
        CourseSection(id: "draft", title: "Hidden", order: 2, lectures: [lecture("hidden", order: 0)]),
    ])
}

private let threeLectures = [lecture("a", order: 0), lecture("b", order: 1), lecture("c", order: 0),
                             lecture("x", order: 1, state: .draft)]

private func done(_ ids: String...) -> [String: LectureProgress] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, LectureProgress(completed: true)) })
}

@Test func courseSummaryCoversEveryTileState() {
    let empty = CourseSummary(course: course("e"), progress: done("hidden"))
    #expect(empty.status == .noLectures)
    #expect(empty.stones.isEmpty && empty.total == 0 && empty.percent == 0)
    #expect(empty.meta == "No lectures yet")
    #expect(empty.countText == nil)
    #expect(empty.nextLecture == nil && empty.nextDestination == nil)

    // One stone per learner section, not per lecture. The draft section and the draft lecture do not count.
    let new = CourseSummary(course: course("n", lectures: threeLectures), progress: done("x"))
    #expect(new.status == .new)
    #expect(new.stones == [SectionStone(completed: 0, total: 2, isNext: true), SectionStone(completed: 0, total: 1, isNext: false)])
    #expect(new.meta == "3 lectures")
    #expect(new.countText == "0 of 3 done")
    #expect(new.nextDestination == .lecture(sectionID: "s1", lectureID: "a"))

    // The first incomplete lecture is the next lecture, also after a gap.
    let progress = CourseSummary(course: course("p", lectures: threeLectures), progress: done("a", "c"))
    #expect(progress.status == .inProgress)
    #expect(progress.stones == [SectionStone(completed: 1, total: 2, isNext: true), SectionStone(completed: 1, total: 1, isNext: false)])
    #expect(progress.stones.map(\.fraction) == [0.5, 1])
    #expect(progress.completed == 2 && progress.total == 3)
    #expect(progress.percent == 66)
    #expect(progress.meta == "Next: B")
    #expect(progress.countText == "2 of 3 done")
    #expect(progress.nextDestination == .lecture(sectionID: "s1", lectureID: "b"))

    let finished = CourseSummary(course: course("d", lectures: threeLectures), progress: done("a", "b", "c"))
    #expect(finished.status == .done)
    #expect(finished.meta == "3 lectures · all done")
    #expect(finished.countText == "3 of 3 done")
    #expect(finished.stones.allSatisfy { $0.isDone && !$0.isNext })
    #expect(finished.percent == 100)
    #expect(finished.nextLecture == nil && finished.nextDestination == nil)

    let one = CourseSummary(course: course("o", lectures: [lecture("a", order: 0)]), progress: [:])
    #expect(one.meta == "1 lecture")
    let oneDone = CourseSummary(course: course("o", lectures: [lecture("a", order: 0)]), progress: done("a"))
    #expect(oneDone.meta == "1 lecture · all done")
}

/// #69 owner decision: one stone per section that fills as its lectures are done, then "N of M done".
@Test func sectionStonesFillPerSectionAndSkipEmptySections() {
    let course = Course(id: "c", title: "C", state: .published, sections: [
        CourseSection(id: "full", title: "Full", order: 0, state: .published, lectures: [lecture("a", order: 0)]),
        CourseSection(id: "empty", title: "Empty", order: 1, state: .published, lectures: [lecture("d", order: 0, state: .draft)]),
        CourseSection(id: "part", title: "Part", order: 2, state: .published,
                      lectures: [lecture("b", order: 0), lecture("c", order: 1), lecture("e", order: 2), lecture("f", order: 3)]),
        CourseSection(id: "later", title: "Later", order: 3, state: .published, lectures: [lecture("g", order: 0)]),
    ])
    let stones = SectionStone.stones(course: course, progress: done("a", "c", "d", "unknown"))
    // The section with only a draft lecture has no stone. The ring goes to the first section that is not done.
    #expect(stones == [SectionStone(completed: 1, total: 1, isNext: false), SectionStone(completed: 1, total: 4, isNext: true),
                       SectionStone(completed: 0, total: 1, isNext: false)])
    #expect(stones.map(\.fraction) == [1, 0.25, 0])
    #expect(SectionStone.countText(stones) == "2 of 6 done")
    #expect(SectionStone.accessibilityLabel(stones) == "2 of 6 lectures done, 1 of 3 sections done")

    let one = [SectionStone(completed: 0, total: 1, isNext: true)]
    #expect(SectionStone.accessibilityLabel(one) == "0 of 1 lecture done, 0 of 1 section done")
    #expect(SectionStone.stones(course: course, progress: [:]).map(\.isNext) == [true, false, false])
    #expect(SectionStone.countText([]) == "0 of 0 done")
    #expect(SectionStone(completed: 0, total: 0, isNext: false).fraction == 0)
}

@Test func gridColumnsDependOnTheWindowWidth() {
    #expect(LibraryGrid.columns(forWidth: 0) == 3)
    #expect(LibraryGrid.columns(forWidth: 1179.9) == 3)
    #expect(LibraryGrid.columns(forWidth: 1180) == 4)
    #expect(LibraryGrid.columns(forWidth: 4000) == 4)
}

/// #69: no 2×2 hero. Every course gets one cell of the same size, row by row.
@Test func gridTilesFillTheRowsInReadingOrder() {
    let cell = { (row: Int, column: Int) in GridCell(row: row, column: column) }
    #expect(LibraryGrid.tileCells(count: 0, columns: 4) == [])
    #expect(LibraryGrid.tileCells(count: 1, columns: 3) == [cell(0, 0)])
    #expect(LibraryGrid.tileCells(count: 3, columns: 3) == [cell(0, 0), cell(0, 1), cell(0, 2)])
    #expect(LibraryGrid.tileCells(count: 4, columns: 3) == [cell(0, 0), cell(0, 1), cell(0, 2), cell(1, 0)])
    #expect(LibraryGrid.tileCells(count: 6, columns: 4) == [
        cell(0, 0), cell(0, 1), cell(0, 2), cell(0, 3), cell(1, 0), cell(1, 1),
    ])
    #expect(LibraryGrid.tileCells(count: 8, columns: 4).last == cell(1, 3))
    #expect(LibraryGrid.meta(courses: 1, inProgress: 0) == "1 course · 0 in progress")
    #expect(LibraryGrid.meta(courses: 6, inProgress: 3) == "6 courses · 3 in progress")
}

@MainActor @Test func libraryHomePicksTheContinueCourseAndOpensCourses() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LibraryHomeTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CourseStore(root: root)
    // Library order is by title: Done, Empty, First, New, Second.
    for id in ["done", "empty", "first", "new", "second"] {
        try store.saveCourse(course(id, lectures: id == "empty" ? [] : threeLectures))
    }
    for id in ["a", "b", "c"] { try store.setCompleted(true, courseID: "done", lectureID: id) }
    try store.setCompleted(true, courseID: "first", lectureID: "a")
    try store.setCompleted(true, courseID: "second", lectureID: "b")
    let library = LibraryModel(root: root)
    await library.reload()
    #expect(library.courses.map(\.id) == ["done", "empty", "first", "new", "second"])
    #expect(library.libraryMeta == "5 courses · 2 in progress")
    // The strip uses the first course in progress in library order. Second is also in progress.
    #expect(library.continueCourse?.id == "first")
    #expect(library.courses.map { library.summary(of: $0).status } == [.done, .noLectures, .inProgress, .new, .inProgress])
    // The summary does not need a selected course.
    #expect(library.selectedCourse == nil)

    library.openNextLecture(ofCourse: "first")
    #expect(library.selectedCourseID == "first")
    #expect(library.destination == .lecture(sectionID: "s1", lectureID: "b"))
    library.selectCourse(nil)
    #expect(library.selectedCourse == nil && library.destination == nil)
    library.openNextLecture(ofCourse: "done")
    #expect(library.destination == .overview)
    library.selectCourse(nil)
    library.openNextLecture(ofCourse: "missing")
    #expect(library.selectedCourse == nil && library.destination == nil)

    // With no course in progress, there is no "Continue" strip.
    try store.setCompleted(false, courseID: "first", lectureID: "a")
    try store.setCompleted(false, courseID: "second", lectureID: "b")
    await library.reload()
    #expect(library.continueCourse == nil)
    #expect(library.libraryMeta == "5 courses · 0 in progress")
}
