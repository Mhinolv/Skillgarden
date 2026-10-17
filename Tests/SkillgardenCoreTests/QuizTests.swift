import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "QuizTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func fixtureObject() throws -> [String: Any] {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
}

/// Changes the lecture at `sections[section].lectures[lecture]` of the fixture manifest.
private func editLecture(_ object: inout [String: Any], section: Int = 1, lecture: Int = 0,
                         _ change: (inout [String: Any]) throws -> Void) throws {
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[section]["lectures"] as? [[String: Any]])
    try change(&lectures[lecture])
    sections[section]["lectures"] = lectures
    object["sections"] = sections
}

/// Changes the question list of the fixture quiz.
private func editQuestions(_ object: inout [String: Any], _ change: (inout [[String: Any]]) throws -> Void) throws {
    try editLecture(&object) { lecture in
        var quiz = try #require(lecture["quiz"] as? [String: Any])
        var questions = try #require(quiz["questions"] as? [[String: Any]])
        try change(&questions)
        quiz["questions"] = questions
        lecture["quiz"] = quiz
    }
}

/// Loads the manifest object and returns its diagnostics. An empty result means the manifest is valid.
private func diagnostics(_ object: Any) throws -> [ManifestDiagnostic] {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "skillgarden.json")
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    do {
        _ = try ManifestLoader.load(file: file)
        return []
    } catch let error as ManifestValidationError {
        return error.diagnostics
    }
}

private let questionPath = "sections[1].lectures[0].quiz.questions"

private func question(_ id: String, tag: String, correct: String = "a") -> QuizQuestion {
    QuizQuestion(id: id, prompt: "Prompt \(id)", objectiveTag: tag,
                 choices: [QuizChoice(id: "a", text: "A"), QuizChoice(id: "b", text: "B")],
                 correctChoiceID: correct, explanation: "Because")
}

// MARK: Manifest

@Test func fixtureQuizLoadsWithAnImageQuestion() throws {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    let quiz = try #require(manifest.sections[1].lectures[0].quiz)
    #expect(quiz.questions.map(\.id) == ["outline", "order", "goal"])
    #expect(quiz.questions[0].image == ManifestImage(path: "media/section.svg", alt: "Two course sections"))
    #expect(quiz.questions[0].objectiveTag == "Read a course outline")
    #expect(quiz.questions[0].correctChoiceID == "sections")
    #expect(quiz.questions.allSatisfy { $0.image == nil || $0.id == "outline" })
    #expect(manifest.sections.flatMap(\.lectures).filter { $0.type != .quiz }.allSatisfy { $0.quiz == nil })
}

@Test(arguments: ["objective_tag", "explanation"])
func validationFailsWhenAQuestionLacksAField(field: String) throws {
    var object = try fixtureObject()
    try editQuestions(&object) { questions in
        questions[1].removeValue(forKey: field)
        questions[2][field] = "   "
    }
    let errors = try diagnostics(object)
    #expect(errors.map(\.fieldPath) == ["\(questionPath)[1].\(field)", "\(questionPath)[2].\(field)"])
    #expect(errors.map(\.message) == ["required field is missing", "must not be empty"])
}

@Test func validationChecksQuizStructure() throws {
    var object = try fixtureObject()
    try editQuestions(&object) { questions in
        questions[1]["id"] = "outline"
        questions[1]["choices"] = [["id": "only", "text": "One choice"]]
        questions[2]["choices"] = [["id": "skill", "text": "A"], ["id": "skill", "text": "B"]]
        questions[2]["correct_choice_id"] = "missing"
        questions[0]["image"] = ["path": "internal/research.md", "alt": ""]
    }
    let errors = try diagnostics(object)
    // The JSON file has sorted keys, so compare without order.
    #expect(Set(errors.map { "\($0.fieldPath): \($0.message)" }) == [
        "\(questionPath)[0].image.path: path must not be inside internal/",
        "\(questionPath)[0].image.alt: alt text is required",
        "\(questionPath)[1].id: duplicate id \"outline\" (first used at \(questionPath)[0].id)",
        "\(questionPath)[1].choices: must have at least two choices",
        "\(questionPath)[1].correct_choice_id: must refer to a choice id in this question",
        "\(questionPath)[2].choices[1].id: duplicate id \"skill\" (first used at \(questionPath)[2].choices[0].id)",
        "\(questionPath)[2].correct_choice_id: must refer to a choice id in this question",
    ])
}

@Test func validationMatchesQuizToTheLectureType() throws {
    var object = try fixtureObject()
    let sections = try #require(object["sections"] as? [[String: Any]])
    let lectures = try #require(sections[1]["lectures"] as? [[String: Any]])
    let quiz = try #require(lectures[0]["quiz"])
    try editLecture(&object) { $0.removeValue(forKey: "quiz") }
    try editLecture(&object, section: 0, lecture: 0) { $0["quiz"] = quiz }
    try editLecture(&object, lecture: 1) { $0["type"] = "quiz"; $0["quiz"] = ["questions": [Any]()] }
    let errors = try diagnostics(object)
    #expect(errors.map { "\($0.fieldPath): \($0.message)" } == [
        "sections[0].lectures[0].quiz: allowed only when type is quiz",
        "sections[1].lectures[0].quiz: required when type is quiz",
        "sections[1].lectures[1].quiz.questions: must have at least one question",
    ])
}

@Test func questionAndChoiceIDsAreScopedToTheirQuiz() throws {
    var object = try fixtureObject()
    // Choice ids repeat across questions, and a question id matches a lecture id. Both are valid.
    try editQuestions(&object) { questions in
        questions[0]["id"] = "welcome"
        questions[1]["choices"] = [["id": "sections", "text": "A"], ["id": "lectures", "text": "B"]]
        questions[1]["correct_choice_id"] = "sections"
    }
    #expect(try diagnostics(object).isEmpty)
}

// MARK: Scoring

@Test func scoringCountsCorrectChoicesAndListsWeakObjectiveTags() {
    let quiz = Quiz(questions: [
        question("q1", tag: "Read a course outline"),
        question("q2", tag: "Order course sections", correct: "b"),
        question("q3", tag: " Read a course outline "),
        question("q4", tag: "Check a lecture objective"),
        question("q5", tag: "Order course sections"),
    ])
    let result = QuizResult(quiz: quiz, answers: ["q1": "b", "q2": "b", "q3": "b", "q4": "a"])
    #expect(result.correct == 2)
    #expect(result.total == 5)
    #expect(result.percent == 40)
    // q5 has no answer, so it is wrong. Each tag shows once, in the order of its first wrong answer.
    #expect(result.weakSkills == ["Read a course outline", "Order course sections"])

    let perfect = QuizResult(quiz: quiz, answers: ["q1": "a", "q2": "b", "q3": "a", "q4": "a", "q5": "a"])
    #expect(perfect.correct == 5 && perfect.percent == 100 && perfect.weakSkills.isEmpty)
    let none = QuizResult(quiz: quiz, answers: [:])
    #expect(none.correct == 0 && none.percent == 0)
    #expect(none.weakSkills == ["Read a course outline", "Order course sections", "Check a lecture objective"])
}

@Test func percentRoundsToTheNearestWholeNumber() {
    #expect(QuizResult(correct: 2, total: 3, weakSkills: []).percent == 67)
    #expect(QuizResult(correct: 1, total: 3, weakSkills: []).percent == 33)
    #expect(QuizResult(correct: 4, total: 5, weakSkills: []).percent == 80)
    #expect(QuizResult(correct: 0, total: 0, weakSkills: []).percent == 0)
    #expect(QuizResult(quiz: Quiz(questions: []), answers: [:]) == QuizResult(correct: 0, total: 0, weakSkills: []))
}

@Test func weakSkillRuleIgnoresCorrectAndEmptyTags() {
    #expect(SkillReview.weakSkills([]).isEmpty)
    #expect(SkillReview.weakSkills([
        SkillOutcome(objectiveTag: "Plan", correct: true),
        SkillOutcome(objectiveTag: "  ", correct: false),
        SkillOutcome(objectiveTag: "Check", correct: false),
        SkillOutcome(objectiveTag: "Plan", correct: false),
        SkillOutcome(objectiveTag: "Check\n", correct: false),
        SkillOutcome(objectiveTag: "check", correct: false),
    ]) == ["Check", "Plan", "check"])
}

// MARK: Attempt

@Test func attemptShowsOneQuestionAtATime() {
    let quiz = Quiz(questions: [question("q1", tag: "One"), question("q2", tag: "Two", correct: "b")])
    var attempt = QuizAttempt(quiz: quiz)
    #expect(attempt.question?.id == "q1" && !attempt.showsResults)
    // Submit and Next do nothing until the learner selects a choice and submits.
    attempt.perform(.submit)
    attempt.perform(.next)
    #expect(!attempt.isSubmitted && attempt.question?.id == "q1")
    attempt.perform(.select(choiceID: "missing"))
    attempt.perform(.selectNumber(3))
    attempt.perform(.selectNumber(0))
    #expect(attempt.selection == nil)
    attempt.perform(.selectNumber(2))
    #expect(attempt.selection == "b")
    #expect(quiz.questions[0].choices.map(attempt.state(of:)) == [.normal, .selected])
    attempt.perform(.submit)
    #expect(attempt.isAnswerCorrect == false)
    #expect(quiz.questions[0].choices.map(attempt.state(of:)) == [.correct(picked: false), .incorrect])
    // The choices are locked after Submit.
    attempt.perform(.select(choiceID: "a"))
    #expect(attempt.answers == ["q1": "b"])
    attempt.perform(.next)
    #expect(attempt.question?.id == "q2" && attempt.selection == nil && !attempt.isSubmitted)
    #expect(attempt.isLastQuestion)
    attempt.perform(.select(choiceID: "b"))
    attempt.perform(.submit)
    #expect(attempt.isAnswerCorrect == true)
    #expect(quiz.questions[1].choices.map(attempt.state(of:)) == [.dimmed, .correct(picked: true)])
    attempt.perform(.next)
    #expect(attempt.showsResults && attempt.question == nil)
    #expect(attempt.result == QuizResult(correct: 1, total: 2, weakSkills: ["One"]))
    attempt.perform(.retake)
    #expect(attempt == QuizAttempt(quiz: quiz))
    #expect(QuizAttempt(quiz: Quiz(questions: [])).showsResults)
}

// MARK: Store and library

@Test func quizResultsSaveAndMigrateFromSchemaVersion5() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(5)))
    try old.saveLastOpenedLecture(courseID: "c", lectureID: "q")

    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == CourseStore.currentSchemaVersion)
    #expect(try store.lastOpenedLectures() == ["c": "q"])
    #expect(try store.allQuizResults().isEmpty)
    try store.saveQuizResult(QuizResult(correct: 1, total: 3, weakSkills: ["A", "B"]), courseID: "c", lectureID: "q")
    try store.saveQuizResult(QuizResult(correct: 3, total: 3, weakSkills: []), courseID: "c", lectureID: "q")
    try store.saveQuizResult(QuizResult(correct: 0, total: 1, weakSkills: ["It's \"quoted\""]), courseID: "d", lectureID: "q")
    #expect(try store.allQuizResults() == [
        "c": ["q": QuizResult(correct: 3, total: 3, weakSkills: [])],
        "d": ["q": QuizResult(correct: 0, total: 1, weakSkills: ["It's \"quoted\""])],
    ])
}

@Test func publishRejectsAMissingOrInvalidQuestionImage() throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    let manifest = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: manifest, encoding: .utf8)
    let path = "sections[1].lectures[0].quiz.questions[0].image.path"
    for (image, message) in [("media/missing.svg", "file does not exist"), ("content/plan.md", nil as String?)] {
        try text.replacingOccurrences(of: "path: media/section.svg\n                alt", with: "path: \(image)\n                alt")
            .write(to: manifest, atomically: true, encoding: .utf8)
        do {
            _ = try CoursePublisher.publish(courseFolder: folder, root: base.appending(path: "library"))
            Issue.record("Expected publish to fail for \(image)")
        } catch let error as ManifestValidationError {
            #expect(error.diagnostics.map(\.fieldPath) == [path])
            if let message { #expect(error.diagnostics.first?.message == message) }
        }
    }
}

@MainActor @Test func libraryKeepsTheAttemptAndSavesTheResult() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .quizQuestion, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    let quizDestination = CourseDestination.lecture(sectionID: "practice", lectureID: "check")
    library.selectDestination(quizDestination)
    #expect(library.selectedQuiz?.questions.count == 3)
    library.performQuizAction(.selectNumber(1))
    library.performQuizAction(.submit)
    // The attempt stays in memory when the learner leaves the lecture and comes back.
    library.selectDestination(.overview)
    #expect(library.selectedQuizAttempt == nil)
    library.selectDestination(quizDestination)
    #expect(library.selectedQuizAttempt?.answers == ["outline": "sections"])
    for action: QuizAction in [.next, .selectNumber(2), .submit, .next, .selectNumber(2), .submit, .next] {
        library.performQuizAction(action)
    }
    let expected = QuizResult(correct: 1, total: 3, weakSkills: ["Order course sections", "Check a lecture objective"])
    #expect(library.selectedQuizAttempt?.result == expected)
    #expect(library.quizResults[courseID]?["check"] == expected)
    await library.waitForWrites()
    #expect(try CourseStore(root: root).allQuizResults() == [courseID: ["check": expected]])
    // Retake starts a new attempt and keeps the saved result until the learner finishes again.
    library.performQuizAction(.retake)
    #expect(library.selectedQuizAttempt?.question?.id == "outline")
    await library.reload()
    #expect(library.quizResults[courseID]?["check"] == expected)
    // Non-quiz lectures have no quiz.
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    #expect(library.selectedQuiz == nil)
}
