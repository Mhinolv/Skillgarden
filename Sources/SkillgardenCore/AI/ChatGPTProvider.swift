import Foundation

/// One model of the account model list of a ChatGPT plan (#157). The request sends `slug` as `model`.
public struct ChatGPTModel: Equatable, Hashable, Identifiable, Sendable {
    public let slug: String
    public let displayName: String

    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }

    public var id: String { slug }
}

/// The learner text of the ChatGPT plan errors (#157). No text holds a response body, a `detail` text or a token.
/// After an error the app does not try an API key.
public enum ChatGPTErrors {
    public static let planLimitText = "You reached the ChatGPT plan limit. Try again later."
    /// It names Settings, so the turn shows "Open Settings…".
    public static let revokedText = "ChatGPT access ended. Sign in again in Settings."
    public static let noConnectionText = "Skillgarden can't connect to ChatGPT. Check the network."
    public static let connectionLostText = "The connection to ChatGPT stopped. Try again."
    public static let failedText = "ChatGPT could not finish the answer. Try again."
    public static let unreadableText = "ChatGPT sent data that Skillgarden can't read. Try again."

    public static func statusText(_ status: Int) -> String { "ChatGPT sent an error (\(status))." }

    /// The `error.code` of the plan limit. It can come as a 429 or in `response.failed` after the stream starts.
    static let planLimitCode = "subscription_sharing_usage_limit_exceeded"
    /// The `error.code` of a revoked or expired grant (401).
    static let revokedCode = "subscription_sharing_invalid_user"

    /// The text of a response with `status`. The body is not read.
    static func reason(status: Int) -> String {
        switch status {
        case 401: revokedText
        case 429: planLimitText
        default: statusText(status)
        }
    }

    /// The text of a session that Skillgarden can't get. A network failure or a 503 keeps the tokens.
    static func reason(_ error: ChatGPTAuthError) -> String {
        if error.needsSignIn || error == .canceled { return revokedText }
        switch error {
        case .network: return noConnectionText
        case .credential(let error): return error.message
        case .httpStatus(let status): return statusText(status)
        default: return failedText
        }
    }
}

/// The answer of a ChatGPT plan through the Responses API with the account tokens of Sign in with ChatGPT (#157).
/// It sends only to `https://api.openai.com`, with `store: false`, `stream: true` and the full history in `input`.
/// It sends no output limit, no tools and no other field that the subscription profile refuses.
/// The stream and cancel contract is the one of `OpenAIAnswerProvider`: deltas, then one `.ended` update.
@MainActor
public final class ChatGPTAnswerProvider: AnswerProvider {
    /// A valid session of the profile. `ProviderSettings.chatGPTSession(for:)` refreshes it when it is near its end.
    public typealias SessionSource = @MainActor @Sendable () async throws(ChatGPTAuthError) -> ChatGPTSession

    public let id: String
    /// The provider row of the consent sheet: "ChatGPT Plan (OpenAI)".
    public let displayName: String
    public let kind = AnswerProviderKind.subscription
    public let destination: RemoteDestination?

    private let profile: ProviderProfile
    private let client: LlamaClient
    private let session: SessionSource
    /// Ends the session after OpenAI says that the grant is revoked, so Settings shows "Sign in again.".
    private let revoke: @MainActor @Sendable () -> Void

    /// The granted scope that inference needs.
    public nonisolated static let directScope = "chatgpt.tokens.use.direct"
    nonisolated static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    nonisolated static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    public init(profile: ProviderProfile, transport: any LlamaTransport, session: @escaping SessionSource,
                revoke: @escaping @MainActor @Sendable () -> Void) {
        id = profile.id
        displayName = "\(profile.name) (\(profile.vendor))"
        destination = profile.destination
        self.profile = profile
        self.session = session
        self.revoke = revoke
        client = LlamaClient(transport: transport)
    }

    /// Nil when the profile is not a ChatGPT plan or has no model. The session is read on each question, so a sign-in
    /// again applies at once.
    public func prepare() -> PreparedAnswer? {
        let model = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.isChatGPTPlan, !model.isEmpty else { return nil }
        return PreparedAnswer(origin: AnswerOrigin(providerID: id, modelID: profile.modelID)) { [client, source = session, revoke] messages in
            client.start { transport, send in
                let session: ChatGPTSession
                do throws(ChatGPTAuthError) { session = try await source() } catch {
                    return Task.isCancelled ? .canceled : .refused(reason: ChatGPTErrors.reason(error))
                }
                if Task.isCancelled { return .canceled }
                // A grant with no direct-use scope can't answer. A new sign-in asks for it.
                guard session.scopes.contains(Self.directScope),
                      let request = Self.responsesRequest(messages, model: model, accessToken: session.accessToken) else {
                    return .refused(reason: ChatGPTErrors.revokedText)
                }
                let (outcome, revoked) = await Self.pump(transport.send(request), send: send)
                if revoked { await revoke() }
                return outcome
            }
        }
    }

    public func cancel(_ id: UUID) {
        client.cancel(id)
    }

    /// The `POST /v1/responses` request, or nil when the model or the token is empty, or the token has a character that a
    /// header can't hold. System messages go into `instructions`, because the profile refuses a `system` item.
    nonisolated static func responsesRequest(_ messages: [ChatMessage], model: String, accessToken: String) -> URLRequest? {
        guard var request = authorizedRequest(url: responsesURL, accessToken: accessToken), !model.isEmpty else { return nil }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let body = ResponsesBody(model: model, instructions: instructions.isEmpty ? nil : instructions,
                                 input: messages.filter { $0.role != .system }, stream: true, store: false)
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    /// The `GET /v1/models` request of the account model list.
    nonisolated static func modelsRequest(accessToken: String) -> URLRequest? {
        guard var request = authorizedRequest(url: modelsURL, accessToken: accessToken) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private nonisolated static func authorizedRequest(url: URL, accessToken: String) -> URLRequest? {
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private struct ResponsesBody: Encodable {
        let model: String
        let instructions: String?
        let input: [ChatMessage]
        let stream: Bool
        let store: Bool
    }

    /// Reads the response. A status other than 200 gives the design-note text at once, and the body is never read,
    /// so a `detail` text never shows. `revoked` is true when OpenAI says that the grant ended.
    /// Only `response.completed` is a success. A body that ends before it is a failure.
    nonisolated static func pump(_ events: AsyncThrowingStream<LlamaTransportEvent, any Error>,
                                 send: (String) -> Bool) async -> (outcome: AnswerOutcome, revoked: Bool) {
        var reader = ResponsesStreamReader(failedReason: ChatGPTErrors.failedText)
        var status: Int?
        do {
            for try await event in events {
                switch event {
                case .response(let code):
                    guard code == 200 else { return (.refused(reason: ChatGPTErrors.reason(status: code)), code == 401) }
                    status = code
                case .data(let data):
                    guard let outcome = reader.read(data, send: send) else { continue }
                    switch reader.failureCode {
                    case ChatGPTErrors.planLimitCode: return (.refused(reason: ChatGPTErrors.planLimitText), false)
                    case ChatGPTErrors.revokedCode: return (.refused(reason: ChatGPTErrors.revokedText), true)
                    default: return (outcome == .malformed ? .refused(reason: ChatGPTErrors.unreadableText) : outcome, false)
                    }
                }
            }
        } catch {
            if Task.isCancelled { return (.canceled, false) }
        }
        if Task.isCancelled { return (.canceled, false) }
        return (.refused(reason: status == nil ? ChatGPTErrors.noConnectionText : ChatGPTErrors.connectionLostText), false)
    }

    /// The models of the account, in server order. Only models with `visibility == "list"` show.
    nonisolated static func fetchModels(accessToken: String, transport: any LlamaTransport) async -> ChatGPTModelsResult {
        guard let request = modelsRequest(accessToken: accessToken) else {
            return .failed(reason: ChatGPTErrors.revokedText, revoked: false)
        }
        var status: Int?
        var body = Data()
        do {
            for try await event in transport.send(request) {
                switch event {
                case .response(let code):
                    guard code == 200 else { return .failed(reason: ChatGPTErrors.reason(status: code), revoked: code == 401) }
                    status = code
                case .data(let data):
                    body.append(data)
                    if body.count > 1_000_000 { return .failed(reason: ChatGPTErrors.unreadableText, revoked: false) }
                }
            }
        } catch {
            return .failed(reason: status == nil ? ChatGPTErrors.noConnectionText : ChatGPTErrors.connectionLostText, revoked: false)
        }
        guard status != nil else { return .failed(reason: ChatGPTErrors.noConnectionText, revoked: false) }
        guard let models = models(from: body) else { return .failed(reason: ChatGPTErrors.unreadableText, revoked: false) }
        return .models(models)
    }

    /// The listed models of a `{"models": [...]}` body. Nil when the body is not that form.
    /// A model with no display name shows its slug.
    nonisolated static func models(from body: Data) -> [ChatGPTModel]? {
        struct List: Decodable {
            struct Model: Decodable {
                let slug: String?
                let displayName: String?
                let visibility: String?
                enum CodingKeys: String, CodingKey { case slug, displayName = "display_name", visibility }
            }
            let models: [Model]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: body) else { return nil }
        var seen: Set<String> = []
        return list.models.compactMap { model in
            guard model.visibility == "list", let slug = model.slug?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            let name = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ChatGPTModel(slug: slug, displayName: name.isEmpty ? slug : name)
        }
    }
}

/// The result of the account model fetch (#157).
public enum ChatGPTModelsResult: Equatable, Sendable {
    case models([ChatGPTModel])
    /// `reason` is the design-note text. `revoked` is true when OpenAI says that the grant ended.
    case failed(reason: String, revoked: Bool)
}
