import Foundation
import Testing
@testable import SkillgardenCore

// #150: Q&A sends each question through `AnswerProvider`. Each turn stores the provider and model IDs.
// No test needs a model, a server or a network.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private let secret = String(repeating: "0123456789abcdef", count: 4)

/// A provider with no transport. The test sends the deltas by hand. Cancel ends the stream like `LlamaClient`.
@MainActor
private final class FakeProvider: AnswerProvider {
    let id = "test-provider"
    let displayName = "Test Provider"
    let kind = AnswerProviderKind.externalLocal
    var modelID: String? = "test-model"
    var isReady = true
    private(set) var asked: [[ChatMessage]] = []
    private(set) var cancelled: [UUID] = []
    private var active: (id: UUID, continuation: AsyncStream<AnswerUpdate>.Continuation, text: String)?

    var requestID: UUID? { active?.id }

    func prepare() -> PreparedAnswer? {
        guard isReady else { return nil }
        return PreparedAnswer(origin: AnswerOrigin(providerID: id, modelID: modelID)) { [weak self] messages in
            MainActor.assumeIsolated { self!.start(messages) }
        }
    }

    private func start(_ messages: [ChatMessage]) -> AnswerRequest {
        asked.append(messages)
        let (updates, continuation) = AsyncStream<AnswerUpdate>.makeStream()
        let id = UUID()
        active = (id, continuation, "")
        return AnswerRequest(id: id, updates: updates)
    }

    func send(_ text: String) {
        active?.text = text
        active?.continuation.yield(.delta(text: text))
    }

    func finish() {
        end(.finished)
    }

    func cancel(_ id: UUID) {
        cancelled.append(id)
        guard active?.id == id else { return }
        end(.canceled)
    }

    private func end(_ outcome: AnswerOutcome) {
        guard let current = active else { return }
        active = nil
        current.continuation.yield(.ended(outcome, text: current.text))
        current.continuation.finish()
    }
}

private struct Timeout: Error {}

@MainActor
private func until(_ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < end {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout()
}

@MainActor
private func withReadLecture(_ body: (LibraryModel) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnswerProviderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .assignment, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "read"))
    try await body(library)
}

@MainActor @Test func bundledProviderHasAStableIDAKindAndTheRunningModel() {
    var endpoint: LocalAIEndpoint?
    let provider = BundledAnswerProvider(client: LlamaClient(transport: LoopbackTransport()), endpoint: { endpoint })
    #expect(provider.id == "bundled-local")
    #expect(provider.id == BundledAnswerProvider.providerID)
    #expect(provider.kind == .local)
    #expect(!provider.displayName.isEmpty)
    #expect(AnswerProviderKind.allCases.map(\.rawValue) == ["local", "externalLocal", "api", "subscription"])
    // No ready server: the provider can't answer.
    #expect(provider.prepare() == nil)
    endpoint = LocalAIEndpoint(port: 8080, apiKey: secret, modelID: "qwen.gguf")
    #expect(provider.prepare()?.origin == AnswerOrigin(providerID: "bundled-local", modelID: "qwen.gguf"))
    #expect(AnswerOrigin.legacy == AnswerOrigin(providerID: "bundled-local", modelID: nil))
}

@MainActor @Test func lectureQASendsThroughTheProviderAndSavesItsOrigin() async throws {
    try await withReadLecture { library throws in
        let provider = FakeProvider()
        let qa = LectureQA(library: library, provider: provider, draftInterval: .zero)
        qa.show(LectureQA.key(library: library))
        await qa.load()

        provider.isReady = false
        #expect(!qa.send("What is step one?"))
        #expect(qa.draft == nil)
        provider.isReady = true

        #expect(qa.send("What is step one?"))
        try await until { provider.requestID != nil }
        // The passage IDs of the lecture go to the provider in the system prompt.
        let messages = try #require(provider.asked.first)
        #expect(messages.first?.role == .system && messages.last == ChatMessage(role: .user, content: "What is step one?"))
        guard case .ready(let context) = await library.lectureContext(forLecture: "read") else { throw Timeout() }
        let system = try #require(messages.first?.content)
        let cited = try #require(context.passages.first { system.contains("[\($0.id)]") })
        provider.send("Write the goal [\(cited.id)].")
        try await until { qa.draft?.text == "Write the goal [\(cited.id)]." }
        provider.finish()
        await qa.waitForRequest()
        let turn = try #require(qa.conversation.turns.first)
        #expect(turn.status == .complete)
        #expect(turn.origin == AnswerOrigin(providerID: "test-provider", modelID: "test-model"))
        // The citation of the answer resolves to the same passage through the adapter.
        let sources = qa.citations(for: turn).sources
        #expect(sources.map(\.number) == [1] && sources.allSatisfy(\.isActionable))

        // A second turn with another model keeps the model of each turn.
        provider.modelID = "other-model"
        #expect(qa.send("And then?"))
        try await until { provider.requestID != nil }
        provider.finish()
        await qa.waitForRequest()
        let saved = try #require(try await library.lectureConversation(forLecture: "read"))
        #expect(saved.turns.map(\.origin.modelID) == ["test-model", "other-model"])
    }
}

@MainActor @Test func cancelGoesToTheProviderWithTheRequestID() async throws {
    try await withReadLecture { library throws in
        let provider = FakeProvider()
        let qa = LectureQA(library: library, provider: provider, draftInterval: .zero)
        qa.show(LectureQA.key(library: library))
        await qa.load()
        #expect(qa.send("What is step one?"))
        try await until { provider.requestID != nil }
        let id = try #require(provider.requestID)
        provider.send("Write")
        try await until { qa.draft?.text == "Write" }
        qa.cancel()
        await qa.waitForRequest()
        #expect(provider.cancelled == [id])
        #expect(qa.draft == nil)
        let turn = try #require(qa.conversation.turns.first)
        #expect(turn.status == .cancelled && turn.answer == "Write")
        #expect(turn.origin == AnswerOrigin(providerID: "test-provider", modelID: "test-model"))
    }
}

@Test func turnsSavedBeforeTheProviderMigrationLoadAsBundledLocal() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnswerProviderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(11)))
    #expect(try old.schemaVersion == 11)
    let course = Course(id: "c", title: "Garden", state: .published, sections: [
        CourseSection(id: "s", title: "Start", order: 0, state: .published,
                      lectures: [Lecture(id: "a", title: "a", type: .article, order: 0, state: .published)]),
    ])
    try old.saveCourse(course)
    // Version 11 rows have no provider or model columns.
    let database = try SQLiteDatabase(url: old.databaseURL)
    try database.execute("INSERT INTO qa_threads (course_id, lecture_id) VALUES ('c', 'a')")
    try database.execute("""
        INSERT INTO qa_messages (course_id, lecture_id, question, answer, status, source_revision, asked_at)
        VALUES ('c', 'a', 'Why?', 'Because.', 'complete', 'r', 0), ('c', 'a', 'How?', '', 'pending', 'r', 1)
        """)

    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == 12)
    #expect(try store.loadCourse(id: "c") == course)
    let legacy = try store.qaTurns(courseID: "c", lectureID: "a")
    #expect(legacy.map(\.question) == ["Why?", "How?"])
    #expect(legacy.map(\.answer) == ["Because.", ""])
    #expect(legacy.map(\.origin) == [.legacy, .legacy])
    try store.interruptPendingQATurns()
    #expect(try store.qaTurns(courseID: "c", lectureID: "a").map(\.status) == [.complete, .interrupted])

    let origin = AnswerOrigin(providerID: "bundled-local", modelID: "qwen.gguf")
    let new = try store.startQATurn(question: "What?", sourceRevision: "r", origin: origin, courseID: "c", lectureID: "a")
    #expect(new.origin == origin)
    try store.finishQATurn(id: new.id, status: .complete, answer: "This.")
    #expect(try store.qaTurns(courseID: "c", lectureID: "a").map(\.origin) == [.legacy, .legacy, origin])
}
