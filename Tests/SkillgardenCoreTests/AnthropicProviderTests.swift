import Foundation
import Testing
@testable import SkillgardenCore

// #154: the Anthropic Messages API with an API key. The fixtures copy the Messages stream form.
// No test needs a key, a network or Anthropic.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/sample-course")
private let question = [ChatMessage(role: .user, content: "What is a loop?")]
private let apiKey = "sk-ant-api03-test-key"

private func anthropic(modelID: String = "claude-sonnet-5-5", answerTokens: Int? = nil,
                       origin: String = "https://api.anthropic.com") -> ProviderProfile {
    ProviderProfile(id: "claude", kind: .api, name: "Anthropic API", vendor: "Anthropic", origin: origin, modelID: modelID,
                    answerTokens: answerTokens, credentialReference: "claude")
}

/// One SSE event with its `event:` line, as the Messages API sends it.
private func event(_ type: String, _ json: String) -> String { "event: \(type)\ndata: \(json)\n\n" }

private func textDelta(_ text: String) -> String {
    event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#)
}

private func stop(_ reason: String) -> String {
    event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)","stop_sequence":null},"usage":{"output_tokens":9}}"#)
        + event("message_stop", #"{"type":"message_stop"}"#)
}

private let start = event("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5-5","stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}"#)
    + event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
    + event("ping", #"{"type": "ping"}"#)

/// A full answer: start, a ping, two text deltas with a ping between them, the block end, then `end_turn`.
private let answerStream = start + textDelta("A loop") + event("ping", #"{"type": "ping"}"#) + textDelta(" repeats [t1].")
    + event("content_block_stop", #"{"type":"content_block_stop","index":0}"#) + stop("end_turn")

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

/// Sends `status` and `body` in pieces of `piece` bytes on the next request of `transport`, then `end`.
private func reply(_ transport: ScriptedTransport, status: Int = 200, _ body: String, piece: Int = 7,
                   end: (any Error)? = nil) async {
    let stream = await transport.next()
    stream.yield(.response(status: status))
    let bytes = Array(body.utf8)
    for start in stride(from: 0, to: bytes.count, by: piece) {
        stream.yield(.data(Data(bytes[start..<min(start + piece, bytes.count)])))
    }
    stream.finish(throwing: end)
}

/// One answer of `profile` on the scripted transport with `messages`.
@MainActor
private func answer(_ body: String = "", profile: ProviderProfile = anthropic(), status: Int = 200, piece: Int = 7,
                    messages: [ChatMessage] = question, end: (any Error)? = nil)
    async throws -> (updates: [AnswerUpdate], request: URLRequest) {
    let transport = ScriptedTransport()
    let provider = AnthropicAnswerProvider(profile: profile, credentials: MemoryCredentialStore(secrets: ["claude": apiKey]),
                                           transport: transport)
    let prepared = try #require(provider.prepare())
    #expect(prepared.origin == AnswerOrigin(providerID: profile.id, modelID: profile.modelID))
    let request = prepared.ask(messages)
    await reply(transport, status: status, body, piece: piece, end: end)
    return (await collect(request), try #require(transport.requests.first))
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Request

@MainActor @Test func requestsGoToTheFixedHostWithTheVersionHeaderAndMaxTokens() async throws {
    let messages = [ChatMessage(role: .system, content: "Answer from the lecture."),
                    ChatMessage(role: .user, content: "Why?"), ChatMessage(role: .assistant, content: "Because [t1]."),
                    ChatMessage(role: .user, content: "What is a loop?")]
    let (_, request) = try await answer(answerStream, messages: messages)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == apiKey)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(!request.httpShouldHandleCookies)
    let body = try json(request)
    #expect(body["model"] as? String == "claude-sonnet-5-5")
    #expect(body["stream"] as? Bool == true)
    // A profile with no limit uses the default of 1024.
    #expect(body["max_tokens"] as? Int == 1024)
    // The system text is at the top level. Only user and assistant turns are in `messages`.
    #expect(body["system"] as? String == "Answer from the lecture.")
    #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "Why?"],
                                                          ["role": "assistant", "content": "Because [t1]."],
                                                          ["role": "user", "content": "What is a loop?"]])
    #expect(Set(body.keys) == ["model", "max_tokens", "system", "messages", "stream"])

    // The output limit of the profile goes into `max_tokens`. No system message gives no `system` key.
    let (_, limited) = try await answer(answerStream, profile: anthropic(answerTokens: 2048))
    #expect(try json(limited)["max_tokens"] as? Int == 2048)
    #expect(try json(limited)["system"] == nil)
}

@MainActor @Test func theKeyComesFromTheKeychainOnEachQuestionAndBadProfilesSendNothing() async throws {
    let transport = ScriptedTransport()
    let credentials = MemoryCredentialStore(secrets: ["claude": "sk-ant-1"])
    let provider = AnthropicAnswerProvider(profile: anthropic(), credentials: credentials, transport: transport)
    let first = try #require(provider.prepare()).ask(question)
    await reply(transport, answerStream)
    _ = await collect(first)
    try credentials.save("sk-ant-2", account: "claude")
    let second = try #require(provider.prepare()).ask(question)
    await reply(transport, answerStream)
    _ = await collect(second)
    #expect(transport.requests.map { $0.value(forHTTPHeaderField: "x-api-key") } == ["sk-ant-1", "sk-ant-2"])

    // No key, a refused Keychain item, another host, no model or a key that a header can't hold: nothing sends.
    var noKey = anthropic()
    noKey.credentialReference = nil
    let refused = [
        AnthropicAnswerProvider(profile: noKey, credentials: credentials, transport: transport),
        AnthropicAnswerProvider(profile: anthropic(), credentials: MemoryCredentialStore(deniedAccounts: ["claude"]), transport: transport),
        AnthropicAnswerProvider(profile: anthropic(origin: "https://api.example.com"), credentials: credentials, transport: transport),
        AnthropicAnswerProvider(profile: anthropic(origin: "http://api.anthropic.com"), credentials: credentials, transport: transport),
        AnthropicAnswerProvider(profile: anthropic(modelID: " "), credentials: credentials, transport: transport),
        AnthropicAnswerProvider(profile: anthropic(answerTokens: 0), credentials: credentials, transport: transport),
        AnthropicAnswerProvider(profile: anthropic(), credentials: MemoryCredentialStore(secrets: ["claude": "sk\r\nX-Other: 1"]),
                                transport: transport),
    ]
    for provider in refused { #expect(provider.prepare() == nil) }
    #expect(transport.requests.count == 2)
    #expect(AnthropicAnswerProvider.messagesRequest(question, profile: anthropic(), key: "") == nil)
    var local = anthropic()
    local.kind = .externalLocal
    #expect(AnthropicAnswerProvider.messagesRequest(question, profile: local, key: apiKey) == nil)
}

// MARK: - Stream events

@MainActor @Test func pingTextAndStopEventsGiveOneAccumulatedAnswer() async throws {
    // A cut at each byte, every 7 bytes and in one piece gives the same answer. Pings change nothing.
    for piece in [1, 7, 4096] {
        let (updates, _) = try await answer(answerStream, piece: piece)
        #expect(updates == [.delta(text: "A loop"), .delta(text: "A loop repeats [t1]."),
                            .ended(.finished, text: "A loop repeats [t1].")], "piece \(piece)")
    }
    // Thinking blocks, non-text deltas and unknown events are skipped. CRLF line ends also work.
    let thinking = event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
        + event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm."}}"#)
        + event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"x"}}"#)
        + event("future_event", #"{"type":"future_event","data":1}"#)
        + event("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#)
    let mixed = (start + thinking + textDelta("Yes.") + stop("end_turn")).replacingOccurrences(of: "\n", with: "\r\n")
    #expect(try await answer(mixed).updates == [.delta(text: "Yes."), .ended(.finished, text: "Yes.")])
    // `message_stop` with no text is empty.
    #expect(try await answer(start + stop("end_turn")).updates == [.ended(.empty, text: "")])
    // Data that is not JSON is malformed. The partial answer stays.
    #expect(try await answer(start + textDelta("Half") + "data: {not json\n\n").updates
        == [.delta(text: "Half"), .ended(.malformed, text: "Half")])
    // A body that ends with no `message_stop` keeps the partial answer as a lost connection.
    #expect(try await answer(start + textDelta("Half")).updates == [.delta(text: "Half"), .ended(.disconnected, text: "Half")])
    #expect(try await answer(start + textDelta("Half"), end: URLError(.networkConnectionLost)).updates
        == [.delta(text: "Half"), .ended(.disconnected, text: "Half")])
}

@MainActor @Test func theOutputLimitKeepsThePartialAnswerAndARefusalShowsNone() async throws {
    let limited = try await answer(start + textDelta("A loop repeats") + stop("max_tokens")).updates
    #expect(limited == [.delta(text: "A loop repeats"), .ended(.incomplete, text: "A loop repeats")])
    let window = try await answer(start + textDelta("A loop") + stop("model_context_window_exceeded")).updates
    #expect(window.last == .ended(.incomplete, text: "A loop"))
    let refusal = try await answer(start + textDelta("I can") + stop("refusal")).updates
    #expect(refusal == [.delta(text: "I can"), .ended(.declined, text: "")])

    #expect(AnswerOutcome.incomplete.keepsText && !AnswerOutcome.declined.keepsText)
    #expect(QATurnStatus(outcome: .incomplete) == .incomplete)
    #expect(QATurnStatus.incomplete.label == "Stopped at the output limit")
    #expect(QATurnStatus.incomplete.systemImage == "exclamationmark.triangle")
    #expect(QATurnStatus(outcome: .declined) == .declined)
    #expect(QATurnStatus.declined.label == "The model declined to answer.")
    #expect(QATurnStatus.declined.systemImage == "hand.raised")
}

// MARK: - Errors

@MainActor @Test func anthropicErrorsGiveTheDesignTextAndNeverTheBody() async throws {
    let secret = "SECRET-BODY-TEXT"
    func body(_ type: String) -> String { #"{"type":"error","error":{"type":"\#(type)","message":"\#(secret)"}}"# }
    func reason(_ status: Int, _ text: String) async throws -> String? {
        let updates = try await answer(text, status: status).updates
        guard updates.count == 1, case .ended(let outcome, "") = updates[0] else { return nil }
        return outcome.learnerText
    }
    #expect(try await reason(401, body("authentication_error")) == "Anthropic did not accept the API key. Check it in Settings.")
    #expect(try await reason(403, body("permission_error")) == "This API key cannot use claude-sonnet-5-5.")
    #expect(try await reason(429, body("rate_limit_error")) == "Anthropic rate limit reached. Try again later.")
    #expect(try await reason(529, body("overloaded_error")) == "Anthropic is busy. Try again later.")
    #expect(try await reason(529, "") == "Anthropic is busy. Try again later.")
    // An `overloaded_error` body with another status is also busy.
    #expect(try await reason(503, body("overloaded_error")) == "Anthropic is busy. Try again later.")
    for status in [307, 400, 404, 500] {
        #expect(try await reason(status, body("api_error")) == "Anthropic sent an error (\(status)).", "\(status)")
    }
    // A limit that the model can't give is a clear output limit error.
    #expect(try await reason(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 99999 > 64000"}}"#)
        == "The output limit is too large for claude-sonnet-5-5. Lower it in Settings.")

    // An error event in the stream ends the answer with the text of its type. No partial answer stays.
    func streamed(_ type: String) async throws -> [AnswerUpdate] {
        try await answer(start + textDelta("Half") + event("error", body(type))).updates
    }
    #expect(try await streamed("overloaded_error") == [.delta(text: "Half"), .ended(.refused(reason: "Anthropic is busy. Try again later."), text: "")])
    #expect(try await streamed("rate_limit_error").last == .ended(.refused(reason: "Anthropic rate limit reached. Try again later."), text: ""))
    #expect(try await streamed("api_error").last == .ended(.refused(reason: "Anthropic sent an error (500)."), text: ""))
    #expect(try await streamed("something_new").last == .ended(.refused(reason: "Anthropic sent an error (500)."), text: ""))

    // No response at all.
    let transport = ScriptedTransport()
    let provider = AnthropicAnswerProvider(profile: anthropic(), credentials: MemoryCredentialStore(secrets: ["claude": apiKey]),
                                           transport: transport)
    let request = try #require(provider.prepare()).ask(question)
    await transport.next().finish(throwing: URLError(.notConnectedToInternet))
    #expect(await collect(request)
        == [.ended(.refused(reason: "Skillgarden can't connect to Anthropic. Check the internet connection."), text: "")])

    // The key and the body never go into a reason, and only reasons that name Settings get "Open Settings…".
    for text in [AnthropicErrors.rejectedKey, AnthropicErrors.busy, AnthropicErrors.rateLimited] {
        #expect(!text.contains(secret) && !text.contains(apiKey))
    }
    #expect(QATurnStatus.failed(reason: AnthropicErrors.rejectedKey).opensSettings)
    #expect(!QATurnStatus.failed(reason: AnthropicErrors.busy).opensSettings)
    #expect(!QATurnStatus.incomplete.opensSettings)
}

@MainActor @Test func cancelEndsAtOnceAndLateEventsChangeNothing() async throws {
    let transport = ScriptedTransport()
    let provider = AnthropicAnswerProvider(profile: anthropic(), credentials: MemoryCredentialStore(secrets: ["claude": apiKey]),
                                           transport: transport)
    let request = try #require(provider.prepare()).ask(question)
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    stream.yield(.data(Data((start + textDelta("A loop")).utf8)))
    var updates = request.updates.makeAsyncIterator()
    #expect(await updates.next() == .delta(text: "A loop"))
    provider.cancel(request.id)
    #expect(await updates.next() == .ended(.canceled, text: "A loop"))
    #expect(await updates.next() == nil)
    stream.yield(.data(Data((textDelta(" more") + stop("end_turn")).utf8)))
    stream.finish()
    while transport.terminated == 0 { await Task.yield() }
    #expect(transport.requests.count == 1)
}

// MARK: - Connection test

@MainActor @Test func connectionTestSendsOneShortSyntheticMessage() async throws {
    let transport = ScriptedTransport()
    async let result = AnthropicAnswerProvider.testConnection(anthropic(), key: " \(apiKey) ", transport: transport)
    // The limit of 16 tokens stops the model. That is a pass.
    await reply(transport, start + textDelta("O") + stop("max_tokens"))
    #expect(await result == .connected)
    let sent = try #require(transport.requests.first)
    #expect(sent.value(forHTTPHeaderField: "x-api-key") == apiKey)
    let body = try json(sent)
    #expect(body["max_tokens"] as? Int == 16)
    #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "Reply with the word OK."]])

    async let rejected = AnthropicAnswerProvider.testConnection(anthropic(), key: apiKey, transport: transport)
    await reply(transport, status: 401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
    #expect(await rejected == .failed(reason: "Anthropic did not accept the API key. Check it in Settings."))

    #expect(await AnthropicAnswerProvider.testConnection(anthropic(), key: nil, transport: transport) == .failed(reason: "Enter an API key."))
    #expect(await AnthropicAnswerProvider.testConnection(anthropic(modelID: ""), key: apiKey, transport: transport)
        == .failed(reason: "Enter the model ID."))
    #expect(transport.requests.count == 2)

    // Settings tests the Anthropic profile through the shipped adapters, with the sheet key or the saved key.
    var keys: [String?] = []
    let providers = ProviderSettings(store: nil, credentials: MemoryCredentialStore(), adapterKinds: ShippedAdapters.kinds,
                                     testConnection: { _, key in keys.append(key); return .connected })
    #expect(providers.canTest(.api))
    try providers.save(anthropic(), secret: "sk-ant-saved")
    #expect(await providers.test(anthropic(), secret: nil) == .connected)
    #expect(await providers.test(anthropic(), secret: "sk-ant-new") == .connected)
    #expect(keys == ["sk-ant-saved", "sk-ant-new"])
}

// MARK: - Profile and text

@MainActor @Test func presetAndTextMatchTheDesignNotes() {
    #expect(APIService.allCases.map(\.menuTitle) == ["OpenAI API…", "Anthropic API…"])
    let preset = ProviderProfile.preset(.anthropic)
    #expect(preset.kind == .api && preset.name == "Anthropic API" && preset.vendor == "Anthropic")
    #expect(preset.origin == "https://api.anthropic.com" && preset.host == "api.anthropic.com")
    #expect(preset.modelID.isEmpty && preset.answerTokens == 1024)
    #expect(preset.apiService == .anthropic)
    #expect(preset.modelProblem == "Enter the model ID.")
    #expect(!preset.isValid(hasSecret: true))
    #expect(APIService.anthropic.keyPrompt == "sk-ant-…")
    #expect(APIService.anthropic.modelPrompt == "Model ID, for example claude-sonnet-5-5")
    #expect(APIService.anthropic.footer
        == "Claude Pro and Max plans do not work here. Use an API key from the Anthropic Console.")

    var profile = preset
    profile.modelID = "claude-sonnet-5-5"
    #expect(profile.isValid(hasSecret: true))
    #expect(!profile.isValid(hasSecret: false))
    #expect(profile.title == "Anthropic API · claude-sonnet-5-5")
    #expect(profile.caption == "api.anthropic.com · claude-sonnet-5-5 · API")
    #expect(profile.answerFooter == "Answers come from Anthropic and can be wrong.")
    // An empty Output limit field is 0: the sheet shows the problem and "Save" is off.
    profile.answerTokens = 0
    #expect(profile.answerTokensProblem == "Enter an output limit of 1 or more tokens.")
    #expect(!profile.isValid(hasSecret: true))
    // Another host is not the Anthropic service, so no adapter sends for it.
    #expect(anthropic(origin: "https://api.example.com").apiService == nil)
    #expect(ShippedAdapters.kinds == [.externalLocal, .api, .subscription])
    let credentials = MemoryCredentialStore()
    #expect(ShippedAdapters.provider(for: anthropic(), credentials: credentials) is AnthropicAnswerProvider)
    #expect(ShippedAdapters.provider(for: anthropic(origin: "https://api.example.com"), credentials: credentials) == nil)
    #expect(ShippedAdapters.provider(for: .preset(.lmStudio), credentials: credentials) is CompatibleAnswerProvider)
    #expect(ShippedAdapters.provider(for: SnapshotPlan.providerProfiles[0], credentials: credentials) is OpenAIAnswerProvider)
}

// MARK: - Q&A, consent, internal text and no fallback

/// The bundled model. It records each request, so a test can prove that no fallback happens.
@MainActor
private final class RecordingBundled: AnswerProvider {
    let id = BundledAnswerProvider.providerID
    let displayName = "Local Model"
    let kind = AnswerProviderKind.local
    private(set) var prepared = 0

    func prepare() -> PreparedAnswer? {
        prepared += 1
        return nil
    }

    func cancel(_ id: UUID) {}
}

@MainActor @Test func anthropicAnswersNeedConsentSendNoInternalTextAndNeverFallBack() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnthropicProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // The fixture has internal files and an internal manifest section.
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaEmpty, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))

    let transport = ScriptedTransport()
    let providers = ProviderSettings(store: ProviderSettingsStore(directory: root), credentials: MemoryCredentialStore(),
                                     adapterKinds: ShippedAdapters.kinds,
                                     makeProvider: { AnthropicAnswerProvider(profile: $0, credentials: $1, transport: transport) })
    try providers.save(anthropic(answerTokens: 512), secret: apiKey)
    providers.select("claude")
    let bundled = RecordingBundled()
    let qa = LectureQA(library: library, provider: bundled, providers: providers, draftInterval: .zero)
    qa.show(LectureQA.key(library: library))
    await qa.load()
    #expect(qa.provider is AnthropicAnswerProvider)

    // No request before the course allows Anthropic.
    #expect(!qa.send("What is the goal of this course?"))
    let consent = try #require(qa.consentRequest)
    #expect(consent.title == "Send this question to Anthropic?")
    #expect(transport.requests.isEmpty)
    #expect(qa.allowAndSend())

    // The first answer stops at the output limit: the partial answer stays with the label and Retry.
    await reply(transport, start + textDelta("It starts [t0]. Then") + stop("max_tokens"))
    await qa.waitForRequest()
    let limited = try #require(qa.conversation.turns.last)
    #expect(limited.status == .incomplete && limited.answer == "It starts [t0]. Then")
    #expect(limited.origin == AnswerOrigin(providerID: "claude", modelID: "claude-sonnet-5-5"))
    #expect(qa.conversation.canRetry(limited))

    // Retry sends again to Anthropic. A 529 fails with the busy text. The bundled model never answers.
    #expect(qa.retry(limited))
    await reply(transport, status: 529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
    await qa.waitForRequest()
    #expect(qa.conversation.turns.last?.status == .failed(reason: "Anthropic is busy. Try again later."))
    #expect(qa.conversation.turns.last?.origin.providerID == "claude")
    #expect(qa.send("How does the course start?"))
    await reply(transport, start + textDelta("Sorry") + stop("refusal"))
    await qa.waitForRequest()
    #expect(qa.conversation.turns.last?.status == .declined && qa.conversation.turns.last?.answer == "")
    #expect(bundled.prepared == 0)
    #expect(transport.requests.count == 3)

    // No request holds internal-only text. The incomplete turn is not in the history of a later prompt.
    let internalText = ["This placeholder belongs to the team", "Team transcript placeholder", "Research brief",
                    "Team notes for the course plan", "internal/research.md"]
    for request in transport.requests {
        let sent = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(sent.contains("t0"))
        #expect(try json(request)["max_tokens"] as? Int == 512)
        for text in internalText { #expect(!sent.contains(text), "\(text)") }
    }
    let last = try json(try #require(transport.requests.last))
    #expect((last["messages"] as? [[String: String]])?.map { $0["role"] } == ["user"])

    // The saved turns load again with their states.
    let saved = try #require(try await library.lectureConversation(forLecture: "welcome"))
    #expect(saved.turns.map(\.status) == [.incomplete, .failed(reason: "Anthropic is busy. Try again later."), .declined])
}

// MARK: - Saved files

@Test func turnsSavedBeforeTheNewStatesStillLoad() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnthropicProviderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(12)))
    #expect(try old.schemaVersion == 12)
    let course = Course(id: "c", title: "Garden", state: .published, sections: [
        CourseSection(id: "s", title: "Start", order: 0, state: .published,
                      lectures: [Lecture(id: "a", title: "a", type: .article, order: 0, state: .published)]),
    ])
    try old.saveCourse(course)
    let origin = AnswerOrigin(providerID: "lm", modelID: "qwen")
    var ids: [Int64] = []
    for (status, answer) in [(QATurnStatus.complete, "Because."), (.failed(reason: "No server."), ""), (.cancelled, "Half")] {
        let turn = try old.startQATurn(question: "Q\(ids.count)", sourceRevision: "r", origin: origin, courseID: "c", lectureID: "a")
        try old.finishQATurn(id: turn.id, status: status, answer: answer)
        ids.append(turn.id)
    }
    _ = try old.startQATurn(question: "Pending", sourceRevision: "r", origin: .legacy, courseID: "c", lectureID: "a")
    // Version 12 can't save the new states.
    let early = try old.startQATurn(question: "Early", sourceRevision: "r", origin: origin, courseID: "c", lectureID: "a")
    #expect(throws: (any Error).self) { try old.finishQATurn(id: early.id, status: .incomplete, answer: "x") }

    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == CourseStore.currentSchemaVersion)
    #expect(CourseStore.currentSchemaVersion == CourseStore.migrations.count)
    #expect(try store.loadCourse(id: "c") == course)
    let loaded = try store.qaTurns(courseID: "c", lectureID: "a")
    #expect(Array(loaded.prefix(3).map(\.id)) == ids)
    #expect(loaded.map(\.question) == ["Q0", "Q1", "Q2", "Pending", "Early"])
    #expect(loaded.map(\.status) == [.complete, .failed(reason: "No server."), .cancelled, .pending, .pending])
    #expect(loaded.map(\.answer) == ["Because.", "", "Half", "", ""])
    #expect(loaded.map(\.origin) == [origin, origin, origin, .legacy, origin])

    // The new states save and load. Clear History still removes the turns of the thread.
    try store.finishQATurn(id: early.id, status: .incomplete, answer: "Partial")
    let declined = try store.startQATurn(question: "No", sourceRevision: "r", origin: origin, courseID: "c", lectureID: "a")
    try store.finishQATurn(id: declined.id, status: .declined, answer: "")
    try store.interruptPendingQATurns()
    let reopened = try CourseStore(root: root).qaTurns(courseID: "c", lectureID: "a")
    #expect(reopened.map(\.status) == [.complete, .failed(reason: "No server."), .cancelled, .interrupted, .incomplete, .declined])
    #expect(reopened[4].answer == "Partial")
    try store.clearQAHistory(courseID: "c", lectureID: "a")
    #expect(try store.qaTurns(courseID: "c", lectureID: "a").isEmpty)
}

@MainActor @Test func anthropicProfilesSavedBeforeThisChangeStillLoad() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnthropicProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    // A #151 file: an Anthropic API profile with no output limit, its consent and the choice.
    try Data("""
    {"version": 1, "selectedID": "claude",
     "profiles": [{"id": "claude", "kind": "api", "name": "Anthropic API", "vendor": "Anthropic",
                   "origin": "https://api.anthropic.com", "modelID": "claude-sonnet-5-5", "credentialReference": "claude"}],
     "consents": [{"courseID": "c", "allowedAt": 0,
                   "destination": {"profileID": "claude", "kind": "api", "host": "api.anthropic.com", "modelID": "claude-sonnet-5-5"}}]}
    """.utf8).write(to: store.fileURL)
    let providers = ProviderSettings(store: store, credentials: MemoryCredentialStore(secrets: ["claude": apiKey]),
                                     adapterKinds: ShippedAdapters.kinds, makeProvider: { ShippedAdapters.provider(for: $0, credentials: $1) })
    let profile = try #require(providers.selected)
    #expect(profile.answerTokens == nil && profile.answerTokensProblem == nil)
    #expect(profile.isValid(hasSecret: true))
    #expect(providers.hasConsent(courseID: "c", destination: profile.destination))
    let provider = providers.activeProvider(bundled: RecordingBundled())
    #expect(provider is AnthropicAnswerProvider)
    #expect(provider.prepare() != nil)
    // No limit in the file gives the default of 1024.
    let request = try #require(AnthropicAnswerProvider.messagesRequest(question, profile: profile, key: apiKey))
    #expect(try json(request)["max_tokens"] as? Int == 1024)
}
