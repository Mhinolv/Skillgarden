import Foundation

/// An OpenAI-compatible Chat Completions server: LM Studio or Ollama on this Mac (#152), OpenRouter or a custom
/// HTTPS endpoint (#155). It sends only to the base URL of the profile: a literal loopback URL, the OpenRouter URL or an
/// `https` URL. It follows no redirect. The optional key of the profile goes only into the `Authorization` header.
/// It never uses the session secret of the owned server. Skillgarden does not start or stop a server.
/// The stream and cancel contract is the one of `LlamaClient`: deltas, then one `.ended` update.
@MainActor
public final class CompatibleAnswerProvider: AnswerProvider {
    public let id: String
    public let displayName: String
    public let kind: AnswerProviderKind
    public let destination: RemoteDestination?

    private let profile: ProviderProfile
    private let credentials: any CredentialStore
    /// One request at a time, as for the owned server.
    private let client: LlamaClient

    /// `transport` nil uses the real transport of the profile.
    public init(profile: ProviderProfile, credentials: any CredentialStore, transport: (any LlamaTransport)? = nil) {
        id = profile.id
        displayName = profile.name
        kind = profile.kind
        destination = profile.destination
        self.profile = profile
        self.credentials = credentials
        client = LlamaClient(transport: transport ?? Self.transport(for: profile))
    }

    /// The real transport of `profile`. It follows no redirect.
    /// A remote endpoint (#155) uses the system proxy settings. A loopback server never does.
    nonisolated static func transport(for profile: ProviderProfile) -> any LlamaTransport {
        LoopbackTransport(usesSystemProxy: profile.kind != .externalLocal)
    }

    /// Nil when the base URL is not valid for the profile, the model ID is empty, OpenRouter has no key,
    /// or the Keychain refuses the token.
    /// The token is read on each question, so a new token in Settings applies at once.
    public func prepare() -> PreparedAnswer? {
        let token: String?
        if profile.credentialReference != nil {
            do { token = try credentials.secret(account: profile.keychainAccount) } catch { return nil }
        } else {
            token = nil
        }
        guard Self.chatRequest([], profile: profile, token: token) != nil else { return nil }
        let errors = ExternalServerErrors(profile: profile)
        return PreparedAnswer(origin: AnswerOrigin(providerID: id, modelID: profile.modelID)) { [client, profile] messages in
            client.start(Self.chatRequest(messages, profile: profile, token: token)) { events, send in
                await Self.pump(events, errors: errors, send: send)
            }
        }
    }

    public func cancel(_ id: UUID) {
        client.cancel(id)
    }

    /// The synthetic message of "Test Connection". It has no lecture text.
    public nonisolated static let testMessages = [ChatMessage(role: .user, content: "Reply with the word OK.")]

    /// "Test Connection": sends `testMessages` with a short answer limit. A 200 stream is a pass, also with no text,
    /// because a reasoning model can use all of the limit before it writes text.
    public nonisolated static func testConnection(_ profile: ProviderProfile, token: String?,
                                                  transport: (any LlamaTransport)? = nil) async -> ConnectionTestResult {
        guard let request = chatRequest(testMessages, profile: profile, token: token, answerTokens: 16) else {
            let noKey = profile.endpoint == .openRouter ? APIService.noKeyText : ExternalServerErrors.rejectedToken
            return .failed(reason: profile.originProblem ?? profile.upstreamProblem ?? profile.modelProblem ?? noKey)
        }
        let errors = ExternalServerErrors(profile: profile)
        // The task of a request holds the client weakly, so the client must live until the end of the answer.
        let client = LlamaClient(transport: transport ?? Self.transport(for: profile))
        let answer = client.start(request) { events, send in
            await pump(events, errors: errors, send: send)
        }
        var outcome = AnswerOutcome.empty
        for await update in answer.updates {
            if case .ended(let end, _) = update { outcome = end }
        }
        withExtendedLifetime(client) {}
        switch outcome {
        case .finished, .empty: return .connected
        default: return .failed(reason: outcome.learnerText ?? "")
        }
    }

    /// The `chat/completions` request under the base URL, or nil when the profile is not a valid compatible profile,
    /// OpenRouter has no key or upstream, or the token has a character that a header can't hold.
    /// OpenRouter gets the `provider` routing of the profile: the upstreams in order, the fallback and the data policy (#155).
    nonisolated static func chatRequest(_ messages: [ChatMessage], profile: ProviderProfile, token: String?,
                                        answerTokens: Int? = nil) -> URLRequest? {
        let model = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let url = profile.chatCompletionsURL, profile.upstreamProblem == nil else { return nil }
        if profile.endpoint == .openRouter, token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            guard token.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let routing = profile.endpoint == .openRouter ? profile.routing.map(ChatBody.Routing.init) : nil
        let body = ChatBody(model: model, messages: messages, stream: true, maxTokens: answerTokens ?? profile.answerTokens,
                            provider: routing)
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private struct ChatBody: Encodable {
        /// The OpenRouter provider routing. With fallback off, `only` also limits the request to the upstreams.
        struct Routing: Encodable {
            let order: [String]
            let only: [String]?
            let allowFallbacks: Bool
            let dataCollection: String
            enum CodingKeys: String, CodingKey {
                case order, only, allowFallbacks = "allow_fallbacks", dataCollection = "data_collection"
            }

            init(_ routing: OpenRouterRouting) {
                order = routing.upstreams
                only = routing.allowsFallback ? nil : routing.upstreams
                allowFallbacks = routing.allowsFallback
                dataCollection = routing.allowsDataCollection ? "allow" : "deny"
            }
        }
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let maxTokens: Int?
        let provider: Routing?
        enum CodingKeys: String, CodingKey { case model, messages, stream, maxTokens = "max_tokens", provider }
    }

    /// The most bytes of an error body that the adapter reads. It reads the body only to find an unknown model.
    nonisolated static let errorBodyLimit = 16_384

    /// Reads the response. No connection gives "not running", or "can't connect" for a remote endpoint.
    /// A status other than 200 gives the design-note text. The body of an error never goes into the text.
    /// A remote endpoint (#155) has its own text for a redirect, a lost connection and unreadable data.
    nonisolated static func pump(_ events: AsyncThrowingStream<LlamaTransportEvent, any Error>, errors: ExternalServerErrors,
                                 send: (String) -> Bool) async -> AnswerOutcome {
        var reader = ChatStreamReader()
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
                    if let outcome = reader.read(data, send: send) {
                        switch outcome {
                        case .httpError(let code): return .refused(reason: errors.statusText(code))
                        case .malformed where errors.isRemote: return .refused(reason: errors.unreadable)
                        default: return outcome
                        }
                    }
                }
            }
        } catch {
            if Task.isCancelled { return .canceled }
            if status == 200 { return errors.isRemote ? .refused(reason: errors.connectionLost) : .disconnected }
        }
        if Task.isCancelled { return .canceled }
        guard let status else { return .refused(reason: errors.notRunning) }
        guard status == 200 else { return .refused(reason: errors.reason(status: status, body: errorBody)) }
        // The body ended with no finish event.
        return reader.unfinishedOutcome
    }
}

/// The learner text of the errors of an external local server (#152) or a remote compatible endpoint (#155):
/// the test result and the turn reason. No text holds the response body or the key.
struct ExternalServerErrors: Sendable {
    let vendor: String
    let host: String
    let modelID: String
    /// True for OpenRouter and a custom HTTPS endpoint (#155).
    let isRemote: Bool

    init(profile: ProviderProfile) {
        vendor = profile.vendor
        host = profile.host
        modelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        isRemote = profile.kind != .externalLocal
    }

    static let rejectedToken = "The server did not accept the token."
    static let redirectText = "The server tried to redirect. Skillgarden stopped the request."

    static func statusText(_ status: Int) -> String { "The server sent an error (\(status))." }

    /// "openrouter.ai sent an error (500)." for a remote endpoint.
    func statusText(_ status: Int) -> String { isRemote ? "\(host) sent an error (\(status))." : Self.statusText(status) }

    /// "LM Studio is not running at 127.0.0.1:1234." A remote endpoint: "Skillgarden can't connect to openrouter.ai. …"
    var notRunning: String {
        isRemote ? "Skillgarden can't connect to \(host). Check the network." : "\(vendor) is not running at \(host)."
    }

    /// "openrouter.ai did not accept the API key." (#155)
    var rejectedKey: String { "\(host) did not accept the API key." }
    var connectionLost: String { "The connection to \(host) stopped. Try again." }
    var unreadable: String { "\(host) sent data that Skillgarden can't read. Try again." }
    var limit: String { "\(host) rate limit or quota reached. Try again later." }

    var unknownModel: String { "The server has no model \"\(modelID)\"." }

    /// The text of a response with `status`. A 404, or an error body that names the model, is an unknown model.
    /// A remote endpoint never follows a redirect (#155).
    func reason(status: Int, body: Data) -> String {
        if isRemote {
            switch status {
            case 300..<400: return Self.redirectText
            case 401: return rejectedKey
            // OpenRouter sends 403 for a flagged prompt, not for a bad key.
            case 403: return statusText(status)
            case 429: return limit
            default: break
            }
        }
        switch status {
        case 401, 403: return Self.rejectedToken
        case 404: return unknownModel
        default: return Self.namesUnknownModel(body) ? unknownModel : statusText(status)
        }
    }

    /// True when an OpenAI-style error body says that the model is not found:
    /// `{"error": {"code": "model_not_found"}}`, `{"error": {"param": "model"}}`, or a message such as `model "x" not found`.
    static func namesUnknownModel(_ body: Data) -> Bool {
        /// Each field is optional and can have another type, for example a number code.
        struct Detail: Decodable {
            let code: String?, param: String?, message: String?
            enum CodingKeys: String, CodingKey { case code, param, message }
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = try? container.decode(String.self, forKey: .code)
                param = try? container.decode(String.self, forKey: .param)
                message = try? container.decode(String.self, forKey: .message)
            }
        }
        struct Envelope: Decodable {
            let detail: Detail?
            let text: String?
            enum CodingKeys: String, CodingKey { case error }
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                detail = try? container.decode(Detail.self, forKey: .error)
                text = try? container.decode(String.self, forKey: .error)
            }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return false }
        if envelope.detail?.code == "model_not_found" || envelope.detail?.param == "model" { return true }
        let message = (envelope.detail?.message ?? envelope.text ?? "").lowercased()
        return message.contains("model") && message.contains("not found")
    }
}
