import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// The `quick_checks` block of the sample video lecture, exactly as in `skillgarden.yaml`.
let sampleQuickChecksYAML = """
              quick_checks:
                - prompt: Where does a Skillgarden course live?
                  choices:
                    - id: local
                      text: On this Mac
                    - id: server
                      text: On a web server
                  correct_choice_id: local
                - prompt: What does the course outline show first?
                  choices:
                    - id: sections
                      text: The sections, in order
                    - id: scores
                      text: The quiz scores
                  correct_choice_id: sections
                  explanation: The outline lists the sections in order, and each section lists its lectures.

    """

private let path = "sections[0].lectures[0].video.quick_checks"

/// Gives each test a writable copy of the sample course and an empty library root.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenQuickCheckTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try body(folder, base.appending(path: "library"))
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let url = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
}

/// Publishes and returns the diagnostics as "field: message" lines. Returns [] when the publish succeeds.
private func publishErrors(_ folder: URL, _ root: URL) throws -> [String] {
    do {
        _ = try CoursePublisher.publish(courseFolder: folder, root: root)
        return []
    } catch let error as ManifestValidationError {
        return error.diagnostics.map { "\($0.fieldPath): \($0.message)" }
    }
}

/// One check in the fixture YAML indentation.
private func checkYAML(_ prompt: String, choices: [String] = ["a", "b"], correct: String = "a") -> String {
    "            - prompt: \(prompt)\n              choices:\n"
        + choices.map { "                - id: \($0)\n                  text: Choice \($0)\n" }.joined()
        + "              correct_choice_id: \(correct)\n"
}

// MARK: Manifest

@Test func manifestReadsTheSampleQuickChecks() throws {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    let checks = try #require(manifest.sections[0].lectures[0].video?.quickChecks)
    #expect(checks.map(\.prompt) == ["Where does a Skillgarden course live?", "What does the course outline show first?"])
    #expect(checks[0].explanation == nil)
    #expect(checks[1].correctChoiceID == "sections")
    #expect(checks[1].choices.map(\.id) == ["sections", "scores"])

    // A manifest saved before quick-check support decodes with no checks.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[0]["lectures"] as? [[String: Any]])
    var video = try #require(lectures[0]["video"] as? [String: Any])
    video.removeValue(forKey: "quick_checks")
    lectures[0]["video"] = video
    sections[0]["lectures"] = lectures
    object["sections"] = sections
    let old = try JSONDecoder().decode(CourseManifest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.sections[0].lectures[0].video?.quickChecks == nil)
    #expect(LectureVideo(folder: fixture, video: try #require(old.sections[0].lectures[0].video))?.quickChecks == [])
}

@Test func publishAcceptsOneOrTwoQuickChecks() throws {
    try withCourse { folder, root throws in
        #expect(try publishErrors(folder, root) == [])
    }
    try withCourse { folder, root in
        try edit(folder, sampleQuickChecksYAML, "          quick_checks:\n" + checkYAML("Only one?"))
        #expect(try publishErrors(folder, root) == [])
    }
    try withCourse { folder, root in
        try edit(folder, sampleQuickChecksYAML, "")
        #expect(try publishErrors(folder, root) == [])
    }
}

@Test func publishRejectsMoreThanTwoQuickChecks() throws {
    try withCourse { folder, root in
        try edit(folder, sampleQuickChecksYAML, sampleQuickChecksYAML + checkYAML("Third?"))
        #expect(try publishErrors(folder, root) == ["\(path): must have at most 2 checks"])
    }
    try withCourse { folder, root in
        try edit(folder, sampleQuickChecksYAML, "          quick_checks: []\n\n")
        #expect(try publishErrors(folder, root) == ["\(path): must have at least one check"])
    }
}

@Test func publishChecksQuickCheckChoices() throws {
    try withCourse { folder, root in
        try edit(folder, sampleQuickChecksYAML, "          quick_checks:\n" + checkYAML("One choice?", choices: ["a"]) + "\n")
        #expect(try publishErrors(folder, root) == ["\(path)[0].choices: must have at least two choices"])
    }
    try withCourse { folder, root in
        try edit(folder, sampleQuickChecksYAML, "          quick_checks:\n" + checkYAML("Twice?", choices: ["a", "a"]) + "\n")
        #expect(try publishErrors(folder, root) == [
            "\(path)[0].choices[1].id: duplicate id \"a\" (first used at \(path)[0].choices[0].id)",
        ])
    }
    try withCourse { folder, root in
        try edit(folder, sampleQuickChecksYAML, "          quick_checks:\n" + checkYAML("Missing?", correct: "z") + "\n")
        #expect(try publishErrors(folder, root) == ["\(path)[0].correct_choice_id: must refer to a choice id in this question"])
    }
    try withCourse { folder, root in
        // Choice ids are unique inside their check only, so a lecture id or a quiz choice id can repeat.
        try edit(folder, sampleQuickChecksYAML, "          quick_checks:\n" + checkYAML("Shared?", choices: ["read", "sections"], correct: "read")
                 + checkYAML("Again?", choices: ["read", "sections"], correct: "sections") + "\n")
        #expect(try publishErrors(folder, root) == [])
    }
    try withCourse { folder, root in
        try edit(folder, "              correct_choice_id: local\n", "")
        try edit(folder, "              explanation: The outline lists", "              explanation: 3\n              note: The outline lists")
        #expect(try publishErrors(folder, root) == [
            "\(path)[0].correct_choice_id: required field is missing",
            "\(path)[1].explanation: expected string, found integer",
        ])
    }
}

// MARK: Session

private let checks = [
    QuickCheck(id: 0, prompt: "First?", choices: [QuizChoice(id: "a", text: "A"), QuizChoice(id: "b", text: "B")],
               correctChoiceID: "a"),
    QuickCheck(id: 1, prompt: "Second?", choices: [QuizChoice(id: "x", text: "X"), QuizChoice(id: "y", text: "Y"),
                                                   QuizChoice(id: "z", text: "Z")],
               correctChoiceID: "y", explanation: "Y is right."),
]

@Test func quickCheckChecksKeepManifestOrderAndDropBlankExplanations() {
    let manifest = [
        ManifestQuickCheck(prompt: "P1", choices: [ManifestQuizChoice(id: "a", text: "A")], correctChoiceID: "a", explanation: "  "),
        ManifestQuickCheck(prompt: "P2", choices: [], correctChoiceID: "a", explanation: " Why "),
    ]
    let result = QuickCheck.checks(manifest: manifest)
    #expect(result.map(\.id) == [0, 1])
    #expect(result.map(\.explanation) == [nil, "Why"])
    #expect(QuickCheck.checks(manifest: nil) == [])
}

@Test func quickCheckSessionLocksTheFirstAnswerAndShowsTheExplanationForEveryPick() {
    var session = QuickCheckSession(checks: checks)
    #expect(session.buttonTitle == "Quick Check (2)")
    #expect(session.isCorrect(1) == nil)
    #expect(session.resultLine(1) == nil)
    #expect(session.shownExplanation(1) == nil)
    #expect(checks[1].choices.map { session.state(of: $0, in: 1) } == [.normal, .normal, .normal])

    // A wrong pick: the pick is red, the correct choice is green, the explanation shows.
    session.answer(checkID: 1, choiceID: "x")
    #expect(session.isCorrect(1) == false)
    #expect(session.resultLine(1) == "Not quite")
    #expect(session.shownExplanation(1) == "Y is right.")
    #expect(checks[1].choices.map { session.state(of: $0, in: 1) } == [.incorrect, .correct(picked: false), .dimmed])
    // The choices are locked.
    session.answer(checkID: 1, choiceID: "y")
    #expect(session.answers[1] == "x")

    // A correct pick also shows the explanation.
    session.tryAgain(checkID: 1)
    #expect(session.isCorrect(1) == nil)
    session.answer(checkID: 1, choiceID: "y")
    #expect(session.resultLine(1) == "Correct")
    #expect(session.shownExplanation(1) == "Y is right.")
    #expect(checks[1].choices.map { session.state(of: $0, in: 1) } == [.dimmed, .correct(picked: true), .dimmed])

    // A check without an explanation shows only the result line.
    session.answer(checkID: 0, choiceID: "b")
    #expect(session.resultLine(0) == "Not quite")
    #expect(session.shownExplanation(0) == nil)
}

@Test func quickCheckTryAgainResetsOneCheckOnly() {
    var session = QuickCheckSession(checks: checks)
    session.answer(checkID: 0, choiceID: "a")
    session.answer(checkID: 1, choiceID: "z")
    session.tryAgain(checkID: 1)
    #expect(session.answers == [0: "a"])
    session.tryAgain(checkID: 5)
    #expect(session.answers == [0: "a"])
}

@Test func quickCheckIgnoresUnknownChecksAndChoices() {
    var session = QuickCheckSession(checks: checks)
    session.answer(checkID: 1, choiceID: "missing")
    session.answer(checkID: 9, choiceID: "a")
    // A choice id of the other check does not answer this check.
    session.answer(checkID: 0, choiceID: "y")
    #expect(session.answers.isEmpty)
    #expect(session.isCorrect(9) == nil)
    #expect(session.state(of: QuizChoice(id: "a", text: "A"), in: 9) == .normal)
}

// MARK: Library

@MainActor @Test func libraryKeepsQuickCheckAnswersForTheSessionOnly() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenQuickCheckTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .videoQuickCheck, root: base, fixture: fixture))
    let library = LibraryModel(root: base)
    await library.reload()
    library.selectCourse(courseID)
    let welcome = CourseDestination.lecture(sectionID: "plan", lectureID: "welcome")
    library.selectDestination(welcome)
    let session = try #require(library.selectedQuickChecks)
    #expect(session.checks.count == 2)
    #expect(session.checks.map(\.prompt) == ["Where does a Skillgarden course live?", "What does the course outline show first?"])

    library.answerQuickCheck(1, choiceID: "scores")
    library.answerQuickCheck(0, choiceID: "local")
    #expect(library.selectedQuickChecks?.answers == [0: "local", 1: "scores"])
    library.retryQuickCheck(1)
    #expect(library.selectedQuickChecks?.answers == [0: "local"])

    // An article lecture has no quick checks, and its actions do nothing.
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "read"))
    #expect(library.selectedQuickChecks == nil)
    library.answerQuickCheck(1, choiceID: "sections")
    // The answers stay while the app runs.
    library.selectDestination(welcome)
    #expect(library.selectedQuickChecks?.answers == [0: "local"])

    // A new app session starts with no answers.
    let next = LibraryModel(root: base)
    await next.reload()
    next.selectCourse(courseID)
    next.selectDestination(welcome)
    #expect(next.selectedQuickChecks?.answers == [:])
}

@MainActor @Test func libraryHasNoQuickChecksForAVideoWithoutThem() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenQuickCheckTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appending(path: "course")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    let yaml = folder.appending(path: "skillgarden.yaml")
    try String(contentsOf: yaml, encoding: .utf8).replacingOccurrences(of: sampleQuickChecksYAML, with: "")
        .write(to: yaml, atomically: true, encoding: .utf8)
    let root = base.appending(path: "library")
    let courseID = try CoursePublisher.publish(courseFolder: folder, root: root).id
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    #expect(library.video(forLecture: "welcome")?.quickChecks == [])
    #expect(library.selectedQuickChecks == nil)
}
