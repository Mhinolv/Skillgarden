import Foundation
import Testing
@testable import SkillgardenCore

// #128: the lecture Q&A tab. These tests cover the panel states, the Transcript and Q&A slot, the draft throttle,
// and the panel model with the real store and client on a scripted transport. No test needs a model or a server.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private let secret = String(repeating: "0123456789abcdef", count: 4)
private let endpoint = LocalAIEndpoint(port: 8080, apiKey: secret)

/// Gives each request stream to the test, which then sends the events by hand.
private final class ScriptedTransport: LlamaTransport, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<LlamaTransportEvent, any Error>.Continuation

    private let lock = NSLock()
    private var streams: [Continuation] = []

    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<LlamaTransportEvent, any Error>.makeStream()
        lock.withLock { streams.append(continuation) }
        return stream
    }

    var requestCount: Int { lock.withLock { streams.count } }

    /// The stream of request `index`, after the client sent it.
    @MainActor
    func stream(_ index: Int) async throws -> Continuation {
        try await until { self.requestCount > index }
        return lock.withLock { streams[index] }
    }
}

/// One `data:` event of a chat chunk with `content`.
private func chunk(_ content: String, finish: String? = nil) -> Data {
    let text = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
    let reason = finish.map { "\"\($0)\"" } ?? "null"
    return Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\(text)},\"finish_reason\":\(reason)}]}\n\n".utf8)
}

private struct Timeout: Error {}

/// Waits until `condition` is true, for 5 seconds at most.
@MainActor @discardableResult
private func until(_ condition: () -> Bool) async throws -> Bool {
    let end = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < end {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout()
}

/// A library with the published sample course and its practice section, so quiz and assignment lectures show too.
@MainActor
private func withLibrary(_ body: (LibraryModel) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LectureQATests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .assignment, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    try await body(library)
}

@MainActor
private func open(_ library: LibraryModel, _ lectureID: String, section: String = "plan") {
    library.selectDestination(.lecture(sectionID: section, lectureID: lectureID))
}

@MainActor
private final class Announcements {
    var texts: [String] = []
}

@MainActor
private func model(_ library: LibraryModel, transport: ScriptedTransport, interval: Duration = .zero,
                   endpoint: LocalAIEndpoint? = endpoint, announcements: Announcements = Announcements()) -> LectureQA {
    LectureQA(library: library, client: LlamaClient(transport: transport), endpoint: { endpoint }, draftInterval: interval,
              announce: { announcements.texts.append($0) })
}

// MARK: States

@Test func panelStatesFollowTheLectureTextThenTheService() {
    let ready = LectureQA.Content.ready
    #expect(LectureQAState(status: .off, content: ready) == .off)
    #expect(LectureQAState(status: .noModel, content: ready) == .noModel)
    #expect(LectureQAState(status: .starting, content: ready) == .starting)
    #expect(LectureQAState(status: .stopping, content: ready) == .stopping)
    #expect(LectureQAState(status: .failed(.serverStopped(exitCode: 9)), content: ready)
        == .error(reason: "The server stopped. Exit code 9."))
    #expect(LectureQAState(status: .ready(version: "b1"), content: ready) == .ready)
    #expect(LectureQAState(status: .ready(version: "b1"), content: .loading) == .loading)
    // A lecture without text shows its message in every service state.
    for status in [LocalAIStatus.off, .noModel, .starting, .stopping, .failed(.noFreePort), .ready(version: "b1")] {
        #expect(LectureQAState(status: status, content: .unavailable("No text")) == .unavailable(message: "No text"))
    }
    let states: [LectureQAState] = [.loading, .unavailable(message: "x"), .off, .noModel, .starting, .stopping, .error(reason: nil), .ready]
    #expect(states.filter(\.canSend) == [.ready])
}

// #160: saved turns stay in every service state. Only "Send" needs a ready model.
@Test func savedTurnsShowInEveryServiceStateWithAStatusRow() {
    let service: [LectureQAState] = [.off, .noModel, .starting, .stopping, .error(reason: "x")]
    for state in service {
        #expect(state.showsTurns(hasHistory: true), "\(state)")
        #expect(state.showsStatusRow(hasHistory: true), "\(state)")
        // No history keeps the #128 full state view.
        #expect(!state.showsTurns(hasHistory: false) && !state.showsStatusRow(hasHistory: false), "\(state)")
        #expect(!state.canSend)
    }
    #expect(LectureQAState.ready.showsTurns(hasHistory: true) && !LectureQAState.ready.showsStatusRow(hasHistory: true))
    #expect(!LectureQAState.ready.showsTurns(hasHistory: false))
    // Loading and "No captions" do not change.
    for state in [LectureQAState.loading, .unavailable(message: "No text")] {
        #expect(!state.showsTurns(hasHistory: true) && !state.showsStatusRow(hasHistory: true))
    }
}

@MainActor @Test func turnsAndSourcesStayAndClearHistoryWorksWithLocalAIOff() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LectureQATests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaCitations, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    open(library, "welcome")
    try await SnapshotPlan.seedQATurns(for: .qaCitations, library: library)

    // No endpoint: local AI is off.
    let qa = model(library, transport: ScriptedTransport(), endpoint: nil)
    qa.show(LectureQA.key(library: library))
    await qa.load()
    let state = LectureQAState(status: .off, content: qa.content)
    #expect(state == .off)
    #expect(qa.hasHistory)
    #expect(state.showsTurns(hasHistory: qa.hasHistory))
    let turn = try #require(qa.conversation.turns.first)
    #expect(qa.citations(for: turn).sources.count == 3)
    #expect(!qa.send("Another question?"))

    qa.clearHistory()
    #expect(qa.conversation.turns.isEmpty && !qa.hasHistory)
    await library.waitForWrites()
    #expect(try await library.lectureConversation(forLecture: "welcome")?.turns.isEmpty == true)
    #expect(!state.showsTurns(hasHistory: qa.hasHistory))
}

@Test func transcriptAndQAShareOneSlotAndTheSavedChoiceStays() {
    #expect(LecturePanelSlot.showsTranscript(saved: true, showsQA: false))
    #expect(!LecturePanelSlot.showsTranscript(saved: true, showsQA: true))
    #expect(!LecturePanelSlot.showsTranscript(saved: false, showsQA: false))
    // Q&A on hides the transcript but the saved choice stays on, so Q&A off shows it again.
    // The Transcript pill on closes Q&A. The pill off keeps Q&A as it is.
    #expect(LecturePanelSlot.setTranscript(true, showsQA: true) == (saved: true, showsQA: false))
    #expect(LecturePanelSlot.setTranscript(false, showsQA: false) == (saved: false, showsQA: false))
    #expect(LecturePanelSlot.setTranscript(false, showsQA: true) == (saved: false, showsQA: true))
}

@Test func draftThrottleAllowsTenChangesASecond() {
    var throttle = DraftThrottle(interval: .milliseconds(100))
    let start = ContinuousClock.now
    #expect(throttle.delay(at: start) == nil)
    throttle.published(at: start)
    #expect(throttle.delay(at: start + .milliseconds(30)) == .milliseconds(70))
    #expect(throttle.delay(at: start + .milliseconds(99)) == .milliseconds(1))
    #expect(throttle.delay(at: start + .milliseconds(100)) == nil)
    #expect(throttle.delay(at: start + .seconds(5)) == nil)
    #expect(DraftThrottle(interval: .zero).delay(at: start) == nil)
}

// MARK: Panel model

@MainActor @Test func onlyVideoAndArticleLecturesGetTheTab() async throws {
    try await withLibrary { library throws in
        #expect(LectureQA.key(library: library) == nil)
        open(library, "welcome")
        #expect(LectureQA.key(library: library) == LectureQA.Key(courseID: "sample-course", lectureID: "welcome"))
        open(library, "read")
        #expect(LectureQA.key(library: library)?.lectureID == "read")
        open(library, "check", section: "practice")
        #expect(library.selectedLecture?.type == .quiz)
        #expect(LectureQA.key(library: library) == nil)
        open(library, "apply", section: "practice")
        #expect(library.selectedLecture?.type == .assignment)
        #expect(LectureQA.key(library: library) == nil)
        library.selectDestination(.overview)
        #expect(LectureQA.key(library: library) == nil)
    }
}

@MainActor @Test func answerStreamsIntoADraftThenTheSavedThread() async throws {
    try await withLibrary { library throws in
        open(library, "read")
        let transport = ScriptedTransport()
        let announcements = Announcements()
        let qa = model(library, transport: transport, announcements: announcements)
        #expect(!qa.send("Too early"))
        qa.show(LectureQA.key(library: library))
        await qa.load()
        #expect(qa.content == .ready)
        #expect(qa.conversation.turns.isEmpty)
        #expect(!qa.send("   "))

        #expect(qa.send("  What is step one? "))
        #expect(qa.draft?.question == "What is step one?" && qa.draft?.text == "")
        // One request at a time.
        #expect(!qa.send("Another"))
        let stream = try await transport.stream(0)
        stream.yield(.response(status: 200))
        stream.yield(.data(chunk("Write ")))
        try await until { qa.draft?.text == "Write " }
        stream.yield(.data(chunk("the goal.", finish: "stop")))
        stream.finish()
        await qa.waitForRequest()
        #expect(qa.draft == nil)
        #expect(qa.conversation.turns.map(\.question) == ["What is step one?"])
        #expect(qa.conversation.turns.map(\.answer) == ["Write the goal."])
        #expect(qa.conversation.turns.map(\.status) == [.complete])
        #expect(announcements.texts == ["Answer ready"])

        // The thread is saved for the lecture.
        #expect(try await library.lectureConversation(forLecture: "read")?.turns.map(\.status) == [.complete])
        #expect(transport.requestCount == 1)
    }
}

@MainActor @Test func cancelKeepsThePartialAnswerAndRetryAsksAgain() async throws {
    try await withLibrary { library throws in
        open(library, "read")
        let transport = ScriptedTransport()
        let announcements = Announcements()
        let qa = model(library, transport: transport, announcements: announcements)
        qa.show(LectureQA.key(library: library))
        await qa.load()
        #expect(qa.send("What is step one?"))
        let stream = try await transport.stream(0)
        stream.yield(.response(status: 200))
        stream.yield(.data(chunk("Write")))
        try await until { qa.draft?.text == "Write" }
        qa.cancel()
        await qa.waitForRequest()
        #expect(qa.draft == nil)
        let turn = try #require(qa.conversation.turns.first)
        #expect(turn.status == .cancelled && turn.answer == "Write")
        #expect(turn.status.label == "Cancelled")
        #expect(announcements.texts.isEmpty)

        #expect(qa.retry(turn))
        let second = try await transport.stream(1)
        second.yield(.response(status: 500))
        second.finish()
        await qa.waitForRequest()
        #expect(qa.conversation.turns.map(\.question) == ["What is step one?", "What is step one?"])
        #expect(qa.conversation.turns.last?.status == .failed(reason: "Local AI returned an error (500). Try again."))
        // A complete turn has no Retry.
        #expect(!qa.retry(QATurn(id: 99, question: "Q", answer: "A", status: .complete,
                                 sourceRevision: turn.sourceRevision, askedAt: turn.askedAt)))
    }
}

@MainActor @Test func lectureChangeCancelsTheRequestAndKeepsTheThreadsApart() async throws {
    try await withLibrary { library throws in
        open(library, "read")
        let transport = ScriptedTransport()
        let announcements = Announcements()
        let qa = model(library, transport: transport, announcements: announcements)
        qa.show(LectureQA.key(library: library))
        await qa.load()
        #expect(qa.send("What is step one?"))
        let stream = try await transport.stream(0)
        stream.yield(.response(status: 200))
        stream.yield(.data(chunk("Write")))
        try await until { qa.draft?.text == "Write" }

        open(library, "welcome")
        qa.show(LectureQA.key(library: library))
        #expect(qa.draft == nil)
        #expect(qa.content == .loading)
        // Late events of the old request change nothing.
        stream.yield(.data(chunk(" the goal.", finish: "stop")))
        stream.finish()
        await qa.waitForRequest()
        await qa.load()
        #expect(qa.key?.lectureID == "welcome")
        #expect(qa.content == .ready)
        #expect(qa.draft == nil)
        #expect(qa.conversation.turns.isEmpty)
        #expect(announcements.texts.isEmpty)

        // The old turn is saved for its own lecture, cancelled with the partial answer.
        let read = try #require(try await library.lectureConversation(forLecture: "read"))
        #expect(read.turns.map(\.status) == [.cancelled])
        #expect(read.turns.map(\.answer) == ["Write"])
        #expect(try await library.lectureConversation(forLecture: "welcome")?.turns == [])
    }
}

@MainActor @Test func clearHistoryCancelsTheRequestAndEmptiesThisLectureOnly() async throws {
    try await withLibrary { library throws in
        let transport = ScriptedTransport()
        let qa = model(library, transport: transport)
        for (index, lectureID) in ["welcome", "read"].enumerated() {
            open(library, lectureID)
            qa.show(LectureQA.key(library: library))
            await qa.load()
            #expect(qa.send("What is the course about?"))
            let stream = try await transport.stream(index)
            stream.yield(.response(status: 200))
            stream.yield(.data(chunk("Planning.", finish: "stop")))
            stream.finish()
            await qa.waitForRequest()
            #expect(qa.conversation.turns.count == 1)
        }
        #expect(qa.send("And then?"))
        let stream = try await transport.stream(2)
        stream.yield(.response(status: 200))
        stream.yield(.data(chunk("Write")))
        try await until { qa.draft?.text == "Write" }
        qa.clearHistory()
        #expect(qa.draft == nil)
        #expect(qa.conversation.turns.isEmpty)
        await qa.waitForRequest()
        #expect(try await library.lectureConversation(forLecture: "read")?.turns == [])
        #expect(try await library.lectureConversation(forLecture: "welcome")?.turns.count == 1)
        #expect(qa.conversation.turns.isEmpty)
    }
}

@MainActor @Test func draftChangesAreThrottled() async throws {
    try await withLibrary { library throws in
        open(library, "read")
        let transport = ScriptedTransport()
        let qa = model(library, transport: transport, interval: .seconds(60))
        qa.show(LectureQA.key(library: library))
        await qa.load()
        #expect(qa.send("What is step one?"))
        let stream = try await transport.stream(0)
        stream.yield(.response(status: 200))
        stream.yield(.data(chunk("W")))
        try await until { qa.draft?.text == "W" }
        for letter in "rite the goal" { stream.yield(.data(chunk(String(letter)))) }
        try await Task.sleep(for: .milliseconds(100))
        // The first delta shows at once. The next ones wait for the interval.
        #expect(qa.draft?.text == "W")
        stream.yield(.data(chunk(".", finish: "stop")))
        stream.finish()
        await qa.waitForRequest()
        #expect(qa.draft == nil)
        #expect(qa.conversation.turns.map(\.answer) == ["Write the goal."])
    }
}

@MainActor @Test func noServerOrNoLectureTextSendsNothing() async throws {
    try await withLibrary { library throws in
        open(library, "read")
        let transport = ScriptedTransport()
        let qa = model(library, transport: transport, endpoint: nil)
        qa.show(LectureQA.key(library: library))
        await qa.load()
        #expect(qa.content == .ready)
        #expect(!qa.send("What is step one?"))
        #expect(qa.draft == nil)
        #expect(transport.requestCount == 0)
        #expect(try await library.lectureConversation(forLecture: "read")?.turns == [])
    }
}

@MainActor @Test func videoWithoutCaptionsShowsTheNoTranscriptMessage() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "LectureQANoCaptions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appending(path: "library")
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaNoCaptions, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    open(library, "welcome")
    let qa = model(library, transport: ScriptedTransport())
    qa.show(LectureQA.key(library: library))
    await qa.load()
    #expect(qa.content == .unavailable(LectureQA.noTextMessage))
    #expect(LectureQAState(status: .ready(version: "b1"), content: qa.content)
        == .unavailable(message: "This lecture has no transcript, so Q&A is not available."))
    #expect(!qa.send("What is step one?"))
}
