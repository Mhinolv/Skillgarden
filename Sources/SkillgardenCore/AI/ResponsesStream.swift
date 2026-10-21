import Foundation

/// The meaning of one event of the OpenAI Responses stream (#153). The `type` field of the JSON names the event.
/// The `event:` line of the stream has the same name, so the decoder reads only `data`.
enum ResponsesStreamEvent: Equatable {
    /// `response.output_text.delta`: new answer text.
    case text(String)
    /// `response.refusal.delta` or `response.refusal.done`: the model declines. The refusal text is not kept.
    case refusal
    /// `response.completed`.
    case completed
    /// `response.incomplete`, with the reason of `incomplete_details`, for example `max_output_tokens` or `content_filter`.
    case incomplete(reason: String?)
    /// `response.failed`, or an `error` event, with the error code (#157). The error message is not kept.
    case failed(code: String?)
    /// `response.cancelled`.
    case cancelled
    /// An event that does not change the answer, for example `response.created` or `response.output_text.done`.
    case other
    /// An event that is not valid UTF-8, not JSON, or has no `type`.
    case malformed

    init(data: [UInt8]) {
        guard let text = String(validating: data, as: UTF8.self) else { self = .malformed; return }
        if text == "[DONE]" { self = .other; return }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(data)) else { self = .malformed; return }
        switch event.type {
        case "response.output_text.delta": self = .text(event.delta ?? "")
        case "response.refusal.delta", "response.refusal.done": self = .refusal
        case "response.completed": self = .completed
        case "response.incomplete": self = .incomplete(reason: event.response?.incompleteDetails?.reason)
        case "response.failed": self = .failed(code: event.response?.error?.code)
        case "error": self = .failed(code: event.code)
        case "response.cancelled": self = .cancelled
        default: self = .other
        }
    }

    /// Each field other than `type` is optional and can have another type in other events.
    private struct Event: Decodable {
        struct Response: Decodable {
            struct Details: Decodable { let reason: String? }
            struct Failure: Decodable { let code: String? }
            let incompleteDetails: Details?
            let error: Failure?
            enum CodingKeys: String, CodingKey { case incompleteDetails = "incomplete_details", error }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                incompleteDetails = try? container.decode(Details.self, forKey: .incompleteDetails)
                error = try? container.decode(Failure.self, forKey: .error)
            }
        }
        let type: String
        let delta: String?
        let response: Response?
        /// The code of an `error` event.
        let code: String?

        enum CodingKeys: String, CodingKey { case type, delta, response, code }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            delta = try? container.decode(String.self, forKey: .delta)
            response = try? container.decode(Response.self, forKey: .response)
            code = try? container.decode(String.self, forKey: .code)
        }
    }
}

/// Reads the body of an OpenAI Responses stream (#153). The ChatGPT subscription path (#157) can use it too.
struct ResponsesStreamReader {
    private var decoder = ServerSentEventDecoder()
    /// The full answer so far.
    private(set) var text = ""
    /// True after a refusal event. The end of the response is then `.declined`.
    private var refused = false
    /// The error code of a failed response, for example `subscription_sharing_usage_limit_exceeded` (#157).
    private(set) var failureCode: String?
    /// The turn reason of a failed response. It never holds the error message of the service.
    let failedReason: String

    init(failedReason: String) {
        self.failedReason = failedReason
    }

    /// Reads one chunk of the body. `send` gets the full text after each delta and gives false when the request ended.
    /// The outcome when the chunk ends the answer. Nil when the answer goes on.
    mutating func read(_ data: Data, send: (String) -> Bool) -> AnswerOutcome? {
        for event in decoder.decode(data) {
            switch ResponsesStreamEvent(data: event) {
            case .text(let delta):
                guard !delta.isEmpty else { continue }
                text += delta
                guard send(text) else { return .canceled }
            case .refusal:
                refused = true
            case .completed:
                if refused { return .declined }
                return text.isEmpty ? .empty : .finished
            case .incomplete(let reason):
                return refused || reason == "content_filter" ? .declined : .incomplete
            case .failed(let code):
                failureCode = code
                return .refused(reason: failedReason)
            case .cancelled:
                return .canceled
            case .other:
                continue
            case .malformed:
                return .malformed
            }
        }
        return nil
    }
}
