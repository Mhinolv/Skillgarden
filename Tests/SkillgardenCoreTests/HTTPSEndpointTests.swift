import Foundation
import Testing
@testable import SkillgardenCore

// #155: OpenRouter and custom HTTPS endpoints through the compatible adapter. No test needs the network.

private let question = [ChatMessage(role: .user, content: "What is a loop?")]
private let key = "sk-or-test-0123456789"

private func openRouter(upstreams: [String] = ["openai"], allowsFallback: Bool = false, allowsDataCollection: Bool = false,
                        credentialReference: String? = "or") -> ProviderProfile {
    ProviderProfile(id: "or", kind: .api, name: "OpenRouter", vendor: "OpenRouter", origin: CompatibleEndpoint.openRouterBaseURL,
                    modelID: "openai/gpt-5", credentialReference: credentialReference, endpoint: .openRouter,
                    routing: OpenRouterRouting(upstreams: upstreams, allowsFallback: allowsFallback,
                                               allowsDataCollection: allowsDataCollection))
}

private func custom(origin: String = "https://gateway.example.com/v1", credentialReference: String? = nil) -> ProviderProfile {
    ProviderProfile(id: "custom", kind: .api, name: "Team Gateway", vendor: "Team Gateway", origin: origin, modelID: "llama-3.3-70b",
                    credentialReference: credentialReference, endpoint: .custom)
}

/// An OpenRouter stream: a processing comment, a role chunk with text, a comment between events, a finish chunk, `[DONE]`.
private let openRouterStream = """
: OPENROUTER PROCESSING

: OPENROUTER PROCESSING

data: {"id":"gen-1","provider":"OpenAI","model":"openai/gpt-5","object":"chat.completion.chunk","created":1,"choices":[{"index":0,"delta":{"role":"assistant","content":"A loop"},"finish_reason":null}]}

: OPENROUTER PROCESSING
data: {"id":"gen-1","provider":"OpenAI","model":"openai/gpt-5","object":"chat.completion.chunk","created":1,"choices":[{"index":0,"delta":{"content":" repeats [t1]."},"finish_reason":null}]}

data: {"id":"gen-1","provider":"OpenAI","model":"openai/gpt-5","object":"chat.completion.chunk","created":1,"choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":4}}

data: [DONE]


"""

/// Sends one fixed response for each request and keeps each request.
private final class CannedTransport: LlamaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private let status: Int?
    private let body: String
    private let piece: Int
    private let end: (any Error)?

    init(status: Int? = 200, _ body: String = "", piece: Int = 7, end: (any Error)? = nil) {
        self.status = status
        self.body = body
        self.piece = piece
        self.end = end
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        lock.withLock { sent.append(request) }
        let (status, bytes, piece, end) = (status, Array(body.utf8), piece, end)
        return AsyncThrowingStream { continuation in
            if let status { continuation.yield(.response(status: status)) }
            for start in stride(from: 0, to: bytes.count, by: piece) {
                continuation.yield(.data(Data(bytes[start..<min(start + piece, bytes.count)])))
            }
            continuation.finish(throwing: end)
        }
    }
}

/// One answer of `profile` with `credentials` on `transport`.
@MainActor
private func answer(_ profile: ProviderProfile, credentials: MemoryCredentialStore = MemoryCredentialStore(secrets: ["or": key]),
                    transport: CannedTransport) async throws -> [AnswerUpdate] {
    let provider = try #require(ShippedAdapters.provider(for: profile, credentials: credentials) as? CompatibleAnswerProvider)
    #expect(provider.kind == .api)
    let adapter = CompatibleAnswerProvider(profile: profile, credentials: credentials, transport: transport)
    let prepared = try #require(adapter.prepare())
    var updates: [AnswerUpdate] = []
    for await update in prepared.ask(question).updates { updates.append(update) }
    return updates
}

private func body(_ request: URLRequest?) throws -> [String: Any] {
    let data = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - One adapter

@MainActor @Test func openRouterAndCustomEndpointsShareTheCompatibleAdapter() async throws {
    #expect(ShippedAdapters.provider(for: openRouter(), credentials: MemoryCredentialStore()) is CompatibleAnswerProvider)
    #expect(ShippedAdapters.provider(for: custom(), credentials: MemoryCredentialStore()) is CompatibleAnswerProvider)
    // A custom endpoint with the name and host of a fixed service is never that service.
    var lookalike = custom(origin: "https://api.openai.com")
    lookalike.vendor = "OpenAI"
    #expect(lookalike.apiService == nil)
    #expect(ShippedAdapters.provider(for: lookalike, credentials: MemoryCredentialStore()) is CompatibleAnswerProvider)

    // OpenRouter: the fixed URL, the key in the header only, and the routing of the profile.
    let transport = CannedTransport(openRouterStream)
    let updates = try await answer(openRouter(upstreams: ["openai", "anthropic"]), transport: transport)
    #expect(updates.last == .ended(.finished, text: "A loop repeats [t1]."))
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
    #expect(!request.httpShouldHandleCookies)
    let sent = try body(request)
    #expect(sent["model"] as? String == "openai/gpt-5")
    #expect(sent["stream"] as? Bool == true)
    let provider = try #require(sent["provider"] as? [String: Any])
    #expect(provider["order"] as? [String] == ["openai", "anthropic"])
    #expect(provider["only"] as? [String] == ["openai", "anthropic"])
    #expect(provider["allow_fallbacks"] as? Bool == false)
    #expect(provider["data_collection"] as? String == "deny")
    #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(key))

    // Custom: the normalized URL, no key header when the profile has no key, and no OpenRouter routing.
    let plain = CannedTransport(openRouterStream)
    _ = try await answer(custom(origin: "https://gateway.example.com/v1/"), transport: plain)
    let customRequest = try #require(plain.requests.first)
    #expect(customRequest.url?.absoluteString == "https://gateway.example.com/v1/chat/completions")
    #expect(customRequest.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(try body(customRequest)["provider"] == nil)
    // Custom with a saved key.
    let keyed = CannedTransport(openRouterStream)
    _ = try await answer(custom(credentialReference: "custom"), credentials: MemoryCredentialStore(secrets: ["custom": "gw-key"]),
                         transport: keyed)
    #expect(keyed.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer gw-key")
}

@Test func customBaseURLsAreNormalizedAndOnlyHTTPS() {
    let cases: [(String, String)] = [
        ("https://example.com/v1", "https://example.com/v1/chat/completions"),
        ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
        ("https://example.com/v1/v1", "https://example.com/v1/chat/completions"),
        ("https://example.com//v1///", "https://example.com/v1/chat/completions"),
        ("https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions"),
        ("https://example.com", "https://example.com/v1/chat/completions"),
        ("  HTTPS://example.com:8443/openai/v1  ", "https://example.com:8443/openai/v1/chat/completions"),
        ("https://api.groq.com/openai/v1", "https://api.groq.com/openai/v1/chat/completions"),
    ]
    for (origin, expected) in cases {
        let profile = custom(origin: origin)
        #expect(profile.chatCompletionsURL?.absoluteString == expected, "\(origin)")
        #expect(profile.requestURLCaption == "Requests go to \(expected)", "\(origin)")
        #expect(profile.originProblem == nil, "\(origin)")
        #expect(profile.isValid(hasSecret: false), "\(origin)")
    }
    let notHTTPS = ["http://example.com/v1", "http://127.0.0.1:1234/v1", "ftp://example.com", "example.com/v1", "",
                    "https://", "https://example.com/v1?x=1", "https://example.com/v1#x", "https://example.com:0/v1"]
    for origin in notHTTPS {
        let profile = custom(origin: origin)
        #expect(profile.chatCompletionsURL == nil, "\(origin)")
        #expect(profile.requestURLCaption == nil, "\(origin)")
        #expect(profile.originProblem == "Use an https:// URL.", "\(origin)")
        #expect(!profile.isValid(hasSecret: true), "\(origin)")
    }
    for origin in ["https://user:pass@example.com/v1", "https://user@example.com/v1"] {
        #expect(custom(origin: origin).originProblem == "Remove the user name and password from the URL.", "\(origin)")
        #expect(custom(origin: origin).chatCompletionsURL == nil)
    }
    // OpenRouter sends only to its fixed URL.
    var moved = openRouter()
    moved.origin = "https://evil.example.com/api/v1"
    #expect(moved.chatCompletionsURL == nil)
    #expect(CompatibleAnswerProvider.chatRequest(question, profile: moved, token: key) == nil)
}

// MARK: - OpenRouter defaults

@MainActor @Test func openRouterPresetHasNoFallbackByDefault() async throws {
    let preset = ProviderProfile.preset(.openRouter)
    #expect(preset.kind == .api && preset.endpoint == .openRouter)
    #expect(preset.name == "OpenRouter" && preset.vendor == "OpenRouter")
    #expect(preset.host == "openrouter.ai")
    #expect(preset.routing == OpenRouterRouting(upstreams: [], allowsFallback: false, allowsDataCollection: false))
    #expect(preset.routing?.dataPolicyText == "Deny data collection")
    #expect(preset.upstreamProblem == "Enter at least one upstream provider.")
    #expect(preset.modelProblem == "Enter the model ID.")
    var filled = preset
    filled.modelID = "openai/gpt-5"
    #expect(!filled.isValid(hasSecret: true))
    filled.routing?.upstreams = OpenRouterRouting.upstreams(from: " OpenAI, ,anthropic , openai,")
    #expect(filled.routing?.upstreams == ["openai", "anthropic"])
    #expect(filled.upstreamProblem == nil)
    // OpenRouter needs a key. A custom endpoint does not.
    #expect(!filled.isValid(hasSecret: false))
    #expect(filled.isValid(hasSecret: true))
    #expect(CompatibleAnswerProvider.chatRequest(question, profile: filled, token: nil) == nil)
    #expect(await CompatibleAnswerProvider.testConnection(filled, token: nil, transport: CannedTransport())
        == .failed(reason: "Enter an API key."))
    #expect(await CompatibleAnswerProvider.testConnection(preset, token: key, transport: CannedTransport())
        == .failed(reason: "Enter at least one upstream provider."))
    let customPreset = ProviderProfile.preset(.custom)
    #expect(customPreset.endpoint == .custom && customPreset.routing == nil && customPreset.origin.isEmpty)
    #expect(CompatibleEndpoint.allCases.map(\.menuTitle) == ["OpenRouter…", "Custom HTTPS Endpoint…"])

    // The learner can turn fallback on. Then `only` goes, so OpenRouter can use other upstreams.
    let transport = CannedTransport(openRouterStream)
    _ = try await answer(openRouter(allowsFallback: true, allowsDataCollection: true), transport: transport)
    let provider = try #require(try body(transport.requests.first)["provider"] as? [String: Any])
    #expect(provider["allow_fallbacks"] as? Bool == true)
    #expect(provider["only"] == nil)
    #expect(provider["order"] as? [String] == ["openai"])
    #expect(provider["data_collection"] as? String == "allow")
}

// MARK: - Consent and keys

@MainActor @Test func originOrUpstreamChangeClearsConsentForTheCourses() throws {
    let credentials = MemoryCredentialStore()
    let providers = ProviderSettings(store: nil, credentials: credentials, adapterKinds: [.api])
    try providers.save(openRouter(credentialReference: nil), secret: key)
    let saved = try #require(providers.profiles.first)
    try providers.allow(courseID: "a", destination: saved.destination)
    try providers.allow(courseID: "b", destination: saved.destination)
    #expect(providers.consents.count == 2)

    // A new model ID or name keeps nothing else, as before. The same upstreams with no other change keep the consent.
    var renamed = saved
    renamed.name = "OpenRouter (work)"
    #expect(!providers.changesDestination(renamed))
    try providers.save(renamed, secret: nil)
    #expect(providers.consents.count == 2)

    // A new upstream list asks first, then clears the consent of each course.
    var upstream = renamed
    upstream.routing?.upstreams = ["anthropic"]
    #expect(providers.changesDestination(upstream))
    try providers.save(upstream, secret: nil)
    #expect(providers.consents.isEmpty)
    #expect(!providers.hasConsent(courseID: "a", destination: upstream.destination))
    // The OpenRouter key stays, because the host did not change.
    #expect(try credentials.secret(account: upstream.keychainAccount) == key)
    #expect(providers.hasSecret(upstream))

    // The fallback and the data policy are in the consent too, so a change asks each course again.
    try providers.allow(courseID: "a", destination: upstream.destination)
    var fallback = upstream
    fallback.routing?.allowsFallback = true
    #expect(!providers.changesDestination(fallback))
    try providers.save(fallback, secret: nil)
    #expect(providers.consents.isEmpty)

    // A custom endpoint on a new host asks first and clears the consent. The old key does not go to the new host.
    try providers.save(custom(), secret: "gw-key")
    let gateway = try #require(providers.profiles.first { $0.id == "custom" })
    try providers.allow(courseID: "a", destination: gateway.destination)
    var samePath = gateway
    samePath.origin = "https://gateway.example.com/v1/"
    #expect(!providers.changesDestination(samePath))
    #expect(providers.hasSecret(samePath))
    var moved = gateway
    moved.origin = "https://other.example.net/v1"
    #expect(providers.changesDestination(moved))
    #expect(!providers.hasSecret(moved))
    try providers.save(moved, secret: nil)
    #expect(!providers.consents.contains { $0.destination.profileID == "custom" })
    let after = try #require(providers.profiles.first { $0.id == "custom" })
    #expect(after.credentialReference == nil)
    #expect(try credentials.secret(account: gateway.keychainAccount) == nil)
    // A new profile is never a destination change.
    var fresh = ProviderProfile.preset(.custom)
    fresh.origin = "https://new.example.org/v1"
    #expect(!providers.changesDestination(fresh))
    #expect(!providers.changesDestination(ProviderProfile.preset(.openRouter)))
}

@MainActor @Test func theConsentSheetNamesOpenRouterAndTheUpstream() throws {
    let context = LectureContext(courseTitle: "Course", lectureTitle: "Lecture",
                                 passages: [LecturePassage(id: "t0", label: "0:00", text: "Text.")])
    let prompt = LecturePrompt(passages: context.passages, systemPrompt: "System.",
                               messages: [ChatMessage(role: .system, content: "System."), ChatMessage(role: .user, content: "Why?")],
                               isPartial: false, noEvidence: false)
    let request = RemoteConsentRequest(courseID: "c", question: "Why?", providerName: "OpenRouter",
                                       destination: openRouter(upstreams: ["openai", "anthropic"]).destination,
                                       vendor: "OpenRouter", context: context, prompt: prompt)
    #expect(request.title == "Send this question to OpenRouter?")
    #expect(request.providerName == "OpenRouter, then openai, anthropic")
    #expect(request.destination.host == "openrouter.ai")
    #expect(request.routingRows.map(\.label) == ["Data policy", "Fallback"])
    #expect(request.routingRows.map(\.value) == ["Deny data collection", "Off"])
    #expect(request.cloudNote == nil)
    let gateway = RemoteConsentRequest(courseID: "c", question: "Why?", providerName: "Team Gateway",
                                       destination: custom().destination, vendor: "Team Gateway", context: context, prompt: prompt)
    #expect(gateway.providerName == "Team Gateway")
    #expect(gateway.routingRows.isEmpty)
    #expect(openRouter().title == "OpenRouter · openai/gpt-5")
    #expect(openRouter().answerFooter == "Answers come from OpenRouter and can be wrong.")
    #expect(custom().title == "Team Gateway · llama-3.3-70b")
    #expect(openRouter().caption == "openrouter.ai · openai/gpt-5 · API")
}

// MARK: - Adapter errors

@MainActor @Test func redirectsAreRefusedAndNeverFollowed() async throws {
    for status in [301, 302, 307, 308] {
        let transport = CannedTransport(status: status, "<html>moved to https://evil.example.com</html>")
        let updates = try await answer(openRouter(), transport: transport)
        #expect(updates == [.ended(.refused(reason: "The server tried to redirect. Skillgarden stopped the request."), text: "")],
                "\(status)")
        #expect(transport.requests.count == 1)
    }
    let custom302 = CannedTransport(status: 302)
    #expect(try await answer(custom(), transport: custom302)
        == [.ended(.refused(reason: ExternalServerErrors.redirectText), text: "")])
}

@MainActor @Test func commentsInTheStreamAreSkipped() async throws {
    // Each cut of the bytes gives the same answer: the comments never show and never end the answer.
    for piece in [1, 3, 7, 4096] {
        let updates = try await answer(openRouter(), transport: CannedTransport(openRouterStream, piece: piece))
        #expect(updates == [.delta(text: "A loop"), .delta(text: "A loop repeats [t1]."),
                            .ended(.finished, text: "A loop repeats [t1].")], "piece \(piece)")
    }
    // A stream of comments only, with no event, is an empty answer.
    let quiet = try await answer(custom(), transport: CannedTransport(": OPENROUTER PROCESSING\n\n: ping\r\n\r\n"))
    #expect(quiet == [.ended(.empty, text: "")])
}

@MainActor @Test func aKeyForAnotherOriginGets401AndTheOldKeyNeverMoves() async throws {
    // The server refuses the key: the text names the host and never the body or the key.
    let refused = try await answer(openRouter(), transport: CannedTransport(status: 401, #"{"error":{"message":"No auth \#(key)"}}"#))
    #expect(refused == [.ended(.refused(reason: "openrouter.ai did not accept the API key."), text: "")])
    let wrongHost = try await answer(custom(origin: "https://other.example.net/v1", credentialReference: "custom"),
                                     credentials: MemoryCredentialStore(secrets: ["custom": "gw-key"]),
                                     transport: CannedTransport(status: 401))
    #expect(wrongHost == [.ended(.refused(reason: "other.example.net did not accept the API key."), text: "")])

    // "Test Connection" after a host change sends no saved key to the new host. A typed key goes.
    var tokens: [String?] = []
    let providers = ProviderSettings(store: nil, credentials: MemoryCredentialStore(), adapterKinds: [.api],
                                     testConnection: { _, token in tokens.append(token); return .connected })
    try providers.save(custom(), secret: "gw-key")
    var moved = try #require(providers.profiles.first)
    #expect(await providers.test(moved, secret: nil) == .connected)
    moved.origin = "https://other.example.net/v1"
    #expect(await providers.test(moved, secret: nil) == .connected)
    #expect(await providers.test(moved, secret: "new-key") == .connected)
    #expect(tokens == ["gw-key", nil, "new-key"])
    // Save with a new key binds the new key to the new host.
    try providers.save(moved, secret: "new-key")
    #expect(providers.hasSecret(try #require(providers.profiles.first)))
}

@MainActor @Test func remoteErrorsNameTheHost() async throws {
    let secretBody = "SECRET-BODY-TEXT"
    func reason(_ status: Int) async throws -> [AnswerUpdate] {
        try await answer(openRouter(), transport: CannedTransport(status: status, #"{"error":{"message":"\#(secretBody)"}}"#))
    }
    #expect(try await reason(429) == [.ended(.refused(reason: "openrouter.ai rate limit or quota reached. Try again later."), text: "")])
    for status in [400, 402, 403, 500, 502] {
        #expect(try await reason(status) == [.ended(.refused(reason: "openrouter.ai sent an error (\(status))."), text: "")], "\(status)")
    }
    #expect(try await reason(404) == [.ended(.refused(reason: "The server has no model \"openai/gpt-5\"."), text: "")])
    // An error event in the stream.
    let inStream = try await answer(openRouter(), transport: CannedTransport(
        "data: {\"choices\":[{\"delta\":{\"content\":\"Half\"}}]}\n\ndata: {\"error\":{\"code\":502,\"message\":\"\(secretBody)\"}}\n\n"))
    #expect(inStream == [.delta(text: "Half"), .ended(.refused(reason: "openrouter.ai sent an error (502)."), text: "")])
    // No response, a lost connection and unreadable data.
    #expect(try await answer(openRouter(), transport: CannedTransport(status: nil, end: URLError(.cannotConnectToHost)))
        == [.ended(.refused(reason: "Skillgarden can't connect to openrouter.ai. Check the network."), text: "")])
    #expect(try await answer(openRouter(), transport: CannedTransport("data: {\"choices\":[{\"delta\":{\"content\":\"Half\"}}]}\n\n",
                                                                      end: URLError(.networkConnectionLost)))
        == [.delta(text: "Half"), .ended(.refused(reason: "The connection to openrouter.ai stopped. Try again."), text: "")])
    #expect(try await answer(openRouter(), transport: CannedTransport("data: not json\n\n"))
        == [.ended(.refused(reason: "openrouter.ai sent data that Skillgarden can't read. Try again."), text: "")])
}

// MARK: - Saved files

@MainActor @Test func providerFilesSavedBeforeOpenRouterStillLoad() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HTTPSEndpointTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    // A #157 file: an OpenAI API profile with its consent, and no endpoint or routing keys.
    try Data("""
    {"version": 1, "selectedID": "openai",
     "profiles": [{"id": "openai", "kind": "api", "name": "OpenAI API", "vendor": "OpenAI",
                   "origin": "https://api.openai.com", "modelID": "gpt-5", "credentialReference": "openai"}],
     "consents": [{"courseID": "c", "allowedAt": 0,
                   "destination": {"profileID": "openai", "kind": "api", "host": "api.openai.com", "modelID": "gpt-5"}}]}
    """.utf8).write(to: store.fileURL)
    let providers = ProviderSettings(store: store, credentials: MemoryCredentialStore(secrets: ["openai": "sk"]),
                                     adapterKinds: [.api])
    let profile = try #require(providers.selected)
    #expect(profile.endpoint == nil && profile.routing == nil)
    #expect(profile.apiService == .openAI)
    #expect(providers.hasConsent(courseID: "c", destination: profile.destination))

    // A new OpenRouter profile and its consent save and load again with the routing.
    try providers.save(openRouter(credentialReference: nil), secret: key)
    let saved = try #require(providers.profiles.first { $0.id == "or" })
    try providers.allow(courseID: "c", destination: saved.destination)
    let text = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(!text.contains(key))
    let loaded = ProviderSettings(store: store, credentials: MemoryCredentialStore())
    let reloaded = try #require(loaded.profiles.first { $0.id == "or" })
    #expect(reloaded == saved)
    #expect(reloaded.routing?.allowsFallback == false)
    #expect(loaded.hasConsent(courseID: "c", destination: reloaded.destination))
    #expect(loaded.hasConsent(courseID: "c", destination: profile.destination))

    // Routing keys that are missing get the safe defaults. An unknown endpoint is left out, and the profile loads.
    let partial = try JSONDecoder().decode(ProviderProfile.self, from: Data("""
    {"id": "x", "kind": "api", "name": "OpenRouter", "vendor": "OpenRouter", "origin": "https://openrouter.ai/api/v1",
     "modelID": "m", "endpoint": "openRouter", "routing": {"upstreams": ["openai"]}}
    """.utf8))
    #expect(partial.routing == OpenRouterRouting(upstreams: ["openai"], allowsFallback: false, allowsDataCollection: false))
    let unknown = try JSONDecoder().decode(ProviderProfile.self, from: Data("""
    {"id": "y", "kind": "api", "name": "Later", "vendor": "Later", "origin": "https://x.example", "modelID": "m",
     "endpoint": "somethingLater"}
    """.utf8))
    #expect(unknown.endpoint == nil)
    #expect(ShippedAdapters.provider(for: unknown, credentials: MemoryCredentialStore()) == nil)
}
