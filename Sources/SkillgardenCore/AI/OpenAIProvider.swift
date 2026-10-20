import Foundation

/// The OpenAI Responses API with an API key of the learner (#153).
/// It sends only to the fixed origin `https://api.openai.com`, with `store: false`, and it follows no redirect.
/// The key is a Keychain item. It goes only into the `Authorization` header.
/// The stream and cancel contract is the one of `LlamaClient`: deltas, then one `.ended` update.
@MainActor
public final class OpenAIAnswerProvider: AnswerProvider {
    public let id: String
    public let displayName: String
    public let kind = AnswerProviderKind.api
    public let destination: RemoteDestination?

    private let profile: ProviderProfile
    private let credentials: any CredentialStore
    /// One request at a time, as for the other providers.
    private let client: LlamaClient

    public init(profile: ProviderProfile, credentials: any CredentialStore,
                transport: any LlamaTransport = LoopbackTransport(usesSystemProxy: true)) {
        id = profile.id
        displayName = profile.name
        destination = profile.destination
        self.profile = profile
        self.credentials = credentials
        client = LlamaClient(transport: transport)
    }

    /// Nil when the profile is not the OpenAI API, the model ID is empty, or the Keychain has no usable key.
    /// The key is read on each question, so a new key in Settings applies at once.
    public func prepare() -> PreparedAnswer? {
        guard profile.credentialReference != nil,
              let key = try? credentials.secret(account: profile.keychainAccount),
              Self.responsesRequest([], profile: profile, key: key) != nil else { return nil }
        let errors = OpenAIErrors(profile: profile)
        return PreparedAnswer(origin: AnswerOrigin(providerID: id, modelID: profile.modelID)) { [client, profile] messages in
            client.start(Self.responsesRequest(messages, profile: profile, key: key)) { events, send in
                await Self.pump(events, errors: errors, send: send)
            }
        }
    }

    public func cancel(_ id: UUID) {
        client.cancel(id)
    }

    /// The answer limit when the profile has none: the default of the "Output limit" field.
    public nonisolated static let defaultAnswerTokens = 1024
    /// The smallest `max_output_tokens` that the API accepts.
    public nonisolated static let minimumAnswerTokens = 16

    /// "Test Connection": sends `CompatibleAnswerProvider.testMessages` with the smallest answer limit.
    /// A response that completes, stops at the limit or declines is a pass: the key and the model work.
    public nonisolated static func testConnection(_ profile: ProviderProfile, key: String?,
                                                  transport: any LlamaTransport = LoopbackTransport(usesSystemProxy: true))
        async -> ConnectionTestResult {
        guard let request = responsesRequest(CompatibleAnswerProvider.testMessages, profile: profile, key: key,
                                             answerTokens: minimumAnswerTokens) else {
            return .failed(reason: profile.modelProblem ?? OpenAIErrors.noKey)
        }
        let errors = OpenAIErrors(profile: profile)
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

    /// The `POST /v1/responses` request, or nil when the profile is not the OpenAI API, the model ID is empty,
    /// or the key is empty or has a character that a header can't hold.
    /// System messages go into `instructions`. The other messages go into `input` in order.
    nonisolated static func responsesRequest(_ messages: [ChatMessage], profile: ProviderProfile, key: String?,
                                             answerTokens: Int? = nil) -> URLRequest? {
        let model = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard profile.apiService == .openAI, !model.isEmpty, !key.isEmpty,
              key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        var request = URLRequest(url: APIService.openAI.endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let limit = answerTokens ?? profile.answerTokens ?? defaultAnswerTokens
        let body = ResponsesBody(model: model, instructions: instructions.isEmpty ? nil : instructions,
                                 input: messages.filter { $0.role != .system }, stream: true, store: false,
                                 maxOutputTokens: max(minimumAnswerTokens, limit))
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private struct ResponsesBody: Encodable {
        let model: String
        let instructions: String?
        let input: [ChatMessage]
        let stream: Bool
        let store: Bool
        let maxOutputTokens: Int
        enum CodingKeys: String, CodingKey { case model, instructions, input, stream, store, maxOutputTokens = "max_output_tokens" }
    }

    /// Reads the response. A status other than 200 gives the design-note text at once, and the body is never read.
    nonisolated static func pump(_ events: AsyncThrowingStream<LlamaTransportEvent, any Error>, errors: OpenAIErrors,
                                 send: (String) -> Bool) async -> AnswerOutcome {
        var reader = ResponsesStreamReader(failedReason: OpenAIErrors.failedText)
        var status: Int?
        do {
            for try await event in events {
                switch event {
                case .response(let code):
                    guard code == 200 else { return .refused(reason: errors.reason(status: code)) }
                    status = code
                case .data(let data):
                    if let outcome = reader.read(data, send: send) {
                        return outcome == .malformed ? .refused(reason: OpenAIErrors.unreadableText) : outcome
                    }
                }
            }
        } catch {
            if Task.isCancelled { return .canceled }
        }
        if Task.isCancelled { return .canceled }
        // No response at all, or a body that ended with no terminal event.
        return .refused(reason: status == nil ? OpenAIErrors.noConnectionText : OpenAIErrors.connectionLostText)
    }
}

/// The learner text of the OpenAI errors (#153): the test result and the turn reason. No text holds a response body or the key.
struct OpenAIErrors: Sendable {
    let modelID: String

    init(profile: ProviderProfile) {
        modelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let noKey = ProviderProfile.noKeyText
    static let rejectedKeyText = "OpenAI did not accept the API key. Check it in Settings."
    static let limitText = "OpenAI rate limit or quota reached. Try again later."
    static let noConnectionText = "Skillgarden can't connect to OpenAI. Check the network."
    static let connectionLostText = "The connection to OpenAI stopped. Try again."
    static let failedText = "OpenAI could not finish the answer. Try again."
    static let unreadableText = "OpenAI sent data that Skillgarden can't read. Try again."

    static func statusText(_ status: Int) -> String { "OpenAI sent an error (\(status))." }

    /// "This API key cannot use gpt-5."
    var noAccessText: String { "This API key cannot use \(modelID)." }

    /// The text of a response with `status`. OpenAI sends 404 for a model that the key can't use.
    func reason(status: Int) -> String {
        switch status {
        case 401: Self.rejectedKeyText
        case 403, 404: noAccessText
        case 429: Self.limitText
        default: Self.statusText(status)
        }
    }
}
