import Foundation
import SQLite3
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func withStore(_ body: (CourseStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LectureConversationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try body(CourseStore(root: root), root)
}

private func course(_ id: String = "c", lectures: [String] = ["a", "b"]) -> Course {
    Course(id: id, title: "Garden Basics", state: .published, sections: [
        CourseSection(id: "s", title: "Start", order: 0, state: .published,
                      lectures: lectures.enumerated().map { Lecture(id: $1, title: $1, type: .article, order: $0, state: .published) }),
    ])
}

private func rowCount(_ table: String, _ store: CourseStore) throws -> Int {
    let database = try SQLiteDatabase(url: store.databaseURL)
    return try database.query("SELECT COUNT(*) FROM \(table)") { Int(sqlite3_column_int64($0, 0)) }.first ?? -1
}

private func turn(_ id: Int64, _ status: QATurnStatus, revision: String = "r2", question: String = "Q", answer: String = "A") -> QATurn {
    QATurn(id: id, question: question, answer: answer, status: status, sourceRevision: revision, askedAt: Date(timeIntervalSince1970: 0))
}

private func passages(_ texts: [String]) -> [LecturePassage] {
    texts.enumerated().map { LecturePassage(id: "a\($0)", label: "Plan", text: $1) }
}

// MARK: Store

@Test func migrationFromVersion10KeepsDataAndAddsQATables() throws {
    try withStore { (_: CourseStore, root: URL) throws in
        let other = root.appending(path: "old")
        let old = try CourseStore(root: other, migrations: Array(CourseStore.migrations.prefix(10)))
        #expect(try old.schemaVersion == 10)
        try old.saveCourse(course())
        try old.setCompletedByHand(false, courseID: "c", lectureID: "a")
        try old.saveLastOpenedLecture(courseID: "c", lectureID: "b")
        #expect(throws: CourseStoreError.databaseFailure) { try old.qaTurns(courseID: "c", lectureID: "a") }

        let store = try CourseStore(root: other)
        #expect(try store.schemaVersion == CourseStore.currentSchemaVersion)
        #expect(CourseStore.currentSchemaVersion == 11)
        #expect(try store.loadCourse(id: "c") == course())
        #expect(try store.allProgress() == ["c": ["a": LectureProgress(completed: false, autoCompleteOff: true)]])
        #expect(try store.lastOpenedLectures() == ["c": "b"])
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").isEmpty)
        _ = try store.startQATurn(question: "Why?", sourceRevision: "r", courseID: "c", lectureID: "a")
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").count == 1)
    }
}

@Test func turnIsSavedBeforeTheRequestAndFinishedOnce() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        try store.saveCourse(course())
        let asked = Date(timeIntervalSince1970: 1_800_000_000.5)
        let first = try store.startQATurn(question: "What is soil?", sourceRevision: "r1", courseID: "c", lectureID: "a", askedAt: asked)
        #expect(first.status == .pending && first.answer.isEmpty && first.askedAt == asked)
        // The pending question survives a restart before the answer ends.
        #expect(try CourseStore(root: root).qaTurns(courseID: "c", lectureID: "a") == [first])

        #expect(try store.finishQATurn(id: first.id, status: .complete, answer: "Soil holds water."))
        #expect(try !store.finishQATurn(id: first.id, status: .cancelled, answer: "changed"))
        let second = try store.startQATurn(question: "And sand?", sourceRevision: "r1", courseID: "c", lectureID: "a")
        try store.finishQATurn(id: second.id, status: .cancelled, answer: "Sand")
        let third = try store.startQATurn(question: "And clay?", sourceRevision: "r1", courseID: "c", lectureID: "a")
        try store.finishQATurn(id: third.id, status: QATurnStatus(outcome: .httpError(status: 500)), answer: "")
        #expect(throws: CourseStoreError.invalidData) { try store.finishQATurn(id: third.id, status: .pending, answer: "") }

        let turns = try CourseStore(root: root).qaTurns(courseID: "c", lectureID: "a")
        #expect(turns.map(\.question) == ["What is soil?", "And sand?", "And clay?"])
        #expect(turns.map(\.status) == [.complete, .cancelled, .failed(reason: "Local AI returned an error (500). Try again.")])
        #expect(turns.map(\.answer) == ["Soil holds water.", "Sand", ""])
        #expect(turns.allSatisfy { $0.sourceRevision == "r1" })
        #expect(try store.qaTurns(courseID: "c", lectureID: "b").isEmpty)
        // A thread needs its course row.
        #expect(throws: CourseStoreError.databaseFailure) {
            try store.startQATurn(question: "Q", sourceRevision: "r", courseID: "absent", lectureID: "a")
        }
    }
}

@Test func pendingTurnsBecomeInterruptedAndDoNotFinishLater() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        try store.saveCourse(course())
        let done = try store.startQATurn(question: "One", sourceRevision: "r", courseID: "c", lectureID: "a")
        try store.finishQATurn(id: done.id, status: .complete, answer: "Done")
        let pending = try store.startQATurn(question: "Two", sourceRevision: "r", courseID: "c", lectureID: "a")
        try store.interruptPendingQATurns()
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").map(\.status) == [.complete, .interrupted])
        #expect(try !store.finishQATurn(id: pending.id, status: .complete, answer: "Late"))
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").last?.answer == "")
    }
}

@Test func clearHistoryRemovesOneLectureOnly() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        try store.saveCourse(course())
        try store.saveCourse(course("d"))
        for (courseID, lectureID) in [("c", "a"), ("c", "a"), ("c", "b"), ("d", "a")] {
            _ = try store.startQATurn(question: "Q", sourceRevision: "r", courseID: courseID, lectureID: lectureID)
        }
        let pending = try store.qaTurns(courseID: "c", lectureID: "a")[0]
        try store.clearQAHistory(courseID: "c", lectureID: "a")
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").isEmpty)
        #expect(try store.qaTurns(courseID: "c", lectureID: "b").count == 1)
        #expect(try store.qaTurns(courseID: "d", lectureID: "a").count == 1)
        #expect(try rowCount("qa_threads", store) == 2)
        // A request that ends after Clear History does not bring its turn back.
        #expect(try !store.finishQATurn(id: pending.id, status: .complete, answer: "Late"))
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").isEmpty)
        try store.clearQAHistory(courseID: "c", lectureID: "absent")
    }
}

@Test func courseDeletionRemovesItsQAHistory() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        for id in ["c", "d", "e"] { try store.saveCourse(course(id)) }
        for id in ["c", "d", "e"] { _ = try store.startQATurn(question: "Q", sourceRevision: "r", courseID: id, lectureID: "a") }
        try store.deleteCourse(id: "c")
        _ = try store.removeCourse(id: "d")
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").isEmpty)
        #expect(try store.qaTurns(courseID: "d", lectureID: "a").isEmpty)
        #expect(try store.qaTurns(courseID: "e", lectureID: "a").count == 1)
        #expect(try rowCount("qa_threads", store) == 1)
        #expect(try rowCount("qa_messages", store) == 1)
    }
}

@Test func republishKeepsHistoryOfStableLectureIDs() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        try store.saveCourse(course())
        let saved = try store.startQATurn(question: "Q", sourceRevision: "r", courseID: "c", lectureID: "a")
        // The save replaces the section and lecture rows. The thread has no foreign key to them.
        var changed = course(lectures: ["b", "a", "new"])
        changed.title = "Garden Basics 2"
        try store.saveCourse(changed)
        try store.saveCourse(course(lectures: ["b"]))
        try store.saveCourse(course())
        #expect(try store.qaTurns(courseID: "c", lectureID: "a") == [saved])
    }
}

// MARK: Conversation

@Test func sourceRevisionChangesOnlyWithTheLectureText() {
    let base = LectureContext(courseTitle: "C", lectureTitle: "L", passages: passages(["One", "Two"]))
    #expect(base.sourceRevision.count == 64)
    #expect(LectureContext(courseTitle: "New", lectureTitle: "New", passages: passages(["One", "Two"])).sourceRevision == base.sourceRevision)
    #expect(LectureContext(courseTitle: "C", lectureTitle: "L", passages: passages(["One", "Two."])).sourceRevision != base.sourceRevision)
    #expect(LectureContext(courseTitle: "C", lectureTitle: "L", passages: passages(["OneTwo"])).sourceRevision != base.sourceRevision)
    #expect(LectureContext(courseTitle: "C", lectureTitle: "L", passages: passages(["Two", "One"])).sourceRevision != base.sourceRevision)
}

@Test func earlierVersionTurnsAreLabeledAndCannotRetry() {
    let turns = [turn(1, .complete, revision: "r1"), turn(2, .failed(reason: "x"), revision: "r1"),
                 turn(3, .cancelled), turn(4, .interrupted), turn(5, .complete), turn(6, .pending)]
    let conversation = LectureConversation(turns: turns, sourceRevision: "r2")
    #expect(conversation.earlierTurns.map(\.id) == [1, 2])
    #expect(conversation.currentTurns.map(\.id) == [3, 4, 5, 6])
    #expect(turns.filter(conversation.canRetry).map(\.id) == [3, 4])
    // With no current revision the divider does not show.
    let unknown = LectureConversation(turns: turns, sourceRevision: nil)
    #expect(unknown.earlierTurns.isEmpty)
    #expect(turns.filter(unknown.canRetry).map(\.id) == [2, 3, 4])
    #expect(LectureConversation(turns: [], sourceRevision: "r").earlierTurns.isEmpty)
}

@Test func statusLabelsMatchTheDesignNotes() {
    #expect(QATurnStatus.complete.label == nil && QATurnStatus.pending.label == nil)
    #expect(QATurnStatus.cancelled.label == "Cancelled" && QATurnStatus.cancelled.systemImage == "stop.circle")
    #expect(QATurnStatus.interrupted.label == "Interrupted" && QATurnStatus.interrupted.systemImage == "exclamationmark.triangle")
    let failed = QATurnStatus(outcome: .empty)
    #expect(failed.label == "No answer: The model gave no answer. Try again.")
    #expect(failed.systemImage == "exclamationmark.triangle")
    #expect(QATurnStatus(outcome: .finished) == .complete)
    #expect(QATurnStatus(outcome: .canceled) == .cancelled)
    for outcome: AnswerOutcome in [.disconnected, .malformed, .httpError(status: 503), .untrusted, .busy] {
        #expect(QATurnStatus(outcome: outcome) == .failed(reason: outcome.learnerText ?? ""), "\(outcome)")
    }
    #expect(turn(1, .cancelled, question: "Why?", answer: "Because").accessibilityLabel == "Question: Why?. Answer: Because, Cancelled")
    #expect(turn(1, .complete, question: "Why?", answer: "Because").accessibilityLabel == "Question: Why?. Answer: Because")
}

@Test func promptHasOnlyCompleteTurnsOfTheCurrentVersion() {
    let context = LectureContext(courseTitle: "C", lectureTitle: "L", passages: passages(["Soil holds water."]))
    let now = context.sourceRevision
    let turns = [turn(1, .complete, revision: "old", question: "Old question", answer: "Old answer"),
                 turn(2, .complete, revision: now, question: "Q2", answer: "A2"),
                 turn(3, .cancelled, revision: now, question: "Q3", answer: "Partial"),
                 turn(4, .failed(reason: "x"), revision: now, question: "Q4", answer: ""),
                 turn(5, .interrupted, revision: now, question: "Q5", answer: "Partial"),
                 turn(6, .complete, revision: now, question: "Q6", answer: "A6"),
                 turn(7, .pending, revision: now, question: "Q7", answer: "")]
    let messages = LectureConversation(turns: turns, sourceRevision: now).messages(context: context, question: "Next?")
    #expect(messages == [ChatMessage(role: .system, content: context.systemPrompt),
                         ChatMessage(role: .user, content: "Q2"), ChatMessage(role: .assistant, content: "A2"),
                         ChatMessage(role: .user, content: "Q6"), ChatMessage(role: .assistant, content: "A6"),
                         ChatMessage(role: .user, content: "Next?")])
    // With no saved turns the prompt is the same as the prompt of #125.
    #expect(LectureConversation(turns: [], sourceRevision: now).messages(context: context, question: "Next?")
            == context.messages(question: "Next?"))
}

@Test func promptKeepsTheNewestTurnsThatFitTheBudget() {
    let context = LectureContext(courseTitle: "C", lectureTitle: "L", passages: passages(["Soil."]))
    let now = context.sourceRevision
    let long = String(repeating: "x", count: 300)
    let turns = (1...5).map { turn(Int64($0), .complete, revision: now, question: "Q\($0)", answer: long) }
    // Room for two turns of about 101 tokens each, but not three.
    let budget = LectureContextBudget(contextTokens: context.estimatedTokens + 250, answerTokens: 0, questionTokens: 0)
    let messages = LectureConversation(turns: turns, sourceRevision: now).messages(context: context, question: "Q6", budget: budget)
    #expect(messages.filter { $0.role == .user }.map(\.content) == ["Q4", "Q5", "Q6"])
    let none = LectureContextBudget(contextTokens: context.estimatedTokens, answerTokens: 0, questionTokens: 0)
    #expect(LectureConversation(turns: turns, sourceRevision: now).messages(context: context, question: "Q6", budget: none).count == 2)
    // An old turn that is too long stops the history, so the turns stay in order with no gap.
    var gap = turns
    gap[3] = turn(4, .complete, revision: now, question: "Q4", answer: String(repeating: "y", count: 3000))
    #expect(LectureConversation(turns: gap, sourceRevision: now).messages(context: context, question: "Q6", budget: budget)
        .filter { $0.role == .user }.map(\.content) == ["Q5", "Q6"])
}

// MARK: Library

@MainActor @Test func libraryKeepsTheThreadAcrossRestartAndRepublish() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "LectureConversationFixture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course"), root = base.appending(path: "library")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try CoursePublisher.publish(courseFolder: folder, root: root)

    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("sample-course")
    guard case .ready(let context) = await library.lectureContext(forLecture: "read") else {
        Issue.record("The article has no context")
        return
    }
    let first = try await library.startQATurn(question: "What is step one?", context: context, lectureID: "read")
    library.finishQATurn(first, outcome: .finished, text: "Write the goal [a3].")
    _ = try await library.startQATurn(question: "And then?", context: context, lectureID: "read")
    #expect(try await library.lectureConversation(forLecture: "read")?.turns.map(\.status) == [.complete, .pending])
    // A second reload in the same run keeps the active request pending.
    await library.reload()
    #expect(try await library.lectureConversation(forLecture: "read")?.turns.last?.status == .pending)

    // After a restart the thread is the same, and the pending turn is interrupted.
    let restarted = LibraryModel(root: root)
    await restarted.reload()
    restarted.selectCourse("sample-course")
    let afterRestart = try #require(try await restarted.lectureConversation(forLecture: "read"))
    #expect(afterRestart.turns.map(\.question) == ["What is step one?", "And then?"])
    #expect(afterRestart.turns.map(\.status) == [.complete, .interrupted])
    #expect(afterRestart.earlierTurns.isEmpty)
    #expect(try await restarted.lectureConversation(forLecture: "welcome")?.turns == [])
    #expect(try await restarted.lectureConversation(forLecture: "check") == nil)

    // A republish with the same article text keeps the turns current.
    let manifest = folder.appending(path: "skillgarden.yaml")
    let yaml = try String(contentsOf: manifest, encoding: .utf8)
    try yaml.replacingOccurrences(of: "title: Local Course Basics", with: "title: Local Course Basics 2")
        .write(to: manifest, atomically: true, encoding: .utf8)
    try CoursePublisher.publish(courseFolder: folder, root: root)
    await restarted.reload()
    #expect(try await restarted.lectureConversation(forLecture: "read")?.earlierTurns.isEmpty == true)

    // A changed article text puts the turns above the earlier-version divider and out of new prompts.
    let plan = folder.appending(path: "content/plan.md")
    try (String(contentsOf: plan, encoding: .utf8) + "\nA new paragraph.\n").write(to: plan, atomically: true, encoding: .utf8)
    try CoursePublisher.publish(courseFolder: folder, root: root)
    await restarted.reload()
    let republished = try #require(try await restarted.lectureConversation(forLecture: "read"))
    #expect(republished.earlierTurns.count == 2 && republished.currentTurns.isEmpty)
    guard case .ready(let newContext) = await restarted.lectureContext(forLecture: "read") else {
        Issue.record("The article has no context")
        return
    }
    #expect(newContext.sourceRevision != context.sourceRevision)
    #expect(republished.messages(context: newContext, question: "Q") == newContext.messages(question: "Q"))

    // A lecture that leaves the published outline shows no history. The history comes back with the lecture.
    try yaml.replacingOccurrences(of: "state: published\n        order: 1\n        article:", with: "state: draft\n        order: 1\n        article:")
        .write(to: manifest, atomically: true, encoding: .utf8)
    #expect(try String(contentsOf: manifest, encoding: .utf8) != yaml)
    try CoursePublisher.publish(courseFolder: folder, root: root)
    await restarted.reload()
    restarted.selectCourse("sample-course")
    #expect(try await restarted.lectureConversation(forLecture: "read") == nil)
    try yaml.write(to: manifest, atomically: true, encoding: .utf8)
    try CoursePublisher.publish(courseFolder: folder, root: root)
    await restarted.reload()
    #expect(try await restarted.lectureConversation(forLecture: "read")?.turns.count == 2)

    // Clear History empties this lecture only.
    restarted.clearQAHistory(forLecture: "read")
    #expect(try await restarted.lectureConversation(forLecture: "read")?.turns == [])
}
