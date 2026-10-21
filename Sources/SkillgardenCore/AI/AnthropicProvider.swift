import Foundation

/// The adapters that ship (#152, #153, #154, #157). The app gives them to `ProviderSettings`.
/// `ProviderSettings` makes the ChatGPT plan adapter itself, because it needs the session of the profile (#157).
public enum ShippedAdapters {
    public static let kinds: Set<AnswerProviderKind> = [.externalLocal, .api, .subscription]

    /// The provider of a profile. Nil for a profile with no adapter, for example an API profile of another host.
    @MainActor
    public static func provider(for profile: ProviderProfile, credentials: any CredentialStore) -> (any AnswerProvider)? {
        switch profile.kind {
        case .externalLocal: CompatibleAnswerProvider(profile: profile, credentials: credentials)
        case .api where profile.apiService == .openAI: OpenAIAnswerProvider(profile: profile, credentials: credentials)
        case .api where profile.apiService == .anthropic: AnthropicAnswerProvider(profile: profile, credentials: credentials)
        default: nil
        }
    }

    /// "Test Connection" with the key of the sheet or the saved key.
    public static func testConnection(_ profile: ProviderProfile, secret: String?) async -> ConnectionTestResult {
        switch profile.kind {
        case .externalLocal: await CompatibleAnswerProvider.testConnection(profile, token: secret)
        case .api where profile.apiService == .openAI: await OpenAIAnswerProvider.testConnection(profile, key: secret)
        case .api where profile.apiService == .anthropic: await AnthropicAnswerProvider.testConnection(profile, key: secret)
        default: .failed(reason: noTestText)
        }
    }

    public static let noTestText = "Skillgarden can't test this provider."
}

/// The Anthropic Messages API with an API key (#154). It sends only to `https://api.anthropic.com`, with the key of the
/// profile from the Keychain. It never uses Claude.ai sign-in or a Claude Pro or Max subscription.
/// The stream and cancel contract is the one of `LlamaClient`: deltas, then one `.ended` update.
/// After an error it does not try another provider. Retry uses the same profile.
@MainActor
public final class AnthropicAnswerProvider: AnswerProvider {
    public let id: String
    public let displayName: String
    public let kind = AnswerProviderKind.api
    public let destination: RemoteDestination?

    private let profile: ProviderProfile
    private let credentials: any CredentialStore
    /// One request at a time, as for the other providers.
    private let client: LlamaClient

    /// The `anthropic-version` header that the Messages API requires.
    nonisolated static let apiVersion = "2023-06-01"

    public init(profile: ProviderProfile, credentials: any CredentialStore, transport: any LlamaTransport = LoopbackTransport()) {
        id = profile.id
        displayName = profile.name
        destination = profile.destination
        self.profile = profile
        self.credentials = credentials
        client = LlamaClient(transport: transport)
    }

    /// Nil when the profile is not the Anthropic service, the model ID is empty, or the Keychain has no key or refuses it.
    /// The key is read on each question, so a new key in Settings applies at once.
    public func prepare() -> PreparedAnswer? {
        guard profile.credentialReference != nil, let key = try? credentials.secret(account: profile.keychainAccount),
              Self.messagesRequest([], profile: profile, key: key) != nil else { return nil }
        let errors = AnthropicErrors(profile: profile)
        return PreparedAnswer(origin: AnswerOrigin(providerID: id, modelID: profile.modelID)) { [client, profile] messages in
            client.start(Self.messagesRequest(messages, profile: profile, key: key)) { events, send in
                await Self.pump(events, errors: errors, send: send)
            }
        }
    }

    public func cancel(_ id: UUID) {
        client.cancel(id)
    }

    /// "Test Connection": sends `CompatibleAnswerProvider.testMessages` with a short output limit.
    /// A 200 stream is a pass, also when the model stops at the limit.
    public nonisolated static func testConnection(_ profile: ProviderProfile, key: String?,
                                                  transport: any LlamaTransport = LoopbackTransport()) async -> ConnectionTestResult {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return .failed(reason: APIService.noKeyText)
        }
        guard let request = messagesRequest(CompatibleAnswerProvider.testMessages, profile: profile, key: key, answerTokens: 16) else {
            return .failed(reason: profile.modelProblem ?? AnthropicErrors.rejectedKey)
        }
        let errors = AnthropicErrors(profile: profile)
        // The task of a request holds the client weakly, so the client must live until the end of the answer.
        let client = LlamaClient(transport: transport)
        let answer = client.start(request) { events, send in
            await pump(events, errors: errors, send: send)
        }
        var outcome = AnswerOutcome.empty
        for await update in answer.updates {
            if case .ended(let end, _) = update { outcome = end }
        }
        withExtendedLifetime(client) {}
        switch outcome {
        case .finished, .empty, .incomplete, .declined: return .connected
        default: return .failed(reason: outcome.learnerText ?? "")
        }
    }

    /// The `v1/messages` request, or nil when the profile is not the Anthropic service with a model ID,
    /// or the key is empty or has a character that a header can't hold.
    /// System messages go into the top-level `system` text. User and assistant messages go into `messages`.
    nonisolated static func messagesRequest(_ messages: [ChatMessage], profile: ProviderProfile, key: String,
                                            answerTokens: Int? = nil) -> URLRequest? {
        let model = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.apiService == .anthropic, !model.isEmpty, !key.isEmpty, key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
              let origin = URL(string: APIService.anthropic.origin) else { return nil }
        let limit = answerTokens ?? profile.answerTokens ?? APIService.defaultAnswerTokens
        guard limit >= 1 else { return nil }
        var request = URLRequest(url: origin.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        // The API refuses an empty message.
        let turns = messages.filter { $0.role != .system && !$0.content.isEmpty }
            .map { MessagesBody.Turn(role: $0.role.rawValue, content: $0.content) }
        let body = MessagesBody(model: model, maxTokens: limit, system: system.isEmpty ? nil : system, messages: turns, stream: true)
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private struct MessagesBody: Encodable {
        struct Turn: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Turn]
        let stream: Bool
        enum CodingKeys: String, CodingKey { case model, maxTokens = "max_tokens", system, messages, stream }
    }

    /// The most bytes of an error body that the adapter reads. It reads the body only to find the error type.
    nonisolated static let errorBodyLimit = 16_384

    /// Reads the response. No connection gives "can't connect". A status other than 200 gives the design-note text.
    /// The body of an error never goes into the text.
    nonisolated static func pump(_ events: AsyncThrowingStream<LlamaTransportEvent, any Error>, errors: AnthropicErrors,
                                 send: (String) -> Bool) async -> AnswerOutcome {
        var reader = AnthropicStreamReader(errors: errors)
        var status: Int?
        var errorBody = Data()
        do {
            for try await event in events {
                switch event {
                case .response(let code):
                    status = code
                case .data(let data):
                    guard status == 200 else {
                        errorBody.append(data.prefix(max(0, errorBodyLimit - errorBody.count)))
                        continue
                    }
                    if let outcome = reader.read(data, send: send) { return outcome }
                }
            }
        } catch {
            if Task.isCancelled { return .canceled }
            if status == 200 { return .disconnected }
        }
        if Task.isCancelled { return .canceled }
        guard let status else { return .refused(reason: AnthropicErrors.unreachable) }
        guard status == 200 else { return .refused(reason: errors.reason(status: status, body: errorBody)) }
        // The body ended with no `message_stop`.
        return reader.unfinishedOutcome
    }
}
