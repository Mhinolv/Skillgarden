import Foundation
import Testing
@testable import SkillgardenCore

// #153: the OpenAI Responses API with an API key. The fixtures copy the typed event stream of the Responses API.
// No test uses the network or a real key.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")
private let key = "sk-test-SECRET-KEY-123"
private let messages = [ChatMessage(role: .system, content: "Answer from the lecture. [t1] Plan the course."),
                        ChatMessage(role: .user, content: "Why?"), ChatMessage(role: .assistant, content: "Because."),
                        ChatMessage(role: .user, content: "What is a loop?")]

private func openAI(modelID: String = "gpt-5", answerTokens: Int? = nil, credentialReference: String? = "openai") -> ProviderProfile {
    ProviderProfile(id: "openai", kind: .api, name: "OpenAI API", vendor: "OpenAI", origin: "https://api.openai.com",
                    modelID: modelID, answerTokens: answerTokens, credentialReference: credentialReference)
}

private func event(_ type: String, _ fields: String = "") -> String {
    "event: \(type)\ndata: {\"type\":\"\(type)\",\"sequence_number\":1\(fields.isEmpty ? "" : ",")\(fields)}\n\n"
}

private func delta(_ text: String) -> String {
    event("response.output_text.delta", #""item_id":"msg_1","output_index":0,"content_index":0,"delta":"\#(text)""#)
}

/// The start of each response: created, in progress, then a message item with an empty text part.
private let head = event("response.created", #""response":{"id":"resp_1","object":"response","status":"in_progress","output":[]}"#)
    + event("response.in_progress", #""response":{"id":"resp_1","status":"in_progress"}"#)
    + event("response.output_item.added", #""output_index":0,"item":{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}"#)
    + event("response.content_part.added", #""item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}"#)

private let completedStream = head + delta("A loop") + delta(" repeats [t1].")
    + event("response.output_text.done", #""item_id":"msg_1","output_index":0,"content_index":0,"text":"A loop repeats [t1].""#)
    + event("response.completed", #""response":{"id":"resp_1","status":"completed","incomplete_details":null,"usage":{"output_tokens":5}}"#)

private func incompleteStream(_ reason: String) -> String {
    head + delta("A loop")
        + event("response.incomplete", #""response":{"id":"resp_1","status":"incomplete","incomplete_details":{"reason":"\#(reason)"}}"#)
}

private let refusalStream = head
    + event("response.refusal.delta", #""item_id":"msg_1","output_index":0,"content_index":0,"delta":"I can't help with that.""#)
    + event("response.refusal.done", #""item_id":"msg_1","output_index":0,"content_index":0,"refusal":"I can't help with that.""#)
    + event("response.completed", #""response":{"id":"resp_1","status":"completed"}"#)

private func collect(_ request: AnswerRequest) async -> [AnswerUpdate] {
    var updates: [AnswerUpdate] = []
    for await update in request.updates { updates.append(update) }
    return updates
}

/// Gives each request stream to the test, which then sends the events by hand.
private final class ScriptedTransport: LlamaTransport, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<LlamaTransportEvent, any Error>.Continuation

    private let lock = NSLock()
    private var ready: [Continuation] = []
    private var waiters: [CheckedContinuation<Continuation, Never>] = []
    private var sent: [URLRequest] = []
    private var ended = 0

    var requests: [URLRequest] { lock.withLock { sent } }
    var terminated: Int { lock.withLock { ended } }

    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<LlamaTransportEvent, any Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.ended += 1 } }
        let waiter: CheckedContinuation<Continuation, Never>? = lock.withLock {
            sent.append(request)
            if waiters.isEmpty { ready.append(continuation); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: continuation)
        return stream
    }

    func next() async -> Continuation {
        await withCheckedContinuation { waiter in
            let found: Continuation? = lock.withLock {
                if ready.isEmpty { waiters.append(waiter); return nil }
                return ready.removeFirst()
            }
            if let found { waiter.resume(returning: found) }
        }
    }
}

/// Sends `body` in pieces of `piece` bytes on `stream`, then ends it with `end`.
private func play(_ stream: ScriptedTransport.Continuation, status: Int = 200, _ body: String, piece: Int = 7,
                  end: (any Error)? = nil) {
    stream.yield(.response(status: status))
    let bytes = Array(body.utf8)
    for start in stride(from: 0, to: bytes.count, by: piece) {
        stream.yield(.data(Data(bytes[start..<min(start + piece, bytes.count)])))
    }
    stream.finish(throwing: end)
}

/// One answer of the OpenAI profile on the scripted transport.
@MainActor
private func answer(status: Int = 200, _ body: String = "", piece: Int = 7, end: (any Error)? = nil,
                    profile: ProviderProfile = openAI()) async throws -> (updates: [AnswerUpdate], request: URLRequest) {
    let transport = ScriptedTransport()
    let provider = OpenAIAnswerProvider(profile: profile, credentials: MemoryCredentialStore(secrets: ["openai": key]),
                                        transport: transport)
    let prepared = try #require(provider.prepare())
    #expect(prepared.origin == AnswerOrigin(providerID: "openai", modelID: profile.modelID))
    let request = prepared.ask(messages)
    play(await transport.next(), status: status, body, piece: piece, end: end)
    return (await collect(request), try #require(transport.requests.first))
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Request

@MainActor @Test func requestsGoToTheFixedResponsesEndpointWithInstructionsInputAndStoreFalse() async throws {
    let (updates, request) = try await answer(completedStream)
    #expect(updates.last == .ended(.finished, text: "A loop repeats [t1]."))
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(request.httpShouldHandleCookies == false)
    let body = try json(request)
    #expect(body["model"] as? String == "gpt-5")
    #expect(body["instructions"] as? String == "Answer from the lecture. [t1] Plan the course.")
    #expect(body["stream"] as? Bool == true)
    #expect(body["store"] as? Bool == false)
    #expect(body["max_output_tokens"] as? Int == 1024)
    let input = try #require(body["input"] as? [[String: String]])
    #expect(input == [["role": "user", "content": "Why?"], ["role": "assistant", "content": "Because."],
                      ["role": "user", "content": "What is a loop?"]])
    #expect(Set(body.keys) == ["model", "instructions", "input", "stream", "store", "max_output_tokens"])
    // The key is only in the header: never in the URL or the body.
    #expect(!(request.url?.absoluteString.contains(key) ?? true))
    #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self).contains(key))

    // The output limit of the profile, and the smallest limit that the API accepts.
    for (tokens, sent) in [(2048, 2048), (16, 16), (1, 16)] {
        let limited = try #require(OpenAIAnswerProvider.responsesRequest(messages, profile: openAI(answerTokens: tokens), key: key))
        #expect(try json(limited)["max_output_tokens"] as? Int == sent)
    }
    // No system message gives no instructions.
    let plain = try #require(OpenAIAnswerProvider.responsesRequest([messages[3]], profile: openAI(), key: " \(key) "))
    #expect(try json(plain)["instructions"] == nil)
    #expect(plain.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
}

@MainActor @Test func onlyTheOpenAIPresetWithAKeyAndAModelSends() async throws {
    #expect(OpenAIAnswerProvider.responsesRequest(messages, profile: openAI(), key: nil) == nil)
    #expect(OpenAIAnswerProvider.responsesRequest(messages, profile: openAI(), key: "  ") == nil)
    #expect(OpenAIAnswerProvider.responsesRequest(messages, profile: openAI(), key: "sk\r\nX-Other: 1") == nil)
    #expect(OpenAIAnswerProvider.responsesRequest(messages, profile: openAI(modelID: " "), key: key) == nil)
    // Another origin, vendor or kind never uses this adapter, so the key can't go to another host.
    for origin in ["https://api.openai.com.example.com", "http://api.openai.com", "https://example.com", "https://api.openai.com/"] {
        var moved = openAI()
        moved.origin = origin
        #expect(moved.apiService == nil, "\(origin)")
        #expect(OpenAIAnswerProvider.responsesRequest(messages, profile: moved, key: key) == nil, "\(origin)")
    }
    var other = openAI()
    other.vendor = "Anthropic"
    #expect(OpenAIAnswerProvider.responsesRequest(messages, profile: other, key: key) == nil)
    var local = openAI()
    local.kind = .externalLocal
    #expect(OpenAIAnswerProvider.responsesRequest(messages, profile: local, key: key) == nil)

    // No saved key, or a refused Keychain item: the provider can't answer and sends nothing.
    let transport = ScriptedTransport()
    #expect(OpenAIAnswerProvider(profile: openAI(credentialReference: nil), credentials: MemoryCredentialStore(secrets: ["openai": key]),
                                 transport: transport).prepare() == nil)
    #expect(OpenAIAnswerProvider(profile: openAI(), credentials: MemoryCredentialStore(), transport: transport).prepare() == nil)
    #expect(OpenAIAnswerProvider(profile: openAI(), credentials: MemoryCredentialStore(deniedAccounts: ["openai"]),
                                 transport: transport).prepare() == nil)
    #expect(transport.requests.isEmpty)
}

// MARK: - Stream and outcomes

@MainActor @Test func typedEventsStreamIncrementalAnswersAtEachCut() async throws {
    for piece in [1, 7, 4096] {
        let updates = try await answer(completedStream, piece: piece).updates
        #expect(updates.last == .ended(.finished, text: "A loop repeats [t1]."), "\(piece)")
        let deltas = updates.compactMap { if case .delta(let text) = $0 { text } else { nil } }
        #expect(deltas == ["A loop", "A loop repeats [t1]."], "\(piece)")
    }
    // CRLF line ends and data with no `event:` line give the same answer.
    let crlf = completedStream.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(try await answer(crlf).updates.last == .ended(.finished, text: "A loop repeats [t1]."))
    let dataOnly = completedStream.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.hasPrefix("event:") }.joined(separator: "\n")
    #expect(try await answer(dataOnly).updates.last == .ended(.finished, text: "A loop repeats [t1]."))
}

@MainActor @Test func terminalStatesMapToDistinctOutcomes() async throws {
    // Incomplete at the output limit keeps the partial answer.
    #expect(try await answer(incompleteStream("max_output_tokens")).updates.last == .ended(.incomplete, text: "A loop"))
    // A reasoning model can use all of the limit before it writes text.
    #expect(try await answer(head + event("response.incomplete",
                                          #""response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#))
        .updates == [.ended(.incomplete, text: "")])
    // A content filter or a refusal is a declined answer with no text.
    #expect(try await answer(incompleteStream("content_filter")).updates.last == .ended(.declined, text: ""))
    #expect(try await answer(refusalStream).updates == [.ended(.declined, text: "")])
    // A failed response or an error event: the fixed text, never the message of the service.
    let failed = AnswerUpdate.ended(.refused(reason: "OpenAI could not finish the answer. Try again."), text: "")
    #expect(try await answer(head + delta("Half") + event("response.failed",
        #""response":{"status":"failed","error":{"code":"server_error","message":"RAW-MESSAGE"}}"#)).updates.last == failed)
    #expect(try await answer(event("error", #""code":"rate_limit_exceeded","message":"RAW-MESSAGE","param":null"#)).updates
        == [failed])
    #expect(try await answer(head + event("response.cancelled", #""response":{"status":"cancelled"}"#)).updates
        == [.ended(.canceled, text: "")])
    // A completed response with no text, data that is not JSON, and a body with no terminal event.
    #expect(try await answer(head + event("response.completed", #""response":{"status":"completed"}"#)).updates
        == [.ended(.empty, text: "")])
    #expect(try await answer(head + "data: {not json\n\n").updates
        == [.ended(.refused(reason: "OpenAI sent data that Skillgarden can't read. Try again."), text: "")])
    #expect(try await answer(head + delta("Half")).updates.last
        == .ended(.refused(reason: "The connection to OpenAI stopped. Try again."), text: ""))
    #expect(try await answer(head + delta("Half"), end: URLError(.networkConnectionLost)).updates.last
        == .ended(.refused(reason: "The connection to OpenAI stopped. Try again."), text: ""))

    // Each outcome gives its own turn status and text.
    #expect(QATurnStatus(outcome: .incomplete) == .incomplete)
    #expect(QATurnStatus.incomplete.label == "Stopped at the output limit")
    #expect(QATurnStatus.incomplete.systemImage == "exclamationmark.triangle")
    #expect(QATurnStatus(outcome: .declined) == .declined)
    #expect(QATurnStatus.declined.label == "The model declined to answer.")
    #expect(QATurnStatus.declined.systemImage == "hand.raised")
    #expect(QATurnStatus(outcome: .canceled).label == "Cancelled")
    #expect(QATurnStatus(outcome: .refused(reason: "OpenAI sent an error (500).")).label == "No answer: OpenAI sent an error (500).")
    #expect(AnswerOutcome.incomplete.keepsText && !AnswerOutcome.declined.keepsText)
    for status in [QATurnStatus.incomplete, .declined, .cancelled, .failed(reason: "x")] {
        #expect(status.isRetryable)
        #expect(!status.opensSettings)
    }
}

@MainActor @Test func httpErrorsGiveActionableTextWithoutTheBodyOrTheKey() async throws {
    let rawBody = #"{"error":{"message":"Incorrect API key provided: sk-test-SECRET-KEY-123 RAW-BODY","type":"invalid_request_error"}}"#
    let cases = [
        (401, "OpenAI did not accept the API key. Check it in Settings."),
        (403, "This API key cannot use gpt-5."),
        (404, "This API key cannot use gpt-5."),
        (429, "OpenAI rate limit or quota reached. Try again later."),
        (307, "OpenAI sent an error (307)."),
        (400, "OpenAI sent an error (400)."),
        (500, "OpenAI sent an error (500)."),
    ]
    for (status, text) in cases {
        let updates = try await answer(status: status, rawBody).updates
        #expect(updates == [.ended(.refused(reason: text), text: "")], "\(status)")
        #expect(!text.contains(key) && !text.contains("RAW"))
        let turn = QATurnStatus(outcome: .refused(reason: text))
        // Only the refused key names Settings, so only it shows "Open Settings…".
        #expect(turn.opensSettings == (status == 401), "\(status)")
    }
    // No response at all.
    let transport = ScriptedTransport()
    let provider = OpenAIAnswerProvider(profile: openAI(), credentials: MemoryCredentialStore(secrets: ["openai": key]),
                                        transport: transport)
    let request = try #require(provider.prepare()).ask(messages)
    await transport.next().finish(throwing: URLError(.notConnectedToInternet))
    #expect(await collect(request) == [.ended(.refused(reason: "Skillgarden can't connect to OpenAI. Check the network."), text: "")])
}

@MainActor @Test func cancelStopsAtOnceAndLateEventsChangeNothing() async throws {
    let transport = ScriptedTransport()
    let provider = OpenAIAnswerProvider(profile: openAI(), credentials: MemoryCredentialStore(secrets: ["openai": key]),
                                        transport: transport)
    let request = try #require(provider.prepare()).ask(messages)
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    stream.yield(.data(Data((head + delta("A loop")).utf8)))
    var updates = request.updates.makeAsyncIterator()
    #expect(await updates.next() == .delta(text: "A loop"))
    provider.cancel(request.id)
    #expect(await updates.next() == .ended(.canceled, text: "A loop"))
    #expect(await updates.next() == nil)
    // Late text and a late terminal event go nowhere.
    stream.yield(.data(Data((delta(" repeats.") + event("response.completed", #""response":{"status":"completed"}"#)).utf8)))
    stream.finish()
    while transport.terminated == 0 { await Task.yield() }
    provider.cancel(request.id)
    #expect(transport.requests.count == 1)

    // A second question while one runs is busy.
    let first = try #require(provider.prepare()).ask(messages)
    let running = await transport.next()
    #expect(await collect(try #require(provider.prepare()).ask(messages)) == [.ended(.busy, text: "")])
    play(running, completedStream)
    #expect(await collect(first).last == .ended(.finished, text: "A loop repeats [t1]."))
}

// MARK: - Connection test

@MainActor @Test func openAIConnectionTestSendsOneShortSyntheticMessage() async throws {
    let transport = ScriptedTransport()
    let task = Task { await OpenAIAnswerProvider.testConnection(openAI(), key: key, transport: transport) }
    play(await transport.next(), incompleteStream("max_output_tokens"))
    // A response that stops at the limit still proves that the key and the model work.
    #expect(await task.value == .connected)
    let sent = try #require(transport.requests.first)
    let body = try json(sent)
    #expect(body["max_output_tokens"] as? Int == 16)
    #expect(body["instructions"] == nil)
    #expect(body["input"] as? [[String: String]] == [["role": "user", "content": "Reply with the word OK."]])

    for (status, text) in [(401, "OpenAI did not accept the API key. Check it in Settings."), (429, "OpenAI rate limit or quota reached. Try again later.")] {
        let failing = ScriptedTransport()
        let result = Task { await OpenAIAnswerProvider.testConnection(openAI(), key: key, transport: failing) }
        play(await failing.next(), status: status, "RAW")
        #expect(await result.value == .failed(reason: text))
    }
    #expect(await OpenAIAnswerProvider.testConnection(openAI(), key: nil, transport: transport) == .failed(reason: "Enter an API key."))
    #expect(await OpenAIAnswerProvider.testConnection(openAI(modelID: ""), key: key, transport: transport)
        == .failed(reason: "Enter the model ID."))
    #expect(transport.requests.count == 1)
}

// MARK: - Settings

@MainActor @Test func presetSheetValuesAndValidationMatchTheDesignNotes() async throws {
    #expect(APIService.allCases.map(\.menuTitle) == ["OpenAI API…", "Anthropic API…"])
    let preset = ProviderProfile.preset(.openAI)
    #expect(preset.kind == .api && preset.name == "OpenAI API" && preset.vendor == "OpenAI")
    #expect(preset.origin == "https://api.openai.com" && preset.host == "api.openai.com")
    #expect(preset.answerTokens == 1024 && preset.modelID.isEmpty)
    #expect(preset.apiService == .openAI)
    #expect(preset.modelProblem == "Enter the model ID.")
    #expect(!preset.isValid(hasSecret: true))
    var ready = preset
    ready.modelID = "gpt-5"
    #expect(ready.isValid(hasSecret: true))
    #expect(!ready.isValid(hasSecret: false))
    #expect(ready.title == "OpenAI API · gpt-5")
    #expect(ready.answerFooter == "Answers come from OpenAI and can be wrong.")
    ready.answerTokens = 15
    #expect(!ready.isValid(hasSecret: true))
    #expect(APIService.openAI.keyPrompt == "sk-…")
    #expect(APIService.openAI.modelPrompt == "Model ID, for example gpt-5")
    #expect(ProviderProfile.noKeyText == "Enter an API key.")
    // An empty Output limit field is 0.
    for (tokens, problem) in [(0, "Enter the output limit."), (15, "Enter 16 or more."), (1, "Enter 16 or more."),
                              (16, nil), (1024, nil)] as [(Int, String?)] {
        ready.answerTokens = tokens
        #expect(ready.answerTokensProblem == problem)
    }

    // The app routes the API kind to this adapter and its test.
    var keys: [String?] = []
    let credentials = MemoryCredentialStore()
    let providers = ProviderSettings(store: nil, credentials: credentials, adapterKinds: [.externalLocal, .api],
                                     makeProvider: { $0.apiService == .openAI ? OpenAIAnswerProvider(profile: $0, credentials: $1) : nil },
                                     testConnection: { _, key in keys.append(key); return .connected })
    #expect(providers.canTest(.api))
    var profile = preset
    profile.modelID = "gpt-5"
    #expect(await providers.test(profile, secret: " \(key) ") == .connected)
    try providers.save(profile, secret: key)
    #expect(try credentials.secret(account: profile.id) == key)
    // The saved file holds no secret.
    let saved = try #require(providers.profiles.first)
    #expect(saved.credentialReference == profile.id)
    #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains(key))
    #expect(await providers.test(saved, secret: nil) == .connected)
    #expect(keys == [key, key])
    providers.select(saved.id)
    #expect(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: saved)) is OpenAIAnswerProvider)
}

@MainActor @Test func openAIProviderFilesSavedBeforeThisChangeStillLoad() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "OpenAIProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    // A #151 file: an OpenAI API profile with no output limit, its consent and the choice.
    try Data("""
    {"version": 1, "selectedID": "openai",
     "profiles": [{"id": "openai", "kind": "api", "name": "OpenAI API", "vendor": "OpenAI",
                   "origin": "https://api.openai.com", "modelID": "gpt-5", "credentialReference": "openai"}],
     "consents": [{"courseID": "c", "allowedAt": 0,
                   "destination": {"profileID": "openai", "kind": "api", "host": "api.openai.com", "modelID": "gpt-5"}}]}
    """.utf8).write(to: store.fileURL)
    let providers = ProviderSettings(store: store, credentials: MemoryCredentialStore(secrets: ["openai": key]),
                                     adapterKinds: [.api],
                                     makeProvider: { OpenAIAnswerProvider(profile: $0, credentials: $1, transport: ScriptedTransport()) })
    let profile = try #require(providers.selected)
    #expect(profile.apiService == .openAI)
    #expect(profile.answerTokens == nil)
    #expect(providers.hasConsent(courseID: "c", destination: profile.destination))
    #expect(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: profile)).prepare() != nil)
    // A profile with no output limit sends the default.
    let request = try #require(OpenAIAnswerProvider.responsesRequest(messages, profile: profile, key: key))
    #expect(try json(request)["max_output_tokens"] as? Int == 1024)
}

// MARK: - Store

@Test func incompleteAndDeclinedTurnsSaveAndOldStoresStillLoad() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "OpenAIProviderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    // A version 12 store with a failed turn and a complete turn.
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(12)))
    #expect(try old.schemaVersion == 12)
    let course = Course(id: "c", title: "Garden", state: .published, sections: [
        CourseSection(id: "s", title: "Start", order: 0, state: .published,
                      lectures: [Lecture(id: "a", title: "a", type: .article, order: 0, state: .published)]),
    ])
    try old.saveCourse(course)
    let database = try SQLiteDatabase(url: old.databaseURL)
    try database.execute("INSERT INTO qa_threads (course_id, lecture_id) VALUES ('c', 'a')")
    try database.execute("""
        INSERT INTO qa_messages (course_id, lecture_id, question, answer, status, failure_reason, source_revision, asked_at)
        VALUES ('c', 'a', 'Why?', 'Because.', 'complete', NULL, 'r', 0), ('c', 'a', 'How?', '', 'failed', 'Busy.', 'r', 1)
        """)

    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == 13)
    #expect(try store.qaTurns(courseID: "c", lectureID: "a").map(\.status) == [.complete, .failed(reason: "Busy.")])
    let origin = AnswerOrigin(providerID: "openai", modelID: "gpt-5")
    for (status, answer) in [(QATurnStatus.incomplete, "A loop"), (.declined, ""), (.failed(reason: "OpenAI sent an error (500)."), "")] {
        let turn = try store.startQATurn(question: "Q", sourceRevision: "r", origin: origin, courseID: "c", lectureID: "a")
        #expect(try store.finishQATurn(id: turn.id, status: status, answer: answer))
    }
    let turns = try store.qaTurns(courseID: "c", lectureID: "a")
    #expect(turns.map(\.status) == [.complete, .failed(reason: "Busy."), .incomplete, .declined,
                                     .failed(reason: "OpenAI sent an error (500).")])
    #expect(turns.map(\.answer) == ["Because.", "", "A loop", "", ""])
}

// MARK: - Q&A, consent and history

@MainActor @Test func consentedQuestionsSendAndOutcomesSaveWithoutCorruptingHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "OpenAIProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaEmpty, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))

    let transport = ScriptedTransport()
    let providers = ProviderSettings(store: ProviderSettingsStore(directory: root), credentials: MemoryCredentialStore(),
                                     adapterKinds: [.api],
                                     makeProvider: { OpenAIAnswerProvider(profile: $0, credentials: $1, transport: transport) })
    try providers.save(openAI(credentialReference: nil), secret: key)
    providers.select("openai")
    let qa = LectureQA(library: library, provider: UnavailableAnswerProvider(profile: openAI()), providers: providers,
                       draftInterval: .zero)
    qa.show(LectureQA.key(library: library))
    await qa.load()
    #expect(qa.provider is OpenAIAnswerProvider)

    // No request before the course consent.
    #expect(!qa.send("What is the goal of this course?"))
    let consent = try #require(qa.consentRequest)
    #expect(consent.title == "Send this question to OpenAI?")
    #expect(consent.cloudNote == nil)
    #expect(transport.requests.isEmpty)
    #expect(qa.allowAndSend())

    // The request has the lecture passages in `instructions` and the question in `input`.
    play(await transport.next(), incompleteStream("max_output_tokens"))
    await qa.waitForRequest()
    let body = try json(try #require(transport.requests.first))
    #expect((body["instructions"] as? String)?.contains("t0") == true)
    #expect((body["input"] as? [[String: String]])?.last == ["role": "user", "content": "What is the goal of this course?"])
    let incomplete = try #require(qa.conversation.turns.last)
    #expect(incomplete.status == .incomplete && incomplete.answer == "A loop")
    #expect(incomplete.origin == AnswerOrigin(providerID: "openai", modelID: "gpt-5"))
    #expect(qa.conversation.canRetry(incomplete))

    // A refused key: the turn reason names Settings.
    #expect(qa.retry(incomplete))
    play(await transport.next(), status: 401, "RAW")
    await qa.waitForRequest()
    let refused = try #require(qa.conversation.turns.last)
    #expect(refused.status == .failed(reason: "OpenAI did not accept the API key. Check it in Settings."))
    #expect(refused.status.opensSettings)

    // Cancel keeps the partial answer. Late text and a late completion do not change the saved turn.
    #expect(qa.send("How does the course start?"))
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    stream.yield(.data(Data((head + delta("It starts")).utf8)))
    while qa.draft?.text != "It starts" { await Task.yield() }
    qa.cancel()
    stream.yield(.data(Data((delta(" late.") + event("response.completed", #""response":{"status":"completed"}"#)).utf8)))
    stream.finish()
    await qa.waitForRequest()
    #expect(qa.draft == nil)
    let cancelled = try #require(qa.conversation.turns.last)
    #expect(cancelled.status == .cancelled && cancelled.answer == "It starts")
    await library.waitForWrites()
    let reloaded = try #require(try await library.lectureConversation(forLecture: "welcome"))
    #expect(reloaded.turns.map(\.status) == [.incomplete, .failed(reason: "OpenAI did not accept the API key. Check it in Settings."),
                                             .cancelled])
    #expect(reloaded.turns.last?.answer == "It starts")
    // Only complete turns go into a later prompt, so a partial answer never reads as a full one.
    let context = try #require({ if case .ready(let value) = $0 { value } else { nil } }(await library.lectureContext(forLecture: "welcome")))
    let prompt = try #require(reloaded.prompt(context: context, question: "And then?"))
    #expect(prompt.messages.filter { $0.role == .assistant }.isEmpty)
}

@Test func docsDescribeTheOpenAIPath() throws {
    let doc = try String(contentsOf: repo.appending(path: "docs/local-ai.md"), encoding: .utf8)
    #expect(doc.contains("OpenAI API (#153)"))
    #expect(doc.contains("store: false"))
    #expect(doc.contains("https://api.openai.com/v1/responses"))
}
