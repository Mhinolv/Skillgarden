import Foundation

/// Reads the body of an Anthropic Messages stream (#154): `message_start`, text blocks, `ping`, `message_delta` with
/// the stop reason, then `message_stop`. An `error` event ends the answer. Unknown events and non-text deltas,
/// for example thinking, are skipped, because Anthropic can add new event types.
struct AnthropicStreamReader {
    private var decoder = ServerSentEventDecoder()
    private let errors: AnthropicErrors
    /// The full answer so far.
    private(set) var text = ""
    /// The `stop_reason` of the last `message_delta`.
    private(set) var stopReason: String?

    init(errors: AnthropicErrors) {
        self.errors = errors
    }

    /// Reads one chunk of the body. `send` gets the full text after each new text and gives false when the request ended.
    /// The outcome when the chunk ends the answer. Nil when the answer goes on.
    mutating func read(_ data: Data, send: (String) -> Bool) -> AnswerOutcome? {
        for event in decoder.decode(data) {
            switch AnthropicStreamEvent(data: event) {
            case .text(let delta):
                guard !delta.isEmpty else { continue }
                text += delta
                guard send(text) else { return .canceled }
            case .stop(let reason):
                stopReason = reason ?? stopReason
            case .end:
                return finalOutcome
            case .error(let type, let message):
                return .refused(reason: errors.reason(status: AnthropicErrors.status(ofType: type), message: message))
            case .other:
                continue
            case .malformed:
                return .malformed
            }
        }
        return nil
    }

    /// The outcome at `message_stop`: the output limit keeps the partial answer, and a refusal shows no answer.
    var finalOutcome: AnswerOutcome {
        switch stopReason {
        case "max_tokens", "model_context_window_exceeded": .incomplete
        case "refusal": .declined
        default: text.isEmpty ? .empty : .finished
        }
    }

    /// The outcome of a body that ended with no `message_stop`.
    var unfinishedOutcome: AnswerOutcome { text.isEmpty ? .empty : .disconnected }
}

/// The meaning of one event of an Anthropic Messages stream (#154).
enum AnthropicStreamEvent: Equatable {
    /// A `text_delta`, or the start text of a text block.
    case text(String)
    /// A `message_delta`. The reason is nil until the model stops.
    case stop(String?)
    /// `message_stop`.
    case end
    /// An `error` event. `message` is only for the mapping. It never goes into learner text.
    case error(type: String, message: String?)
    /// `message_start`, `ping`, `content_block_stop`, a non-text block or delta, or an unknown event.
    case other
    case malformed

    init(data: [UInt8]) {
        guard String(validating: data, as: UTF8.self) != nil,
              let event = try? JSONDecoder().decode(Payload.self, from: Data(data)) else { self = .malformed; return }
        switch event.type {
        case "content_block_start":
            self = event.contentBlock?.type == "text" ? .text(event.contentBlock?.text ?? "") : .other
        case "content_block_delta":
            self = event.delta?.type == "text_delta" ? .text(event.delta?.text ?? "") : .other
        case "message_delta":
            self = .stop(event.delta?.stopReason)
        case "message_stop":
            self = .end
        case "error":
            self = .error(type: event.error?.type ?? "", message: event.error?.message)
        default:
            self = .other
        }
    }

    private struct Payload: Decodable {
        struct Block: Decodable {
            let type: String?
            let text: String?
        }
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?
            enum CodingKeys: String, CodingKey { case type, text, stopReason = "stop_reason" }
        }
        struct Failure: Decodable {
            let type: String?
            let message: String?
        }
        let type: String
        let contentBlock: Block?
        let delta: Delta?
        let error: Failure?
        enum CodingKeys: String, CodingKey { case type, contentBlock = "content_block", delta, error }
    }
}

/// The learner text of the Anthropic errors (#154): the test result and the turn reason. No text holds the response body.
struct AnthropicErrors: Sendable {
    let modelID: String

    init(profile: ProviderProfile) {
        modelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let rejectedKey = "Anthropic did not accept the API key. Check it in Settings."
    static let rateLimited = "Anthropic rate limit reached. Try again later."
    static let busy = "Anthropic is busy. Try again later."
    static let unreachable = "Skillgarden can't connect to Anthropic. Check the internet connection."

    static func statusText(_ status: Int) -> String { "Anthropic sent an error (\(status))." }

    /// "This API key cannot use claude-sonnet-5-5."
    var forbiddenModel: String { "This API key cannot use \(modelID)." }

    /// The text of a 400 error about `max_tokens`: the output limit is too large for the model.
    var outputLimitTooLarge: String { "The output limit is too large for \(modelID). Lower it in Settings." }

    /// The text of an error with `status`. `message` is the `error.message` of the body. It only finds an output limit error.
    func reason(status: Int, message: String?) -> String {
        switch status {
        case 401: Self.rejectedKey
        case 403: forbiddenModel
        case 429: Self.rateLimited
        case 529: Self.busy
        case 400 where message?.contains("max_tokens") == true: outputLimitTooLarge
        default: Self.statusText(status)
        }
    }

    /// The text of a response with `status` and an error `body`: `{"type":"error","error":{"type":…,"message":…}}`.
    /// An `overloaded_error` body is busy with any status.
    func reason(status: Int, body: Data) -> String {
        struct Envelope: Decodable {
            struct Failure: Decodable { let type: String?, message: String? }
            let error: Failure?
        }
        let failure = (try? JSONDecoder().decode(Envelope.self, from: body))?.error
        if failure?.type == "overloaded_error" { return Self.busy }
        return reason(status: status, message: failure?.message)
    }

    /// The HTTP status of an error type in the stream. Anthropic uses the same types in error bodies.
    static func status(ofType type: String) -> Int {
        switch type {
        case "invalid_request_error": 400
        case "authentication_error": 401
        case "billing_error": 402
        case "permission_error": 403
        case "not_found_error": 404
        case "request_too_large": 413
        case "rate_limit_error": 429
        case "overloaded_error": 529
        default: 500
        }
    }
}
