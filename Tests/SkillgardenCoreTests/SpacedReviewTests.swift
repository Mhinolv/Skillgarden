import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SpacedReviewTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func quiz(_ ids: [String]) -> Quiz {
    Quiz(questions: ids.map {
        QuizQuestion(id: $0, prompt: "Prompt \($0)", objectiveTag: "Tag", choices: [QuizChoice(id: "a", text: "A"), QuizChoice(id: "b", text: "B")],
                     correctChoiceID: "a", explanation: "Because")
    })
}

private func lecture(_ id: String, _ type: LectureType, order: Int, state: PublicationState = .published) -> Lecture {
    Lecture(id: id, title: "Title \(id)", type: type, order: order, state: state)
}

/// Sections a, b, c, d in order. a and b have quizzes. Draft content and the quiz in c must never show.
private let course = Course(id: "c", title: "Course", state: .published, sections: [
    CourseSection(id: "a", title: "A", order: 0, state: .published, lectures: [
        lecture("qa", .quiz, order: 0), lecture("read", .article, order: 1), lecture("qa-draft", .quiz, order: 2, state: .draft),
    ]),
    CourseSection(id: "hidden", title: "Hidden", order: 1, lectures: [lecture("qh", .quiz, order: 0)]),
    CourseSection(id: "b", title: "B", order: 2, state: .published, lectures: [lecture("qb", .quiz, order: 0)]),
    CourseSection(id: "c", title: "C", order: 3, state: .published, lectures: [lecture("qc", .quiz, order: 0)]),
    CourseSection(id: "d", title: "D", order: 4, state: .published),
])

private let quizzes = ["qa": quiz(["1", "2"]), "qa-draft": quiz(["x"]), "qh": quiz(["y"]), "qb": quiz(["1", "3"]), "qc": quiz(["z"])]

@Test func candidatesComeOnlyFromEarlierLearnerQuizzes() {
    let ids = { (section: String) in SpacedReview.candidates(course: course, sectionID: section, quizzes: quizzes).map(\.id) }
    #expect(ids("a") == [])
    #expect(ids("b") == ["qa/1", "qa/2"])
    #expect(ids("c") == ["qa/1", "qa/2", "qb/1", "qb/3"])
    #expect(ids("d") == ["qa/1", "qa/2", "qb/1", "qb/3", "qc/z"])
    #expect(ids("hidden") == [])
    #expect(ids("missing") == [])
    let first = SpacedReview.candidates(course: course, sectionID: "b", quizzes: quizzes).first
    #expect(first?.lectureTitle == "Title qa")
    #expect(first?.question.prompt == "Prompt 1")
}

@Test(arguments: 0..<50 as Range<UInt64>)
func selectionPicksTwoOrThreeDistinctEarlierQuestions(seed: UInt64) {
    var random = SeededRandomNumberGenerator(seed: seed)
    for (section, earlier) in [("b", ["qa/1", "qa/2"]), ("c", ["qa/1", "qa/2", "qb/1", "qb/3"]),
                               ("d", ["qa/1", "qa/2", "qb/1", "qb/3", "qc/z"])] {
        let candidates = SpacedReview.candidates(course: course, sectionID: section, quizzes: quizzes)
        let picked = SpacedReview.select(from: candidates, using: &random).map(\.id)
        #expect(picked.count == min(3, earlier.count))
        #expect(Set(picked).count == picked.count)
        #expect(Set(picked).isSubset(of: earlier))
    }
}

@Test func selectionNeedsTwoDistinctQuestions() {
    var random = SeededRandomNumberGenerator(seed: 1)
    let one = ReviewQuestion(lectureID: "q", lectureTitle: "Q", question: quiz(["1"]).questions[0])
    let two = ReviewQuestion(lectureID: "q", lectureTitle: "Q", question: quiz(["2"]).questions[0])
    #expect(SpacedReview.select(from: [], using: &random).isEmpty)
    #expect(SpacedReview.select(from: [one], using: &random).isEmpty)
    #expect(SpacedReview.select(from: [one, one, one], using: &random).isEmpty)
    #expect(Set(SpacedReview.select(from: [one, two, one], using: &random).map(\.id)) == ["q/1", "q/2"])
    // The same question id in two quizzes is two questions.
    let other = ReviewQuestion(lectureID: "r", lectureTitle: "R", question: quiz(["1"]).questions[0])
    #expect(SpacedReview.select(from: [one, other], using: &random).count == 2)
    // The same seed gives the same order.
    var first = SeededRandomNumberGenerator(seed: 9), second = SeededRandomNumberGenerator(seed: 9)
    let candidates = SpacedReview.candidates(course: course, sectionID: "d", quizzes: quizzes)
    #expect(SpacedReview.select(from: candidates, using: &first) == SpacedReview.select(from: candidates, using: &second))
}

@Test func oneClickAnswersAReviewQuestionWithQuizMarks() {
    let questions = SpacedReview.candidates(course: course, sectionID: "b", quizzes: quizzes)
    var review = SectionReview(courseID: "c", sectionID: "b", sectionTitle: "B", questions: questions)
    let a = QuizChoice(id: "a", text: "A"), b = QuizChoice(id: "b", text: "B")
    #expect(review.isCorrect("qa/1") == nil)
    #expect(review.state(of: a, in: "qa/1") == .normal)
    review.answer(questionID: "qa/1", choiceID: "b")
    #expect(review.isCorrect("qa/1") == false)
    #expect(review.state(of: a, in: "qa/1") == .correct(picked: false))
    #expect(review.state(of: b, in: "qa/1") == .incorrect)
    // The first answer counts. Unknown questions and choices do nothing.
    review.answer(questionID: "qa/1", choiceID: "a")
    review.answer(questionID: "qa/2", choiceID: "missing")
    review.answer(questionID: "qb/1", choiceID: "a")
    #expect(review.answers == ["qa/1": "b"])
    review.answer(questionID: "qa/2", choiceID: "a")
    #expect(review.isCorrect("qa/2") == true)
    #expect(review.state(of: a, in: "qa/2") == .correct(picked: true))
    #expect(review.state(of: b, in: "qa/2") == .dimmed)
}

@Test func reviewedSectionsSaveAndMigrateFromSchemaVersion7() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(7)))
    try old.saveQuizResult(QuizResult(correct: 1, total: 2, weakSkills: ["A"]), courseID: "c", lectureID: "q")

    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == CourseStore.currentSchemaVersion)
    #expect(try store.allQuizResults() == ["c": ["q": QuizResult(correct: 1, total: 2, weakSkills: ["A"])]])
    #expect(try store.allReviewedSections().isEmpty)
    try store.saveSectionReviewed(courseID: "c", sectionID: "b")
    try store.saveSectionReviewed(courseID: "c", sectionID: "b")
    try store.saveSectionReviewed(courseID: "c", sectionID: "d")
    try store.saveSectionReviewed(courseID: "e", sectionID: "b")
    #expect(try store.allReviewedSections() == ["c": ["b", "d"], "e": ["b"]])
}

@MainActor @Test func firstVisitShowsTheReviewOnceAndSkipCounts() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .sectionReview, root: root, fixture: fixture))
    let library = LibraryModel(root: root, reviewRandom: SeededRandomNumberGenerator(seed: 3))
    await library.reload()
    library.selectCourse(courseID)
    #expect(library.selectedCourse?.learnerSections.map(\.id) == ["practice", "plan"])
    // The first section has no earlier quiz, so no sheet shows and the section is not marked.
    library.selectDestination(.section(sectionID: "practice"))
    #expect(library.sectionReview == nil)
    #expect(library.reviewedSections[courseID] == nil)
    // The overview never shows the sheet.
    library.selectDestination(.overview)
    #expect(library.sectionReview == nil)
    // A lecture in the second section opens the section for the first time.
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    let review = try #require(library.sectionReview)
    #expect(review.sectionTitle == "Plan the course")
    #expect(Set(review.questions.map(\.id)) == ["check/outline", "check/order"])
    #expect(review.questions.allSatisfy { $0.lectureTitle == "Check the plan" })
    #expect(library.destination == .lecture(sectionID: "plan", lectureID: "welcome"))
    library.answerReview(questionID: "check/order", choiceID: "lowest")
    #expect(library.sectionReview?.isCorrect("check/order") == true)
    // Skip closes the sheet. The section was marked when the sheet opened.
    library.closeReview()
    #expect(library.sectionReview == nil)
    #expect(library.destination == .lecture(sectionID: "plan", lectureID: "welcome"))
    library.selectDestination(.section(sectionID: "plan"))
    #expect(library.sectionReview == nil)
    // The mark is saved. A new session of the same data folder does not show the sheet again.
    await library.waitForWrites()
    #expect(try CourseStore(root: root).allReviewedSections() == [courseID: ["plan"]])
    #expect(try CourseStore(root: root).allQuizResults().isEmpty)
    let next = LibraryModel(root: root)
    await next.reload()
    next.selectCourse(courseID)
    next.selectDestination(.section(sectionID: "plan"))
    #expect(next.sectionReview == nil)
}

@MainActor @Test func leavingTheCourseClosesTheReview() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .sectionReview, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.section(sectionID: "plan"))
    #expect(library.sectionReview != nil)
    await library.reload()
    #expect(library.sectionReview != nil)
    library.selectCourse(nil)
    #expect(library.sectionReview == nil)
}
