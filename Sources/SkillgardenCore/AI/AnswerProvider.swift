import Foundation

/// The kind of an answer provider (#150). #151 shows it in the Settings picker, the Q&A header and the footer.
public enum AnswerProviderKind: String, Sendable, CaseIterable {
    /// The llama.cpp runtime in the app bundle, which Skillgarden owns.
    case local
    /// A model server that the learner runs on this Mac, for example LM Studio or Ollama.
    case externalLocal
    /// A remote API with a key.
    case api
    /// A remote service with an account of the learner.
    case subscription
}

/// The provider and the model of one answer (#150). The store saves them on each turn.
/// They are stable IDs, not display names, because display names can change.
public struct AnswerOrigin: Equatable, Hashable, Sendable {
    public let providerID: String
    /// Nil when the model is not known. Turns saved before #150 have no model.
    public let modelID: String?

    public init(providerID: String, modelID: String?) {
        self.providerID = providerID
        self.modelID = modelID
    }

    /// The origin of a turn saved before #150: the bundled local provider with no known model.
    public static let legacy = AnswerOrigin(providerID: BundledAnswerProvider.providerID, modelID: nil)
}

/// One request that a provider can start now. `AnswerProvider.prepare()` gives it when the learner sends.
public struct PreparedAnswer: Sendable {
    /// The provider and the model that answer.
    public let origin: AnswerOrigin
    private let start: @Sendable ([ChatMessage]) -> AnswerRequest

    public init(origin: AnswerOrigin, start: @escaping @Sendable ([ChatMessage]) -> AnswerRequest) {
        self.origin = origin
        self.start = start
    }

    /// Starts the request. Use the `id` of the request to cancel it.
    public func ask(_ messages: [ChatMessage]) -> AnswerRequest {
        start(messages)
    }
}

/// A source of lecture answers (#150). `LectureQA` sends each question through one provider.
/// The stream contract is the one of `LlamaClient`: deltas, then one `.ended` update.
@MainActor
public protocol AnswerProvider: AnyObject {
    /// A stable ID. It does not change when the display name changes.
    var id: String { get }
    var displayName: String { get }
    var kind: AnswerProviderKind { get }
    /// The place that lecture text goes to (#151). Nil for the bundled model, which needs no consent.
    /// Each other provider sends only after the learner allows the course for this destination.
    var destination: RemoteDestination? { get }
    /// The request that the provider can start now. Nil when it can't answer now, for example when no server is ready.
    /// It sends nothing. Only `PreparedAnswer.ask(_:)` sends.
    func prepare() -> PreparedAnswer?
    /// Ends the request with `id` at once, with the partial answer. It does nothing for an old id.
    func cancel(_ id: UUID)
}

extension AnswerProvider {
    public var destination: RemoteDestination? { nil }
}

/// The bundled llama.cpp runtime (#123, #124) as an answer provider. It is the default provider (#151).
@MainActor
public final class BundledAnswerProvider: AnswerProvider {
    /// The store migration of #150 writes this ID on older turns. Do not change it.
    public nonisolated static let providerID = "bundled-local"

    public let id = BundledAnswerProvider.providerID
    public let displayName = "Local Model"
    public let kind = AnswerProviderKind.local

    private let client: LlamaClient
    private let endpoint: @MainActor () -> LocalAIEndpoint?

    /// `endpoint` is `RuntimeSupervisor.verifiedEndpoint()`.
    public init(client: LlamaClient, endpoint: @escaping @MainActor () -> LocalAIEndpoint?) {
        self.client = client
        self.endpoint = endpoint
    }

    /// Nil when the owned server is not ready. The model ID is the file name of the model that the server runs.
    public func prepare() -> PreparedAnswer? {
        guard let endpoint = endpoint() else { return nil }
        return PreparedAnswer(origin: AnswerOrigin(providerID: id, modelID: endpoint.modelID)) { [client] messages in
            client.ask(messages, endpoint: endpoint)
        }
    }

    public func cancel(_ id: UUID) {
        client.cancel(id)
    }
}
