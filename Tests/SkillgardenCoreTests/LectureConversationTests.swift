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
        #expect(CourseStore.currentSchemaVersion == 13)
        #expect(try store.loadCourse(id: "c") == course())
        #expect(try store.allProgress() == ["c": ["a": LectureProgress(completed: false, autoCompleteOff: true)]])
        #expect(try store.lastOpenedLectures() == ["c": "b"])
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").isEmpty)
        _ = try store.startQATurn(question: "Why?", sourceRevision: "r", origin: .legacy, courseID: "c", lectureID: "a")
        #expect(try store.qaTurns(courseID: "c", lectureID: "a").count == 1)
    }
}

@Test func turnIsSavedBeforeTheRequestAndFinishedOnce() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        try store.saveCourse(course())
        let asked = Date(timeIntervalSince1970: 1_800_000_000.5)
        let first = try store.startQATurn(question: "What is soil?", sourceRevision: "r1", origin: .legacy, courseID: "c", lectureID: "a", askedAt: asked)
        #expect(first.status == .pending && first.answer.isEmpty && first.askedAt == asked)
        // The pending question survives a restart before the answer ends.
        #expect(try CourseStore(root: root).qaTurns(courseID: "c", lectureID: "a") == [first])

        #expect(try store.finishQATurn(id: first.id, status: .complete, answer: "Soil holds water."))
        #expect(try !store.finishQATurn(id: first.id, status: .cancelled, answer: "changed"))
        let second = try store.startQATurn(question: "And sand?", sourceRevision: "r1", origin: .legacy, courseID: "c", lectureID: "a")
        try store.finishQATurn(id: second.id, status: .cancelled, answer: "Sand")
        let third = try store.startQATurn(question: "And clay?", sourceRevision: "r1", origin: .legacy, courseID: "c", lectureID: "a")
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
            try store.startQATurn(question: "Q", sourceRevision: "r", origin: .legacy, courseID: "absent", lectureID: "a")
        }
    }
}

@Test func pendingTurnsBecomeInterruptedAndDoNotFinishLater() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        try store.saveCourse(course())
        let done = try store.startQATurn(question: "One", sourceRevision: "r", origin: .legacy, courseID: "c", lectureID: "a")
        try store.finishQATurn(id: done.id, status: .complete, answer: "Done")
        let pending = try store.startQATurn(question: "Two", sourceRevision: "r", origin: .legacy, courseID: "c", lectureID: "a")
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
            _ = try store.startQATurn(question: "Q", sourceRevision: "r", origin: .legacy, courseID: courseID, lectureID: lectureID)
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

@Test func courseRemovalKeepsQAHistoryAndARepublishShowsIt() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        for id in ["c", "d"] { try store.saveCourse(course(id)) }
        let pending = try store.startQATurn(question: "Q", sourceRevision: "r", origin: .legacy, courseID: "c", lectureID: "a")
        let started = try store.startQATurn(question: "Why?", sourceRevision: "r", origin: .legacy, courseID: "d", lectureID: "a")
        try store.finishQATurn(id: started.id, status: .complete, answer: "Because")
        let done = QATurn(id: started.id, question: "Why?", answer: "Because", status: .complete, sourceRevision: "r",
                          askedAt: started.askedAt)
        try store.deleteCourse(id: "c")
        #expect(try store.removeCourse(id: "d")?.title == "Garden Basics")
        // The rows stay, like learner progress (#118). A removed course starts no new thread.
        #expect(try rowCount("qa_threads", store) == 2)
        #expect(try rowCount("qa_messages", store) == 2)
        #expect(throws: CourseStoreError.databaseFailure) {
            try store.startQATurn(question: "Q", sourceRevision: "r", origin: .legacy, courseID: "d", lectureID: "a")
        }
        // A publish of the same course id shows the history again, also after a restart.
        try store.saveCourse(course("d"))
        try store.saveCourse(course("c"))
        let reopened = try CourseStore(root: root)
        #expect(try reopened.qaTurns(courseID: "d", lectureID: "a") == [done])
        #expect(try reopened.qaTurns(courseID: "c", lectureID: "a") == [pending])
        // Clear History still removes the turns of its thread.
        try reopened.clearQAHistory(courseID: "d", lectureID: "a")
        #expect(try rowCount("qa_threads", reopened) == 1)
        #expect(try rowCount("qa_messages", reopened) == 1)
    }
}

@Test func republishKeepsHistoryOfStableLectureIDs() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        try store.saveCourse(course())
        let saved = try store.startQATurn(question: "Q", sourceRevision: "r", origin: .legacy, courseID: "c", lectureID: "a")
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

@Test func promptHasOnlyCompleteTurnsOfTheCurrentVersion() throws {
    let context = LectureContext(courseTitle: "C", lectureTitle: "L", passages: passages(["Soil holds water."]))
    let now = context.sourceRevision
    let turns = [turn(1, .complete, revision: "old", question: "Old question", answer: "Old answer"),
                 turn(2, .complete, revision: now, question: "Q2", answer: "A2"),
                 turn(3, .cancelled, revision: now, question: "Q3", answer: "Partial"),
                 turn(4, .failed(reason: "x"), revision: now, question: "Q4", answer: ""),
                 turn(5, .interrupted, revision: now, question: "Q5", answer: "Partial"),
                 turn(6, .complete, revision: now, question: "Q6", answer: "A6"),
                 turn(7, .pending, revision: now, question: "Q7", answer: "")]
    let prompt = try #require(LectureConversation(turns: turns, sourceRevision: now).prompt(context: context, question: "Next?"))
    #expect(prompt.messages == [ChatMessage(role: .system, content: prompt.systemPrompt),
                                ChatMessage(role: .user, content: "Q2"), ChatMessage(role: .assistant, content: "A2"),
                                ChatMessage(role: .user, content: "Q6"), ChatMessage(role: .assistant, content: "A6"),
                                ChatMessage(role: .user, content: "Next?")])
    #expect(prompt.systemPrompt == context.prompt(question: "Next?").systemPrompt)
    // With no saved turns the prompt is the same as the prompt of #126.
    #expect(LectureConversation(turns: [], sourceRevision: now).prompt(context: context, question: "Next?")
            == context.prompt(question: "Next?"))
}

@Test func promptKeepsTheNewestTurnsThatFitTheBudget() throws {
    let text = passages(["Soil."])
    let estimate = LectureContext(courseTitle: "C", lectureTitle: "L", passages: text).estimatedTokens
    func context(free: Int) -> LectureContext {
        // The question "Q6" is 1 token, so the free tokens are `free - 1`.
        LectureContext(courseTitle: "C", lectureTitle: "L", passages: text,
                       budget: LectureContextBudget(contextTokens: estimate + free, answerTokens: 0, questionTokens: 0))
    }
    let now = context(free: 0).sourceRevision
    let long = String(repeating: "x", count: 300)
    let turns = (1...5).map { turn(Int64($0), .complete, revision: now, question: "Q\($0)", answer: long) }
    func users(_ turns: [QATurn], free: Int) throws -> [String] {
        let prompt = try #require(LectureConversation(turns: turns, sourceRevision: now).prompt(context: context(free: free), question: "Q6"))
        #expect(!prompt.isPartial)
        return prompt.messages.filter { $0.role == .user }.map(\.content)
    }
    // Room for two turns of 101 tokens each, but not three.
    #expect(try users(turns, free: 250) == ["Q4", "Q5", "Q6"])
    #expect(try users(turns, free: 203) == ["Q4", "Q5", "Q6"])
    #expect(try users(turns, free: 202) == ["Q5", "Q6"])
    #expect(try users(turns, free: 1) == ["Q6"])
    // An old turn that is too long stops the history, so the turns stay in order with no gap.
    var gap = turns
    gap[3] = turn(4, .complete, revision: now, question: "Q4", answer: String(repeating: "y", count: 3000))
    #expect(try users(gap, free: 250) == ["Q5", "Q6"])
}

@Test func longLecturePromptWithHistoryFitsTheBudget() throws {
    // 2,000 cues, about 6 times the passage budget of 1,200 tokens. Cue 1,900 is the only cue about compost.
    let cues = (0..<2_000).map { index in
        LecturePassage(id: "t\(index)", label: "0:00", text: index == 1_900 ? "Add compost in late autumn." : "Water the bed, step \(index).")
    }
    let budget = LectureContextBudget(contextTokens: 1_800, answerTokens: 400, questionTokens: 200)
    let context = LectureContext(courseTitle: "C", lectureTitle: "L", passages: cues, budget: budget)
    #expect(!context.fitsBudget)
    let now = context.sourceRevision
    let complete = (1...30).map { turn(Int64($0 + 2), .complete, revision: now, question: "Is step \($0) in late autumn?", answer: "Yes.") }
    let turns = [turn(1, .complete, revision: "old", question: "Which tractor?", answer: "Old answer"),
                 turn(2, .failed(reason: "x"), revision: now, question: "When do I add compost?", answer: "")] + complete
    let conversation = LectureConversation(turns: turns, sourceRevision: now)
    // "Why?" alone matches no cue. The questions of the current-version turns find the compost cue.
    #expect(context.prompt(question: "Why?").noEvidence)
    let prompt = try #require(conversation.prompt(context: context, question: "Why?"))
    let priorQuestions = turns.dropFirst().map(\.question)
    let retrieval = context.prompt(question: "Why?", priorQuestions: priorQuestions, historyTokens: 27 * 11)
    #expect(prompt.isPartial && !prompt.noEvidence)
    #expect(prompt.passages == retrieval.passages && prompt.systemPrompt == retrieval.systemPrompt)
    // The reserve leaves out some passages of the selection without history. It adds none.
    let all = context.prompt(question: "Why?", priorQuestions: priorQuestions).passages
    #expect(prompt.passages.count < all.count && Set(prompt.passages).isSubset(of: all))
    #expect(prompt.passages.contains { $0.id == "t1900" })
    #expect(prompt.messages.first == ChatMessage(role: .system, content: prompt.systemPrompt))
    #expect(prompt.messages.last == ChatMessage(role: .user, content: "Why?"))
    // The history is the newest complete turns that fit the free tokens. Old and failed turns stay out.
    let history = Array(prompt.messages.dropFirst().dropLast())
    let pairs = complete.flatMap { [ChatMessage(role: .user, content: $0.question), ChatMessage(role: .assistant, content: $0.answer)] }
    // Retrieval keeps a quarter of the passage budget free for the newest turns: 27 turns of 11 tokens.
    #expect(history.count >= 2 * 27 && history.count < pairs.count)
    #expect(history == Array(pairs.suffix(history.count)))
    let free = budget.contextTokens - budget.answerTokens - budget.questionTokens - prompt.estimatedTokens
    func tokens(_ messages: [ChatMessage]) -> Int { messages.map { LectureContextBudget.estimatedTokens($0.content) }.reduce(0, +) }
    #expect(tokens(history) <= free)
    #expect(tokens(Array(pairs.suffix(history.count + 2))) > free)
    // A match that fits only without the history reserve still gives a prompt. The passages take the history tokens.
    let big = LecturePassage(id: "a0", label: "Soil", text: "Compost " + String(repeating: "dirt ", count: 280))
    let small = LectureContext(courseTitle: "C", lectureTitle: "L", passages: [big] + passages(Array(repeating: "Water the bed.", count: 20)).dropFirst(),
                               budget: LectureContextBudget(contextTokens: 1_150, answerTokens: 200, questionTokens: 100))
    #expect(!small.fitsBudget)
    let saved = [turn(1, .complete, revision: small.sourceRevision, question: "Compost?", answer: String(repeating: "y", count: 450))]
    let fallback = try #require(LectureConversation(turns: saved, sourceRevision: small.sourceRevision).prompt(context: small, question: "Compost?"))
    #expect(fallback.passages.contains(big) && fallback.isPartial)
    #expect(fallback.passages == small.prompt(question: "Compost?", priorQuestions: ["Compost?"]).passages)
    #expect(fallback.messages.count == 2)
    // A question with no match in the lecture or the history gives no request.
    #expect(LectureConversation(turns: [], sourceRevision: now).prompt(context: context, question: "Which tractor?") == nil)
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
    let first = try await library.startQATurn(question: "What is step one?", context: context, origin: .legacy, lectureID: "read")
    library.finishQATurn(first, outcome: .finished, text: "Write the goal [a3].")
    _ = try await library.startQATurn(question: "And then?", context: context, origin: .legacy, lectureID: "read")
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
    #expect(republished.prompt(context: newContext, question: "Q") == newContext.prompt(question: "Q"))

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
