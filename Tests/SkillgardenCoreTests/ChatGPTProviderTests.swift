import Foundation
import Testing
@testable import SkillgardenCore

// #157: answers through an authorized ChatGPT plan. The fixtures copy the SIWC Responses profile.
// Each test uses a stub transport. No test uses the network or a real token.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")
private let accessToken = "access-SECRET-TOKEN-1"
private let clientID = "oaiapp_test123"
private let messages = [ChatMessage(role: .system, content: "Answer from the lecture. [t1] Plan the course."),
                        ChatMessage(role: .user, content: "Why?"), ChatMessage(role: .assistant, content: "Because."),
                        ChatMessage(role: .user, content: "What is a loop?")]

private func plan(modelID: String = "gpt-5") -> ProviderProfile {
    ProviderProfile(id: "chatgpt", kind: .subscription, name: "ChatGPT Plan", vendor: "OpenAI", origin: "https://api.openai.com",
                    modelID: modelID)
}

private func session(expiresIn: TimeInterval = 3600, refreshToken: String? = "refresh-SECRET-1",
                     scopes: [String] = ChatGPTAuthConfiguration.openAI.scopes) -> ChatGPTSession {
    ChatGPTSession(clientID: clientID, accessToken: accessToken, refreshToken: refreshToken, idToken: "id-token",
                   expiresAt: Date().addingTimeInterval(expiresIn), scopes: scopes, subject: "user-1",
                   email: "learner@example.com", planType: "plus")
}

private func event(_ type: String, _ fields: String = "") -> String {
    "event: \(type)\ndata: {\"type\":\"\(type)\",\"sequence_number\":1\(fields.isEmpty ? "" : ",")\(fields)}\n\n"
}

private func delta(_ text: String) -> String {
    event("response.output_text.delta", #""item_id":"msg_1","output_index":0,"content_index":0,"delta":"\#(text)""#)
}

private let head = event("response.created", #""response":{"id":"resp_1","object":"response","status":"in_progress","output":[]}"#)
    + event("response.output_item.added", #""output_index":0,"item":{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}"#)

private let completedStream = head + delta("A loop") + delta(" repeats [t1].")
    + event("response.output_text.done", #""item_id":"msg_1","output_index":0,"content_index":0,"text":"A loop repeats [t1].""#)
    + event("response.completed", #""response":{"id":"resp_1","status":"completed","incomplete_details":null}"#)

private func failedStream(_ code: String) -> String {
    head + delta("Half") + event("response.failed", #""response":{"status":"failed","error":{"code":"\#(code)","message":"RAW-MESSAGE"}}"#)
}

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

private func play(_ stream: ScriptedTransport.Continuation, status: Int = 200, _ body: String, piece: Int = 7,
                  end: (any Error)? = nil) {
    stream.yield(.response(status: status))
    let bytes = Array(body.utf8)
    for start in stride(from: 0, to: bytes.count, by: piece) {
        stream.yield(.data(Data(bytes[start..<min(start + piece, bytes.count)])))
    }
    stream.finish(throwing: end)
}

/// Settings with a signed-in ChatGPT plan profile and the scripted transport. `authorizer` refreshes an expired session.
@MainActor
private func signedIn(_ saved: ChatGPTSession = session(), profile: ProviderProfile = plan(),
                      authorizer: ChatGPTAuthorizer? = nil, store: ProviderSettingsStore? = nil)
    throws -> (ProviderSettings, ScriptedTransport, MemoryCredentialStore) {
    let transport = ScriptedTransport()
    let credentials = MemoryCredentialStore()
    let providers = ProviderSettings(store: store, credentials: credentials, adapterKinds: ShippedAdapters.kinds,
                                     makeProvider: { ShippedAdapters.provider(for: $0, credentials: $1) },
                                     chatGPT: authorizer, chatGPTTransport: transport)
    try providers.saveChatGPT(saved, profile: profile)
    providers.select(profile.id)
    return (providers, transport, credentials)
}

/// One answer of the ChatGPT plan on the scripted transport.
@MainActor
private func answer(status: Int = 200, _ body: String = "", piece: Int = 7, end: (any Error)? = nil)
    async throws -> (updates: [AnswerUpdate], request: URLRequest, providers: ProviderSettings) {
    let (providers, transport, _) = try signedIn()
    let provider = providers.activeProvider(bundled: UnavailableAnswerProvider(profile: plan()))
    let prepared = try #require(provider.prepare())
    #expect(prepared.origin == AnswerOrigin(providerID: "chatgpt", modelID: "gpt-5"))
    let request = prepared.ask(messages)
    play(await transport.next(), status: status, body, piece: piece, end: end)
    return (await collect(request), try #require(transport.requests.first), providers)
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Request

@MainActor @Test func chatGPTRequestsUseTheAccountTokenAndOnlyTheSIWCFields() async throws {
    let (updates, request, providers) = try await answer(completedStream)
    #expect(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: plan())) is ChatGPTAnswerProvider)
    #expect(updates.last == .ended(.finished, text: "A loop repeats [t1]."))
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.httpShouldHandleCookies == false)
    let body = try json(request)
    // The SIWC profile: all history in `input`, `store: false`, `stream: true`, the system prompt in `instructions`.
    #expect(Set(body.keys) == ["model", "instructions", "input", "stream", "store"])
    #expect(body["model"] as? String == "gpt-5")
    #expect(body["instructions"] as? String == "Answer from the lecture. [t1] Plan the course.")
    #expect(body["stream"] as? Bool == true)
    #expect(body["store"] as? Bool == false)
    let input = try #require(body["input"] as? [[String: String]])
    #expect(input == [["role": "user", "content": "Why?"], ["role": "assistant", "content": "Because."],
                      ["role": "user", "content": "What is a loop?"]])
    // No output limit, no tools and no other field that the subscription profile refuses.
    for field in ["max_output_tokens", "tools", "temperature", "top_p", "previous_response_id", "background", "conversation",
                  "metadata", "user", "truncation", "safety_identifier", "prompt_cache_retention"] {
        #expect(body[field] == nil, "\(field)")
    }
    // The token is only in the header.
    #expect(!(request.url?.absoluteString.contains(accessToken) ?? true))
    #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self).contains(accessToken))
}

@MainActor @Test func onlyAChatGPTPlanWithAModelAndTheDirectScopeSends() async throws {
    #expect(ChatGPTAnswerProvider.responsesRequest(messages, model: "gpt-5", accessToken: "") == nil)
    #expect(ChatGPTAnswerProvider.responsesRequest(messages, model: "gpt-5", accessToken: "a\r\nX-Other: 1") == nil)
    #expect(ChatGPTAnswerProvider.responsesRequest(messages, model: "", accessToken: accessToken) == nil)
    // No system message gives no instructions.
    let plain = try #require(ChatGPTAnswerProvider.responsesRequest([messages[3]], model: "gpt-5", accessToken: accessToken))
    #expect(try json(plain)["instructions"] == nil)

    // A profile with no model can't answer, and "Answer with" does not list it.
    let (providers, transport, _) = try signedIn(profile: plan(modelID: ""))
    #expect(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: plan())).prepare() == nil)
    // The chosen profile stays in the menu, so the picker keeps a selection.
    #expect(providers.answerProfiles(of: .subscription).map(\.id) == ["chatgpt"])
    let other = ProviderSettings(store: nil, credentials: MemoryCredentialStore(), profiles: [plan(modelID: "")],
                                 adapterKinds: ShippedAdapters.kinds)
    #expect(other.answerProfiles(of: .subscription).isEmpty)
    #expect(transport.requests.isEmpty)

    // A grant with no direct-use scope sends no inference.
    let (scoped, scopedTransport, _) = try signedIn(session(scopes: ["openid", "offline_access"]))
    let request = try #require(scoped.activeProvider(bundled: UnavailableAnswerProvider(profile: plan())).prepare()).ask(messages)
    #expect(await collect(request) == [.ended(.refused(reason: "ChatGPT access ended. Sign in again in Settings."), text: "")])
    #expect(scopedTransport.requests.isEmpty)
}

// MARK: - Stream and errors

@MainActor @Test func chatGPTStreamOutcomesMatchTheResponsesContract() async throws {
    for piece in [1, 7, 4096] {
        let updates = try await answer(completedStream, piece: piece).updates
        #expect(updates.last == .ended(.finished, text: "A loop repeats [t1]."), "\(piece)")
        let deltas = updates.compactMap { if case .delta(let text) = $0 { text } else { nil } }
        #expect(deltas == ["A loop", "A loop repeats [t1]."], "\(piece)")
    }
    // A stream that ends without `response.completed` is a failure.
    #expect(try await answer(head + delta("Half")).updates.last
        == .ended(.refused(reason: "The connection to ChatGPT stopped. Try again."), text: ""))
    #expect(try await answer(head + delta("Half"), end: URLError(.networkConnectionLost)).updates.last
        == .ended(.refused(reason: "The connection to ChatGPT stopped. Try again."), text: ""))
    #expect(try await answer(head + event("response.incomplete",
                                          #""response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#))
        .updates == [.ended(.incomplete, text: "")])
    #expect(try await answer(head + "data: {not json\n\n").updates
        == [.ended(.refused(reason: "ChatGPT sent data that Skillgarden can't read. Try again."), text: "")])
    // A failed response: the fixed text, never the message of the service.
    #expect(try await answer(failedStream("server_error")).updates.last
        == .ended(.refused(reason: "ChatGPT could not finish the answer. Try again."), text: ""))
    // The plan-limit code can come after the stream starts.
    let limit = try await answer(failedStream("subscription_sharing_usage_limit_exceeded"))
    #expect(limit.updates.last == .ended(.refused(reason: "You reached the ChatGPT plan limit. Try again later."), text: ""))
    #expect(limit.providers.expiredSessions.isEmpty)
    #expect(try await answer(event("error", #""code":"subscription_sharing_usage_limit_exceeded","message":"RAW""#)).updates
        == [.ended(.refused(reason: "You reached the ChatGPT plan limit. Try again later."), text: "")])
    // A revoked grant in the stream ends the session.
    let revoked = try await answer(failedStream("subscription_sharing_invalid_user"))
    #expect(revoked.updates.last == .ended(.refused(reason: "ChatGPT access ended. Sign in again in Settings."), text: ""))
    #expect(revoked.providers.expiredSessions == ["chatgpt"])
}

@MainActor @Test func chatGPTHTTPErrorsGiveThePlanLimitRevokedAndStatusText() async throws {
    let detail = #"{"detail":"RAW-DETAIL subscription_sharing_user_not_eligible"}"#
    let cases = [
        (429, "You reached the ChatGPT plan limit. Try again later."),
        (401, "ChatGPT access ended. Sign in again in Settings."),
        (503, "ChatGPT sent an error (503)."),
        (403, "ChatGPT sent an error (403)."),
        (400, "ChatGPT sent an error (400)."),
    ]
    for (status, text) in cases {
        let (updates, _, providers) = try await answer(status: status, detail)
        #expect(updates == [.ended(.refused(reason: text), text: "")], "\(status)")
        #expect(!text.contains("RAW") && !text.contains(accessToken))
        let turn = QATurnStatus(outcome: .refused(reason: text))
        #expect(turn.label == "No answer: \(text)")
        // Only the revoked grant shows "Open Settings…" and ends the session. A 503 keeps the tokens.
        #expect(turn.opensSettings == (status == 401), "\(status)")
        #expect(providers.expiredSessions == (status == 401 ? ["chatgpt"] : []), "\(status)")
        let saved = try #require(providers.savedChatGPTSession(for: "chatgpt"))
        #expect(saved.clientID == clientID)
        #expect(saved.accessToken.isEmpty == (status == 401), "\(status)")
    }
    // No response at all keeps the tokens.
    let (providers, transport, _) = try signedIn()
    let request = try #require(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: plan())).prepare()).ask(messages)
    await transport.next().finish(throwing: URLError(.notConnectedToInternet))
    #expect(await collect(request) == [.ended(.refused(reason: "Skillgarden can't connect to ChatGPT. Check the network."), text: "")])
    #expect(providers.expiredSessions.isEmpty && providers.savedChatGPTSession(for: "chatgpt")?.accessToken == accessToken)
}

@MainActor @Test func aRevokedRefreshClearsTheTokensAndANetworkFailureKeepsThem() async throws {
    for code in ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated",
                 "refresh_token_reused"] {
        let auth = ScriptedTransport()
        let (providers, transport, _) = try signedIn(session(expiresIn: -10),
                                                     authorizer: ChatGPTAuthorizer(transport: auth, hostIDs: MemoryCredentialStore()))
        let request = try #require(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: plan())).prepare()).ask(messages)
        play(await auth.next(), status: 400, #"{"error":"\#(code)"}"#)
        #expect(await collect(request) == [.ended(.refused(reason: "ChatGPT access ended. Sign in again in Settings."), text: "")],
                "\(code)")
        let saved = try #require(providers.savedChatGPTSession(for: "chatgpt"))
        #expect(saved.accessToken.isEmpty && saved.refreshToken == nil && saved.clientID == clientID, "\(code)")
        #expect(providers.expiredSessions == ["chatgpt"])
        // No inference without a valid session.
        #expect(transport.requests.isEmpty)
    }
    // A network failure or a 503 of the refresh keeps the tokens.
    for status in [nil, 503] as [Int?] {
        let auth = ScriptedTransport()
        let (providers, transport, _) = try signedIn(session(expiresIn: -10),
                                                     authorizer: ChatGPTAuthorizer(transport: auth, hostIDs: MemoryCredentialStore()))
        let request = try #require(providers.activeProvider(bundled: UnavailableAnswerProvider(profile: plan())).prepare()).ask(messages)
        if let status { play(await auth.next(), status: status, "{}") } else {
            await auth.next().finish(throwing: URLError(.notConnectedToInternet))
        }
        let text = status == nil ? "Skillgarden can't connect to ChatGPT. Check the network." : "ChatGPT sent an error (503)."
        #expect(await collect(request) == [.ended(.refused(reason: text), text: "")])
        #expect(providers.expiredSessions.isEmpty)
        #expect(providers.savedChatGPTSession(for: "chatgpt")?.refreshToken == "refresh-SECRET-1")
        #expect(transport.requests.isEmpty)
    }
}

@MainActor @Test func chatGPTCancelStopsAtOnceAndLateEventsChangeNothing() async throws {
    let (providers, transport, _) = try signedIn()
    let provider = providers.activeProvider(bundled: UnavailableAnswerProvider(profile: plan()))
    let request = try #require(provider.prepare()).ask(messages)
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    stream.yield(.data(Data((head + delta("A loop")).utf8)))
    var updates = request.updates.makeAsyncIterator()
    #expect(await updates.next() == .delta(text: "A loop"))
    provider.cancel(request.id)
    #expect(await updates.next() == .ended(.canceled, text: "A loop"))
    #expect(await updates.next() == nil)
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

    // Cancel during the token refresh ends at once and sends nothing.
    let auth = ScriptedTransport()
    let (expired, expiredTransport, _) = try signedIn(session(expiresIn: -10),
                                                      authorizer: ChatGPTAuthorizer(transport: auth, hostIDs: MemoryCredentialStore()))
    let refreshing = expired.activeProvider(bundled: UnavailableAnswerProvider(profile: plan()))
    let waiting = try #require(refreshing.prepare()).ask(messages)
    let refresh = await auth.next()
    refreshing.cancel(waiting.id)
    #expect(await collect(waiting) == [.ended(.canceled, text: "")])
    refresh.finish(throwing: URLError(.cancelled))
    #expect(expiredTransport.requests.isEmpty)
}

// MARK: - Model list

@MainActor @Test func theModelListShowsOnlyListedModelsInServerOrder() async throws {
    let (providers, transport, _) = try signedIn()
    let task = Task { await providers.chatGPTModels(for: "chatgpt") }
    play(await transport.next(), #"""
    {"models":[{"slug":"gpt-5","display_name":"GPT-5","visibility":"list"},
               {"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide"},
               {"slug":"gpt-5-mini","display_name":"GPT-5 mini","visibility":"list"},
               {"slug":"o-plain","visibility":"list"},
               {"slug":"gpt-5","display_name":"Again","visibility":"list"}]}
    """#)
    #expect(try await task.value.get() == [ChatGPTModel(slug: "gpt-5", displayName: "GPT-5"),
                                           ChatGPTModel(slug: "gpt-5-mini", displayName: "GPT-5 mini"),
                                           ChatGPTModel(slug: "o-plain", displayName: "o-plain")])
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)")

    // Errors give the design-note text. A revoked grant ends the session.
    for (status, body, text) in [(429, "{}", "You reached the ChatGPT plan limit. Try again later."),
                                 (503, #"{"detail":"RAW"}"#, "ChatGPT sent an error (503)."),
                                 (200, "not json", "ChatGPT sent data that Skillgarden can't read. Try again."),
                                 (401, "{}", "ChatGPT access ended. Sign in again in Settings.")] {
        let (failing, failingTransport, _) = try signedIn()
        let result = Task { await failing.chatGPTModels(for: "chatgpt") }
        play(await failingTransport.next(), status: status, body)
        #expect(await result.value == .failure(ChatGPTModelsFailure(reason: text)), "\(status)")
        #expect(failing.expiredSessions == (status == 401 ? ["chatgpt"] : []), "\(status)")
    }
    let (offline, offlineTransport, _) = try signedIn()
    let result = Task { await offline.chatGPTModels(for: "chatgpt") }
    await offlineTransport.next().finish(throwing: URLError(.notConnectedToInternet))
    #expect(await result.value == .failure(ChatGPTModelsFailure(reason: "Skillgarden can't connect to ChatGPT. Check the network.")))
}

@MainActor @Test func theSignedInSheetLoadsModelsAndSavesTheChoice() async throws {
    let (providers, transport, _) = try signedIn(profile: plan(modelID: ""))
    try providers.allow(courseID: "c", destination: try #require(providers.profiles.first).destination)
    let signIn = ChatGPTSignIn(providers: providers, browser: nil, state: .signedIn(ChatGPTAccount(email: nil, planType: nil)))
    #expect(signIn.models == .notLoaded && !signIn.canSave)
    let load = Task { await signIn.loadModelsIfNeeded() }
    let stream = await transport.next()
    #expect(signIn.models == .loading)
    play(stream, #"{"models":[{"slug":"gpt-5","display_name":"GPT-5","visibility":"list"},{"slug":"gpt-5-mini","visibility":"list"}]}"#)
    await load.value
    // The default is the first model of the list.
    #expect(signIn.models == .loaded([ChatGPTModel(slug: "gpt-5", displayName: "GPT-5"),
                                      ChatGPTModel(slug: "gpt-5-mini", displayName: "gpt-5-mini")]))
    #expect(signIn.modelID == "gpt-5" && signIn.canSave && signIn.missingModelText == nil)
    // A second open does not load again.
    await signIn.loadModelsIfNeeded()
    #expect(transport.requests.count == 1)
    signIn.modelID = "gpt-5-mini"
    #expect(signIn.save() == nil)
    let saved = try #require(providers.profiles.first)
    #expect(saved.modelID == "gpt-5-mini" && saved.title == "ChatGPT Plan · gpt-5-mini")
    // A new model needs a new course consent.
    #expect(providers.consents.isEmpty)
    #expect(providers.answerProfiles(of: .subscription).map(\.id) == ["chatgpt"])

    // A saved model that left the list shows the red caption, and "Save" is off.
    let later = ChatGPTSignIn(providers: providers, browser: nil, state: .signedIn(ChatGPTAccount(email: nil, planType: nil)))
    #expect(later.modelID == "gpt-5-mini")
    let reload = Task { await later.loadModels() }
    play(await transport.next(), #"{"models":[{"slug":"gpt-5","display_name":"GPT-5","visibility":"list"}]}"#)
    await reload.value
    #expect(later.missingModelText == "gpt-5-mini is no longer available. Choose a model.")
    #expect(!later.canSave)
    // An empty list: "Save" is off. An error keeps "Save" off too.
    let empty = Task { await later.loadModels() }
    play(await transport.next(), #"{"models":[]}"#)
    await empty.value
    #expect(later.models == .loaded([]) && !later.canSave)
    let failing = Task { await later.loadModels() }
    play(await transport.next(), status: 503, "{}")
    await failing.value
    #expect(later.models == .failed("ChatGPT sent an error (503).") && !later.canSave)
    // A sheet that is not signed in loads nothing.
    let signedOut = ChatGPTSignIn(providers: providers, browser: nil)
    await signedOut.loadModelsIfNeeded()
    #expect(signedOut.models == .notLoaded && transport.requests.count == 4)
    #expect(ChatGPTSignIn.loadingModelsText == "Loading models…")
    #expect(ChatGPTSignIn.noModelsText == "This plan has no models for Skillgarden.")
}

// MARK: - Settings, consent and Q&A

@MainActor @Test func chatGPTPlanTextMatchesTheDesignNotes() throws {
    let (providers, _, _) = try signedIn()
    let profile = try #require(providers.selected)
    #expect(providers.caption(for: profile) == "learner@example.com · Subscription")
    #expect(profile.title == "ChatGPT Plan · gpt-5")
    #expect(profile.answerFooter == "Answers come from ChatGPT and can be wrong.")
    let provider = providers.activeProvider(bundled: UnavailableAnswerProvider(profile: profile))
    #expect(provider.displayName == "ChatGPT Plan (OpenAI)" && provider.kind == .subscription)
    #expect(provider.destination == RemoteDestination(profileID: "chatgpt", kind: .subscription, host: "api.openai.com",
                                                      modelID: "gpt-5"))
    // A ChatGPT plan never falls back to an API key adapter.
    #expect(ShippedAdapters.provider(for: profile, credentials: MemoryCredentialStore()) == nil)
}

@MainActor @Test func chatGPTQuestionsAskConsentThenSaveTheSameTurnsAndCitationsAsTheAPIKeyPath() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ChatGPTProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaEmpty, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))

    let (providers, transport, _) = try signedIn(store: ProviderSettingsStore(directory: root))
    let qa = LectureQA(library: library, provider: UnavailableAnswerProvider(profile: plan()), providers: providers,
                       draftInterval: .zero)
    qa.show(LectureQA.key(library: library))
    await qa.load()
    #expect(qa.provider is ChatGPTAnswerProvider)

    // No request before the course consent. The sheet names the plan and its limits.
    #expect(!qa.send("What is the goal of this course?"))
    let consent = try #require(qa.consentRequest)
    #expect(consent.title == "Send this question to OpenAI?")
    #expect(consent.providerName == "ChatGPT Plan (OpenAI)")
    #expect(consent.cloudNote == "Use of your plan counts toward its limits.")
    #expect(transport.requests.isEmpty)
    #expect(qa.allowAndSend())
    play(await transport.next(), completedStream)
    await qa.waitForRequest()
    let body = try json(try #require(transport.requests.first))
    #expect((body["instructions"] as? String)?.contains("t0") == true)
    let finished = try #require(qa.conversation.turns.last)
    #expect(finished.status == .complete && finished.answer == "A loop repeats [t1].")
    #expect(finished.origin == AnswerOrigin(providerID: "chatgpt", modelID: "gpt-5"))
    #expect(providers.sourceText(for: finished.origin) == "via ChatGPT Plan · gpt-5")
    // The citations come from the answer and the lecture text only, as for the API-key path.
    let context = try #require({ if case .ready(let value) = $0 { value } else { nil } }(await library.lectureContext(forLecture: "welcome")))
    #expect(qa.citations(for: finished) == AnswerCitations(answer: finished.answer, context: context, isStale: false))

    // A plan limit: the turn has the fixed text and Retry, and no "Open Settings…".
    #expect(qa.send("And then?"))
    play(await transport.next(), status: 429, #"{"detail":"RAW"}"#)
    await qa.waitForRequest()
    let limited = try #require(qa.conversation.turns.last)
    #expect(limited.status == .failed(reason: "You reached the ChatGPT plan limit. Try again later."))
    #expect(!limited.status.opensSettings && qa.conversation.canRetry(limited))

    // Cancel keeps the partial answer. Late text does not change the saved turn.
    #expect(qa.send("How does the course start?"))
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    stream.yield(.data(Data((head + delta("It starts")).utf8)))
    while qa.draft?.text != "It starts" { await Task.yield() }
    qa.cancel()
    stream.yield(.data(Data((delta(" late.") + event("response.completed", #""response":{"status":"completed"}"#)).utf8)))
    stream.finish()
    await qa.waitForRequest()
    let cancelled = try #require(qa.conversation.turns.last)
    #expect(cancelled.status == .cancelled && cancelled.answer == "It starts")

    // A revoked grant: "Open Settings…", and the next question gets the same text with no request.
    #expect(qa.send("Why?"))
    play(await transport.next(), status: 401, "{}")
    await qa.waitForRequest()
    let revoked = try #require(qa.conversation.turns.last)
    #expect(revoked.status == .failed(reason: "ChatGPT access ended. Sign in again in Settings.") && revoked.status.opensSettings)
    #expect(qa.send("Why again?"))
    await qa.waitForRequest()
    #expect(qa.conversation.turns.last?.status == .failed(reason: "ChatGPT access ended. Sign in again in Settings."))
    #expect(transport.requests.count == 4)
}

@MainActor @Test func providerFilesWithAChatGPTPlanSavedBeforeThisChangeStillLoad() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ChatGPTProviderTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    // A #156 file: a ChatGPT plan profile with no model and its course consent.
    try Data("""
    {"version": 1, "selectedID": "bundled-local",
     "profiles": [{"id": "chatgpt", "kind": "subscription", "name": "ChatGPT Plan", "vendor": "OpenAI",
                   "origin": "https://api.openai.com", "modelID": "", "credentialReference": "chatgpt"}],
     "consents": [{"courseID": "c", "allowedAt": 0,
                   "destination": {"profileID": "chatgpt", "kind": "subscription", "host": "api.openai.com", "modelID": ""}}]}
    """.utf8).write(to: store.fileURL)
    let credentials = MemoryCredentialStore(secrets: ["chatgpt": session().keychainText])
    let providers = ProviderSettings(store: store, credentials: credentials, adapterKinds: ShippedAdapters.kinds)
    let profile = try #require(providers.profiles.first)
    #expect(profile.isChatGPTPlan && profile.modelID.isEmpty && providers.selectedID == BundledAnswerProvider.providerID)
    #expect(providers.answerProfiles(of: .subscription).isEmpty)
    providers.checkCredentials()
    #expect(providers.accounts["chatgpt"]?.email == "learner@example.com" && providers.expiredSessions.isEmpty)
    // A model choice saves the profile and lists it in "Answer with".
    try providers.saveChatGPTModel("gpt-5", for: "chatgpt")
    providers.select("chatgpt")
    let reloaded = ProviderSettings(store: store, credentials: credentials, adapterKinds: ShippedAdapters.kinds)
    #expect(reloaded.selected?.modelID == "gpt-5" && reloaded.selectedID == "chatgpt")
    #expect(reloaded.consents.isEmpty)
}

@MainActor @Test func aPlanWithNoModelAsksForAModel() throws {
    // #232: a plan signed in before #157 has no model, so "Answer with" hides it. The row must say why.
    let credentials = MemoryCredentialStore(secrets: ["chatgpt": session().keychainText])
    let profile = ProviderProfile(id: "chatgpt", kind: .subscription, name: "ChatGPT Plan", vendor: "OpenAI",
                                  origin: "https://api.openai.com", modelID: "", credentialReference: "chatgpt")
    let providers = ProviderSettings(store: nil, credentials: credentials, profiles: [profile], adapterKinds: ShippedAdapters.kinds)
    providers.checkCredentials()
    #expect(providers.answerProfiles(of: .subscription).isEmpty)
    #expect(providers.redCaption(for: profile) == "Choose a model to use this plan for Q&A.")
    #expect(providers.needsModel(profile) && !providers.needsSignIn(profile))
    // A model choice clears the caption and lists the plan in "Answer with".
    try providers.saveChatGPTModel("gpt-5", for: "chatgpt")
    let saved = try #require(providers.profiles.first)
    #expect(providers.redCaption(for: saved) == nil && !providers.needsModel(saved))
    #expect(providers.answerProfiles(of: .subscription).map(\.id) == ["chatgpt"])
}

@MainActor @Test func aPlanRowShowsOneRedCaptionInOrder() throws {
    let profile = ProviderProfile(id: "chatgpt", kind: .subscription, name: "ChatGPT Plan", vendor: "OpenAI",
                                  origin: "https://api.openai.com", modelID: "", credentialReference: "chatgpt")
    // A credential problem comes first.
    let denied = ProviderSettings(store: nil, credentials: MemoryCredentialStore(deniedAccounts: ["chatgpt"]),
                                  profiles: [profile], adapterKinds: ShippedAdapters.kinds)
    denied.checkCredentials()
    #expect(denied.redCaption(for: profile) == denied.problems["chatgpt"]?.message && denied.redCaption(for: profile) != nil)
    #expect(!denied.needsModel(profile) && !denied.needsSignIn(profile))
    // A session that can't refresh comes before the model.
    let expired = ProviderSettings(store: nil, credentials: MemoryCredentialStore(secrets: ["chatgpt": "not json"]),
                                   profiles: [profile], adapterKinds: ShippedAdapters.kinds)
    expired.checkCredentials()
    #expect(expired.redCaption(for: profile) == ProviderSettings.signInAgainText)
    #expect(!expired.needsModel(profile) && expired.needsSignIn(profile))
    // A subscription with no adapter already says "Q&A not available yet", so it does not ask for a model.
    let noAdapter = ProviderSettings(store: nil, credentials: MemoryCredentialStore(secrets: ["chatgpt": session().keychainText]),
                                     profiles: [profile], adapterKinds: [.externalLocal, .api])
    noAdapter.checkCredentials()
    #expect(noAdapter.redCaption(for: profile) == nil && !noAdapter.needsModel(profile))
    // An API profile with no model is out of scope: its sheet asks for the model.
    let api = ProviderProfile(id: "openai", kind: .api, name: "OpenAI API", vendor: "OpenAI", origin: "https://api.openai.com",
                              modelID: "", credentialReference: "openai")
    let apiSettings = ProviderSettings(store: nil, credentials: MemoryCredentialStore(secrets: ["openai": "sk-1"]),
                                       profiles: [api], adapterKinds: ShippedAdapters.kinds)
    apiSettings.checkCredentials()
    #expect(apiSettings.redCaption(for: api) == nil && !apiSettings.needsModel(api))
}

@Test func docsDescribeTheChatGPTPlanPath() throws {
    let doc = try String(contentsOf: repo.appending(path: "docs/local-ai.md"), encoding: .utf8)
    #expect(doc.contains("ChatGPT plan (#157)"))
    #expect(doc.contains("https://api.openai.com/v1/models"))
}
