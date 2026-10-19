import Darwin
import Foundation
import Testing
@testable import SkillgardenCore

// #152: LM Studio and Ollama through the OpenAI-compatible adapter. The fixtures copy the stream form of each server.
// No test needs LM Studio, Ollama or a model.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")
private let question = [ChatMessage(role: .user, content: "What is a loop?")]

private func lmStudio(origin: String = "http://127.0.0.1:1234/v1", modelID: String = "qwen3-8b-mlx",
                      credentialReference: String? = nil) -> ProviderProfile {
    ProviderProfile(id: "lm", kind: .externalLocal, name: "LM Studio", vendor: "LM Studio", origin: origin, modelID: modelID,
                    credentialReference: credentialReference)
}

private func ollama(origin: String = "http://127.0.0.1:11434/v1") -> ProviderProfile {
    ProviderProfile(id: "ollama", kind: .externalLocal, name: "Ollama", vendor: "Ollama", origin: origin, modelID: "llama3.2")
}

/// LM Studio chunks: a role chunk with text, a reasoning chunk with no `content`, a finish chunk, then `[DONE]`.
private let lmStudioStream = """
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"qwen3-8b-mlx","system_fingerprint":"qwen3-8b-mlx","choices":[{"index":0,"delta":{"role":"assistant","content":"A loop"},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"qwen3-8b-mlx","choices":[{"index":0,"delta":{"reasoning_content":"Think."},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"qwen3-8b-mlx","choices":[{"index":0,"delta":{"content":" repeats [t1]."},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"qwen3-8b-mlx","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}

data: [DONE]


"""

/// Ollama chunks: each delta has the role, the finish chunk has empty text, then a usage chunk and `[DONE]`.
private let ollamaStream = """
data: {"id":"chatcmpl-42","object":"chat.completion.chunk","created":1,"model":"llama3.2","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"A loop"},"finish_reason":null}]}

data: {"id":"chatcmpl-42","object":"chat.completion.chunk","created":1,"model":"llama3.2","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":" repeats [t1]."},"finish_reason":null}]}

data: {"id":"chatcmpl-42","object":"chat.completion.chunk","created":1,"model":"llama3.2","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop"}]}

data: {"id":"chatcmpl-42","object":"chat.completion.chunk","created":1,"model":"llama3.2","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":4}}

data: [DONE]


"""

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

/// One answer of `profile` on the scripted transport: the status, then `body` cut in pieces of `piece` bytes, then `end`.
@MainActor
private func answer(_ profile: ProviderProfile, status: Int = 200, _ body: String = "", piece: Int = 7,
                    end: (any Error)? = nil) async throws -> (updates: [AnswerUpdate], request: URLRequest) {
    let transport = ScriptedTransport()
    let provider = CompatibleAnswerProvider(profile: profile, credentials: MemoryCredentialStore(), transport: transport)
    let prepared = try #require(provider.prepare())
    #expect(prepared.origin == AnswerOrigin(providerID: profile.id, modelID: profile.modelID))
    let request = prepared.ask(question)
    let stream = await transport.next()
    stream.yield(.response(status: status))
    let bytes = Array(body.utf8)
    for start in stride(from: 0, to: bytes.count, by: piece) {
        stream.yield(.data(Data(bytes[start..<min(start + piece, bytes.count)])))
    }
    stream.finish(throwing: end)
    return (await collect(request), try #require(transport.requests.first))
}

// MARK: - Streams and cancel

@MainActor @Test func lmStudioAndOllamaFixturesStreamIncrementalAnswers() async throws {
    for (profile, body) in [(lmStudio(), lmStudioStream), (ollama(), ollamaStream)] {
        // A cut every 7 bytes and every byte gives the same answer.
        for piece in [1, 7, 4096] {
            let (updates, _) = try await answer(profile, body, piece: piece)
            #expect(updates == [.delta(text: "A loop"), .delta(text: "A loop repeats [t1]."),
                                .ended(.finished, text: "A loop repeats [t1].")], "\(profile.name) piece \(piece)")
        }
    }
}

@MainActor @Test func requestsGoToTheBaseURLWithTheModelAndTheOptionalToken() async throws {
    let (_, request) = try await answer(lmStudio(), lmStudioStream)
    #expect(request.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(!request.httpShouldHandleCookies)
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["model"] as? String == "qwen3-8b-mlx")
    #expect(body["stream"] as? Bool == true)
    #expect(body["max_tokens"] == nil)
    #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "What is a loop?"]])

    let (_, ipv6) = try await answer(ollama(origin: "http://[::1]:11434"), ollamaStream)
    #expect(ipv6.url?.absoluteString == "http://[::1]:11434/v1/chat/completions")

    // The token comes from the credential store on each question. It never goes into the profile.
    let transport = ScriptedTransport()
    let credentials = MemoryCredentialStore(secrets: ["lm": "lm-token-1"])
    let provider = CompatibleAnswerProvider(profile: lmStudio(credentialReference: "lm"), credentials: credentials, transport: transport)
    let first = try #require(provider.prepare()).ask(question)
    await transport.next().finish()
    _ = await collect(first)
    try credentials.save("lm-token-2", account: "lm")
    let second = try #require(provider.prepare()).ask(question)
    await transport.next().finish()
    _ = await collect(second)
    #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer lm-token-1", "Bearer lm-token-2"])
    // A refused Keychain item sends nothing.
    let denied = CompatibleAnswerProvider(profile: lmStudio(credentialReference: "lm"),
                                          credentials: MemoryCredentialStore(deniedAccounts: ["lm"]), transport: transport)
    #expect(denied.prepare() == nil)
    #expect(transport.requests.count == 2)
}

@MainActor @Test func cancelEndsAtOnceWithThePartialAnswer() async throws {
    let transport = ScriptedTransport()
    let provider = CompatibleAnswerProvider(profile: lmStudio(), credentials: MemoryCredentialStore(), transport: transport)
    let request = try #require(provider.prepare()).ask(question)
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    let bytes = Array(lmStudioStream.utf8)
    stream.yield(.data(Data(bytes[...(bytes.firstIndex(of: 0x0A)! + 1)])))
    var updates = request.updates.makeAsyncIterator()
    #expect(await updates.next() == .delta(text: "A loop"))
    // The server stays open. Cancel does not wait for it, and later events go nowhere.
    provider.cancel(request.id)
    #expect(await updates.next() == .ended(.canceled, text: "A loop"))
    #expect(await updates.next() == nil)
    stream.yield(.data(Data(lmStudioStream.utf8)))
    stream.finish()
    // Cancel stops the transport. A second cancel does nothing.
    while transport.terminated == 0 { await Task.yield() }
    provider.cancel(request.id)
    #expect(transport.requests.count == 1)

    // A second question while one runs is busy.
    let first = try #require(provider.prepare()).ask(question)
    let running = await transport.next()
    let busy = try #require(provider.prepare()).ask(question)
    #expect(await collect(busy) == [.ended(.busy, text: "")])
    running.yield(.response(status: 200))
    running.yield(.data(Data(ollamaStream.utf8)))
    running.finish()
    #expect(await collect(first).last == .ended(.finished, text: "A loop repeats [t1]."))
}

// MARK: - Errors

@MainActor @Test func errorsGiveTheDesignTextAndNeverTheBody() async throws {
    let secretBody = "SECRET-BODY-TEXT"
    func reason(_ status: Int, _ body: String = "") async throws -> [AnswerUpdate] {
        try await answer(lmStudio(), status: status, body).updates
    }
    let unknown = AnswerUpdate.ended(.refused(reason: "The server has no model \"qwen3-8b-mlx\"."), text: "")
    #expect(try await reason(404, #"{"error":{"message":"model \"qwen3-8b-mlx\" not found, try pulling it first \#(secretBody)"}}"#) == [unknown])
    #expect(try await reason(400, #"{"error":{"message":"Invalid model identifier \#(secretBody)","type":"invalid_request_error","param":"model","code":"model_not_found"}}"#) == [unknown])
    #expect(try await reason(400, #"{"error":"Model qwen3-8b-mlx not found \#(secretBody)"}"#) == [unknown])
    for status in [401, 403] {
        #expect(try await reason(status, secretBody) == [.ended(.refused(reason: "The server did not accept the token."), text: "")])
    }
    for status in [307, 400, 500, 503] {
        #expect(try await reason(status, #"{"error":{"message":"\#(secretBody)","code":7}}"#)
            == [.ended(.refused(reason: "The server sent an error (\(status))."), text: "")], "\(status)")
    }
    // An error event in the stream ends the answer with the status text.
    let inStream = try await answer(ollama(), "data: {\"choices\":[{\"delta\":{\"content\":\"Half\"}}]}\n\n"
        + "data: {\"error\":{\"message\":\"\(secretBody)\",\"type\":\"api_error\",\"param\":null,\"code\":null}}\n\n").updates
    #expect(inStream == [.delta(text: "Half"), .ended(.refused(reason: "The server sent an error (500)."), text: "")])
    // No response at all: the server is not running. A lost connection keeps the partial answer.
    let transport = ScriptedTransport()
    let provider = CompatibleAnswerProvider(profile: ollama(), credentials: MemoryCredentialStore(), transport: transport)
    let refused = try #require(provider.prepare()).ask(question)
    await transport.next().finish(throwing: URLError(.cannotConnectToHost))
    #expect(await collect(refused) == [.ended(.refused(reason: "Ollama is not running at 127.0.0.1:11434."), text: "")])
    #expect(try await answer(lmStudio(), "data: {\"choices\":[{\"delta\":{\"content\":\"Half\"}}]}\n\n",
                             end: URLError(.networkConnectionLost)).updates
        == [.delta(text: "Half"), .ended(.disconnected, text: "Half")])

    let refusal = AnswerOutcome.refused(reason: "x")
    #expect(!refusal.keepsText)
    #expect(refusal.learnerText == "x")
    #expect(QATurnStatus(outcome: refusal) == .failed(reason: "x"))
    #expect(QATurnStatus(outcome: refusal).label == "No answer: x")
}

@MainActor @Test func onlyLiteralLoopbackBaseURLsSend() async throws {
    let transport = ScriptedTransport()
    let rejected = ["http://localhost:1234/v1", "https://127.0.0.1:1234/v1", "http://127.0.0.2:1234/v1", "http://10.0.0.1:1234/v1",
                    "http://0.0.0.0:1234/v1", "http://user:pass@127.0.0.1:1234/v1", "http://127.0.0.1:1234/v1?to=example.com",
                    "http://127.0.0.1:1234/v1#x", "http://api.example.com/v1", "file:///tmp/socket", "", "127.0.0.1:1234"]
    for origin in rejected {
        let profile = lmStudio(origin: origin)
        #expect(ProviderProfile.loopbackBaseURL(origin) == nil, "\(origin)")
        #expect(profile.originProblem == "Use 127.0.0.1 or [::1]. Use an API provider for other hosts.", "\(origin)")
        #expect(!profile.isValid(hasSecret: true), "\(origin)")
        #expect(CompatibleAnswerProvider(profile: profile, credentials: MemoryCredentialStore(), transport: transport).prepare() == nil)
        #expect(await CompatibleAnswerProvider.testConnection(profile, token: nil, transport: transport)
            == .failed(reason: ProviderProfile.loopbackOnlyText))
    }
    // A token that a header can't hold sends nothing.
    #expect(CompatibleAnswerProvider.chatRequest(question, profile: lmStudio(), token: "tok\r\nX-Other: 1") == nil)
    #expect(CompatibleAnswerProvider.chatRequest(question, profile: lmStudio(modelID: " "), token: nil) == nil)
    // The bundled kind never uses this adapter.
    var api = lmStudio()
    api.kind = .api
    #expect(CompatibleAnswerProvider.chatRequest(question, profile: api, token: nil) == nil)
    #expect(transport.requests.isEmpty)

    let accepted = [("http://127.0.0.1:1234/v1", "http://127.0.0.1:1234/v1"), ("http://127.0.0.1:1234", "http://127.0.0.1:1234/v1"),
                    ("http://127.0.0.1:1234/", "http://127.0.0.1:1234/v1"), ("http://[::1]:11434/v1/", "http://[::1]:11434/v1"),
                    (" http://127.0.0.1:8080/api/v1 ", "http://127.0.0.1:8080/api/v1")]
    for (origin, base) in accepted {
        #expect(ProviderProfile.loopbackBaseURL(origin)?.absoluteString == base, "\(origin)")
        #expect(lmStudio(origin: origin).originProblem == nil)
    }
    // Plain HTTP for an API profile is valid only for a loopback host.
    var http = ProviderProfile(kind: .api, name: "Proxy", vendor: "Proxy", origin: "http://api.example.com", modelID: "m")
    #expect(!http.isValid(hasSecret: true))
    http.origin = "http://127.0.0.1:4000"
    #expect(http.isValid(hasSecret: true))
}

// MARK: - Connection test

@MainActor @Test func connectionTestSendsOneSyntheticMessageAndMapsErrors() async throws {
    // A passed test: one request with the synthetic message only, a short answer limit and the token.
    let ok = try StubServer { _, socket in
        StubServer.write(socket, StubServer.streamHead + StubServer.part(lmStudioStream) + "0\r\n\r\n")
    }
    #expect(await CompatibleAnswerProvider.testConnection(lmStudio(origin: "http://127.0.0.1:\(ok.port)/v1"), token: "tok-1") == .connected)
    #expect(ok.requests.count == 1)
    let sent = try #require(ok.requests.first)
    #expect(sent.hasPrefix("POST /v1/chat/completions HTTP/1.1\r\n"))
    #expect(sent.contains("Authorization: Bearer tok-1\r\n"))
    #expect(sent.contains(#""max_tokens":16"#))
    #expect(sent.contains(#""content":"Reply with the word OK.""#))
    #expect(sent.components(separatedBy: #""role":"#).count == 2)

    // A reasoning model that uses all of the limit with no text still passes.
    let empty = try StubServer { _, socket in
        StubServer.write(socket, StubServer.streamHead + StubServer.part("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n")
            + "0\r\n\r\n")
    }
    #expect(await CompatibleAnswerProvider.testConnection(ollama(origin: "http://127.0.0.1:\(empty.port)"), token: nil) == .connected)

    // An unknown model, a refused token and another error. The raw body never shows.
    func failing(_ status: String, _ body: String) throws -> StubServer {
        try StubServer { _, socket in
            StubServer.write(socket, StubServer.head(status, "Content-Length: \(body.utf8.count)\r\n") + body)
        }
    }
    let cases = [
        (try failing("404 Not Found", #"{"error":{"message":"model \"qwen3-8b-mlx\" not found RAW"}}"#),
         "The server has no model \"qwen3-8b-mlx\"."),
        (try failing("401 Unauthorized", #"{"error":"RAW"}"#), "The server did not accept the token."),
        (try failing("500 Internal Server Error", #"{"error":{"message":"RAW"}}"#), "The server sent an error (500)."),
    ]
    for (server, text) in cases {
        let result = await CompatibleAnswerProvider.testConnection(lmStudio(origin: "http://127.0.0.1:\(server.port)/v1"), token: nil)
        #expect(result == .failed(reason: text))
    }

    // No server on the port: "not running" with the host and the port.
    let closed = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(closed, $0, length) == 0 && getsockname(closed, $0, &length) == 0 }
    }
    let port = Int(UInt16(bigEndian: address.sin_port))
    close(closed)
    #expect(await CompatibleAnswerProvider.testConnection(lmStudio(origin: "http://127.0.0.1:\(port)/v1"), token: nil)
        == .failed(reason: "LM Studio is not running at 127.0.0.1:\(port)."))
    #expect(await CompatibleAnswerProvider.testConnection(lmStudio(modelID: ""), token: nil) == .failed(reason: "Enter the model ID."))
}

@MainActor @Test func settingsTestUsesTheSheetKeyOrTheSavedKey() async throws {
    var tokens: [String?] = []
    let credentials = MemoryCredentialStore()
    let providers = ProviderSettings(store: nil, credentials: credentials, adapterKinds: [.externalLocal],
                                     testConnection: { _, token in tokens.append(token); return .connected })
    #expect(providers.canTest(.externalLocal))
    #expect(!providers.canTest(.api))
    #expect(await providers.test(ProviderProfile.preset(.ollama), secret: "") == .connected)
    try providers.save(lmStudio(), secret: "saved-token")
    #expect(await providers.test(lmStudio(), secret: nil) == .connected)
    #expect(await providers.test(lmStudio(), secret: " new-token ") == .connected)
    #expect(tokens == [nil, "saved-token", "new-token"])
    var api = lmStudio()
    api.kind = .api
    #expect(await providers.test(api, secret: "x") == nil)
    #expect(tokens.count == 3)
    // No test without an adapter.
    #expect(!ProviderSettings(store: nil, credentials: credentials).canTest(.externalLocal))
}

// MARK: - Presets and text

@Test func presetsAndTextMatchTheDesignNotes() {
    #expect(ExternalLocalServer.allCases.map(\.menuTitle) == ["LM Studio…", "Ollama…"])
    let studio = ProviderProfile.preset(.lmStudio)
    #expect(studio.kind == .externalLocal)
    #expect(studio.name == "LM Studio" && studio.vendor == "LM Studio")
    #expect(studio.origin == "http://127.0.0.1:1234/v1")
    #expect(studio.modelID.isEmpty)
    #expect(studio.modelProblem == "Enter the model ID.")
    #expect(studio.originProblem == nil)
    #expect(!studio.isValid(hasSecret: false))
    #expect(studio.externalServer == .lmStudio)
    let local = ProviderProfile.preset(.ollama)
    #expect(local.origin == "http://127.0.0.1:11434/v1")
    #expect(local.externalServer == .ollama)
    #expect(ExternalLocalServer.lmStudio.footer == "Skillgarden does not start LM Studio. Start its local server first.")
    #expect(ExternalLocalServer.ollama.footer == "Ollama can send text to cloud models. Set OLLAMA_NO_CLOUD=1 to keep text on this Mac.")

    let profile = lmStudio()
    #expect(profile.isValid(hasSecret: false))
    #expect(profile.title == "LM Studio · qwen3-8b-mlx")
    #expect(profile.host == "127.0.0.1:1234")
    #expect(ollama(origin: "http://[::1]:11434/v1").host == "[::1]:11434")
    #expect(profile.caption == "127.0.0.1:1234 · qwen3-8b-mlx · External local server")
    #expect(profile.answerFooter == "Answers come from LM Studio on this Mac and can be wrong.")
    #expect(ProviderProfile(kind: .api, name: "OpenAI API", vendor: "OpenAI", origin: "https://api.openai.com", modelID: "gpt-5")
        .answerFooter == "Answers come from OpenAI and can be wrong.")
    // A renamed profile keeps its preset footer.
    var renamed = profile
    renamed.name = "Studio on M4"
    #expect(renamed.externalServer == .lmStudio)
}

// MARK: - Q&A, consent and citations

@MainActor @Test func externalLocalAnswersNeedConsentAndCitationsValidateAgainstTheSentPassages() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CompatibleProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaEmpty, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))

    let transport = ScriptedTransport()
    let providers = ProviderSettings(store: ProviderSettingsStore(directory: root), credentials: MemoryCredentialStore(),
                                     adapterKinds: [.externalLocal],
                                     makeProvider: { CompatibleAnswerProvider(profile: $0, credentials: $1, transport: transport) })
    try providers.save(lmStudio(), secret: nil)
    providers.select("lm")
    let qa = LectureQA(library: library, provider: UnavailableAnswerProvider(profile: lmStudio()), providers: providers,
                       draftInterval: .zero)
    qa.show(LectureQA.key(library: library))
    await qa.load()
    #expect(qa.provider is CompatibleAnswerProvider)

    // An external local server also needs the consent of the course. The sheet names the cloud limit.
    #expect(!qa.send("What is the goal of this course?"))
    let request = try #require(qa.consentRequest)
    #expect(request.title == "Send this question to LM Studio?")
    #expect(request.cloudNote == "Skillgarden can't check if this server uses the cloud.")
    #expect(transport.requests.isEmpty)
    #expect(qa.allowAndSend())

    // The answer cites a sent passage and a passage that the request did not have.
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    stream.yield(.data(Data(("data: {\"choices\":[{\"delta\":{\"content\":\"It starts [t0]. See [L9].\"}}]}\n\n"
        + "data: [DONE]\n\n").utf8)))
    stream.finish()
    await qa.waitForRequest()
    let sent = try #require(transport.requests.first?.httpBody)
    #expect(String(decoding: sent, as: UTF8.self).contains("t0"))
    let turn = try #require(qa.conversation.turns.last)
    #expect(turn.status == .complete)
    #expect(turn.origin == AnswerOrigin(providerID: "lm", modelID: "qwen3-8b-mlx"))
    #expect(providers.sourceText(for: turn.origin) == "via LM Studio · qwen3-8b-mlx")
    let sources = qa.citations(for: turn).sources
    #expect(sources.count == 2)
    #expect(sources.first.map { if case .video = $0.kind { true } else { false } } == true)
    #expect(sources.last?.kind == .unknown)

    // A failed request saves the design text as the turn reason.
    #expect(qa.send("How does the course start?"))
    let failing = await transport.next()
    failing.finish(throwing: URLError(.cannotConnectToHost))
    await qa.waitForRequest()
    #expect(qa.conversation.turns.last?.status == .failed(reason: "LM Studio is not running at 127.0.0.1:1234."))
}

// MARK: - Saved files

@MainActor @Test func providerFilesSavedBeforeThisChangeStillLoad() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CompatibleProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    // A #151 file: an external local server with a `localhost` URL and no path, its consent and the choice.
    try Data("""
    {"version": 1, "selectedID": "lm",
     "profiles": [{"id": "lm", "kind": "externalLocal", "name": "LM Studio", "vendor": "LM Studio",
                   "origin": "http://localhost:1234", "modelID": "qwen"}],
     "consents": [{"courseID": "c", "allowedAt": 0,
                   "destination": {"profileID": "lm", "kind": "externalLocal", "host": "localhost:1234", "modelID": "qwen"}}]}
    """.utf8).write(to: store.fileURL)
    let providers = ProviderSettings(store: store, credentials: MemoryCredentialStore(), adapterKinds: [.externalLocal],
                                     makeProvider: { CompatibleAnswerProvider(profile: $0, credentials: $1, transport: ScriptedTransport()) })
    let profile = try #require(providers.selected)
    #expect(profile.origin == "http://localhost:1234")
    #expect(providers.consents.count == 1)
    #expect(providers.hasConsent(courseID: "c", destination: profile.destination))
    // The profile loads, but it can't answer until the learner fixes the URL. The sheet shows why.
    #expect(profile.originProblem == ProviderProfile.loopbackOnlyText)
    #expect(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: lmStudio())).prepare() == nil)
    var fixed = profile
    fixed.origin = "http://127.0.0.1:1234"
    try providers.save(fixed, secret: nil)
    #expect(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: lmStudio())).prepare() != nil)
    // A new host is a new destination, so the course asks again.
    #expect(providers.consents.isEmpty)
    #expect(ProviderSettings(store: store, credentials: MemoryCredentialStore()).profiles.map(\.origin) == ["http://127.0.0.1:1234"])
}

@Test func docsExplainTheExternalServerPrivacyLimit() throws {
    let doc = try String(contentsOf: repo.appending(path: "docs/local-ai.md"), encoding: .utf8)
    #expect(doc.contains("External local server"))
    #expect(doc.contains("OLLAMA_NO_CLOUD=1"))
    #expect(doc.contains("does not prove"))
    #expect(doc.contains("http://127.0.0.1:1234/v1"))
    #expect(doc.contains("http://127.0.0.1:11434/v1"))
}
