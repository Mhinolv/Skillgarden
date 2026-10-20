import Foundation

/// How a local AI answer ends (#124). The #128 lecture Q&A tab shows `learnerText` under the answer.
public enum AnswerOutcome: Equatable, Sendable {
    case finished
    /// The learner canceled. The partial answer stays.
    case canceled
    /// The connection stopped before the end of the answer.
    case disconnected
    /// The model finished with no text.
    case empty
    /// An event that is not valid UTF-8 or not the expected JSON.
    case malformed
    /// A status other than 200, or an error event in the stream.
    case httpError(status: Int)
    /// A non-loopback endpoint, a bad session secret, a 401 or 403, or a redirect.
    case untrusted
    /// Another request is active. Only one request runs at a time.
    case busy
    /// A provider other than the bundled model refused the request (#152). `reason` is the design-note text.
    /// It never holds the response body.
    case refused(reason: String)
    /// The model stopped at the output limit of the profile (#154). The partial answer stays.
    case incomplete
    /// The model declined to answer, for example an Anthropic `refusal` stop (#154).
    case declined

    public static let incompleteText = "Stopped at the output limit"
    public static let declinedText = "The model declined to answer."

    /// The design-note text for the learner. Nil when the answer shows no extra text.
    public var learnerText: String? {
        switch self {
        case .finished: nil
        case .incomplete: Self.incompleteText
        case .declined: Self.declinedText
        case .canceled: "Canceled"
        case .disconnected: "The answer stopped because local AI stopped. Try again."
        case .empty: "The model gave no answer. Try again."
        case .malformed: "Local AI sent data that Skillgarden can't read. Try again."
        case .httpError(let status): "Local AI returned an error (\(status)). Try again."
        case .untrusted: "Skillgarden stopped the request. The server is not the one that it started."
        case .busy: "Local AI is answering another question. Wait, or cancel it."
        case .refused(let reason): reason
        }
    }

    /// True when the answer keeps the text that came before the end.
    var keepsText: Bool {
        switch self {
        case .finished, .canceled, .disconnected, .malformed, .incomplete: true
        case .empty, .httpError, .untrusted, .busy, .refused, .declined: false
        }
    }
}

/// One change of an answer. Each update has the full text so far, so the UI can skip updates.
public enum AnswerUpdate: Equatable, Sendable {
    /// New text came. `text` is the full answer so far.
    case delta(text: String)
    /// The last update of the request. `text` is empty when the outcome does not keep the text.
    case ended(AnswerOutcome, text: String)
}

/// Splits server-sent event bytes into the `data` of each event (#124).
/// It cuts lines on bytes only, so a UTF-8 character that two chunks split stays whole.
struct ServerSentEventDecoder {
    private var buffer: [UInt8] = []
    private var data: [UInt8]?
    /// A CR at the end of the last chunk. A LF at the start of the next chunk is then part of the same line end.
    private var skipsLineFeed = false

    /// The `data` of each event that `chunk` completes, in order.
    mutating func decode(_ chunk: some Sequence<UInt8>) -> [[UInt8]] {
        var events: [[UInt8]] = []
        for byte in chunk {
            if skipsLineFeed {
                skipsLineFeed = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                skipsLineFeed = true
                fallthrough
            case 0x0A:
                if let event = endLine() { events.append(event) }
            default:
                buffer.append(byte)
            }
        }
        return events
    }

    /// One line is complete. A blank line ends the event.
    private mutating func endLine() -> [UInt8]? {
        defer { buffer.removeAll(keepingCapacity: true) }
        guard !buffer.isEmpty else {
            defer { data = nil }
            return data
        }
        // A line that starts with ":" is a comment. Fields other than `data` are not used.
        let colon = buffer.firstIndex(of: 0x3A) ?? buffer.endIndex
        guard colon > 0, buffer[..<colon].elementsEqual("data".utf8) else { return nil }
        var value = buffer[min(colon + 1, buffer.endIndex)...]
        if value.first == 0x20 { value = value.dropFirst() }
        if data == nil { data = Array(value) } else { data! += [0x0A] + value }
        return nil
    }
}

/// Reads the body of an OpenAI-style chat stream: the owned llama-server (#124) and the external local servers (#152).
struct ChatStreamReader {
    private var decoder = ServerSentEventDecoder()
    /// The full answer so far.
    private(set) var text = ""

    /// Reads one chunk of the body. `send` gets the full text after each delta and gives false when the request ended.
    /// The outcome when the chunk ends the answer. Nil when the answer goes on.
    mutating func read(_ data: Data, send: (String) -> Bool) -> AnswerOutcome? {
        for event in decoder.decode(data) {
            switch ChatStreamEvent(data: event) {
            case .content(let delta):
                guard !delta.isEmpty else { continue }
                text += delta
                guard send(text) else { return .canceled }
            case .finished(let delta):
                text += delta
                if !delta.isEmpty { guard send(text) else { return .canceled } }
                return text.isEmpty ? .empty : .finished
            case .error(let status):
                return .httpError(status: status)
            case .malformed:
                return .malformed
            }
        }
        return nil
    }

    /// The outcome of a body that ended with no finish event.
    var unfinishedOutcome: AnswerOutcome { text.isEmpty ? .empty : .disconnected }
}

/// The meaning of one event of the OpenAI-style chat stream of llama-server.
enum ChatStreamEvent: Equatable {
    case content(String)
    /// `[DONE]`, or a chunk with a `finish_reason`. A finish chunk can also have text.
    case finished(String)
    case error(status: Int)
    case malformed

    init(data: [UInt8]) {
        guard let text = String(validating: data, as: UTF8.self) else { self = .malformed; return }
        if text == "[DONE]" { self = .finished(""); return }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(data)) else { self = .malformed; return }
        if let error = chunk.error { self = .error(status: error.code ?? 500); return }
        guard let choice = chunk.choices?.first else {
            // Some chunks have only `usage` or `timings`.
            self = chunk.choices == nil && chunk.usage == nil && chunk.timings == nil ? .malformed : .content("")
            return
        }
        let content = choice.delta?.content ?? ""
        self = choice.finishReason == nil ? .content(content) : .finished(content)
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case delta, finishReason = "finish_reason" }
        }
        /// An error object with a number code, or another form: LM Studio and Ollama can send a text code or a plain text (#152).
        struct Failure: Decodable {
            let code: Int?

            init(from decoder: any Decoder) throws {
                struct Object: Decodable { let code: Int? }
                code = (try? Object(from: decoder))?.code
            }
        }
        struct Present: Decodable {}
        let choices: [Choice]?
        let error: Failure?
        let usage: Present?
        let timings: Present?
    }
}
