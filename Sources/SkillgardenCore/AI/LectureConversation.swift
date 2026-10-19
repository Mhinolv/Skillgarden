import CryptoKit
import Foundation

/// The state of one saved Q&A turn (#127). The #128 Q&A panel shows `label` under the answer.
public enum QATurnStatus: Equatable, Hashable, Sendable {
    /// The question and an empty answer are saved before the request starts.
    case pending
    case complete
    /// The learner cancelled. The partial answer stays.
    case cancelled
    /// The request ended with no answer. `reason` is the learner text of the outcome.
    case failed(reason: String)
    /// The app stopped while the turn was pending.
    case interrupted

    /// The status of a turn whose request ended with `outcome`.
    public init(outcome: AnswerOutcome) {
        switch outcome {
        case .finished: self = .complete
        case .canceled: self = .cancelled
        default: self = .failed(reason: outcome.learnerText ?? "")
        }
    }

    /// The design-note label. Nil for a complete turn and for the draft bubble of a pending turn.
    public var label: String? {
        switch self {
        case .pending, .complete: nil
        case .cancelled: "Cancelled"
        case .failed(let reason): "No answer: \(reason)"
        case .interrupted: "Interrupted"
        }
    }

    /// The SF Symbol of `label`.
    public var systemImage: String? {
        switch self {
        case .pending, .complete: nil
        case .cancelled: "stop.circle"
        case .failed, .interrupted: "exclamationmark.triangle"
        }
    }

    /// True for a turn that ended without a full answer. Retry asks the question again as a new turn.
    var isRetryable: Bool {
        switch self {
        case .cancelled, .failed, .interrupted: true
        case .pending, .complete: false
        }
    }
}

/// One question of the learner and its answer (#127).
public struct QATurn: Identifiable, Equatable, Hashable, Sendable {
    /// The row id. Ids grow, so a newer turn has a larger id.
    public let id: Int64
    public let question: String
    public let answer: String
    public let status: QATurnStatus
    /// The `LectureContext.sourceRevision` of the lecture text when the learner asked.
    public let sourceRevision: String
    public let askedAt: Date

    public init(id: Int64, question: String, answer: String, status: QATurnStatus, sourceRevision: String, askedAt: Date) {
        self.id = id
        self.question = question
        self.answer = answer
        self.status = status
        self.sourceRevision = sourceRevision
        self.askedAt = askedAt
    }

    /// One accessibility element for the turn: "Question: …", then "Answer: …, <status>".
    public var accessibilityLabel: String { accessibilityLabel(answer: answer) }

    /// The same label with the answer as the panel shows it: numbered source markers in place of passage IDs (#129).
    public func accessibilityLabel(answer: String) -> String {
        var answerText = "Answer: \(answer)"
        if let label = status.label { answerText += ", \(label)" }
        return "Question: \(question). \(answerText)"
    }
}

/// The saved Q&A thread of one lecture, oldest turn first (#127).
/// Turns asked about an earlier version of the lecture text stay visible, but no prompt uses them.
public struct LectureConversation: Equatable, Sendable {
    public let turns: [QATurn]
    /// The source revision of the current lecture text. Nil when the lecture has no context now.
    public let sourceRevision: String?

    public init(turns: [QATurn], sourceRevision: String?) {
        self.turns = turns
        self.sourceRevision = sourceRevision
    }

    /// True when the lecture text changed after the learner asked. With no current revision no turn is earlier,
    /// because the text can be unreadable for a short time.
    public func isEarlierVersion(_ turn: QATurn) -> Bool {
        sourceRevision.map { turn.sourceRevision != $0 } ?? false
    }

    /// The turns above the "Earlier version of this lecture" divider. The divider shows only when this is not empty.
    public var earlierTurns: [QATurn] { turns.filter(isEarlierVersion) }

    /// The turns below the divider. New turns go here.
    public var currentTurns: [QATurn] { turns.filter { !isEarlierVersion($0) } }

    /// Retry shows on a cancelled, failed or interrupted turn of the current version only.
    public func canRetry(_ turn: QATurn) -> Bool {
        turn.status.isRetryable && !isEarlierVersion(turn)
    }

    /// The prompt of `context` for the question, with the saved turns in its messages. Nil when the prompt has no evidence,
    /// so the app sends no request and shows `LecturePrompt.noEvidenceText`.
    /// The questions of the current-version turns, oldest first, help retrieval. The messages are the system prompt,
    /// then the newest complete turns of this lecture version that fit the free tokens, oldest first, then the question.
    /// Earlier-version turns and turns without a full answer are never in the prompt.
    /// Retrieval on a long lecture fills the passage budget, so it keeps free the tokens of the newest complete turns,
    /// up to a quarter of the passage budget.
    public func prompt(context: LectureContext, question: String) -> LecturePrompt? {
        let current = turns.filter { $0.sourceRevision == context.sourceRevision }
        let complete = current.filter { $0.status == .complete }
        func cost(_ turn: QATurn) -> Int {
            LectureContextBudget.estimatedTokens(turn.question) + LectureContextBudget.estimatedTokens(turn.answer)
        }
        let budget = context.budget
        var reserve = 0
        for turn in complete.reversed() {
            guard reserve + cost(turn) <= budget.promptTokens / 4 else { break }
            reserve += cost(turn)
        }
        let prompt = context.prompt(question: question, priorQuestions: current.map(\.question), historyTokens: reserve)
        guard !prompt.noEvidence else { return nil }
        var free = budget.contextTokens - budget.answerTokens
            - max(budget.questionTokens, LectureContextBudget.estimatedTokens(question)) - prompt.estimatedTokens
        var history: [ChatMessage] = []
        for turn in complete.reversed() {
            guard cost(turn) <= free else { break }
            free -= cost(turn)
            history.insert(contentsOf: [ChatMessage(role: .user, content: turn.question),
                                        ChatMessage(role: .assistant, content: turn.answer)], at: 0)
        }
        return LecturePrompt(passages: prompt.passages, systemPrompt: prompt.systemPrompt,
                             messages: [ChatMessage(role: .system, content: prompt.systemPrompt)] + history
                                 + [ChatMessage(role: .user, content: question)],
                             isPartial: prompt.isPartial, noEvidence: false)
    }
}

extension LectureContext {
    /// A SHA-256 of the passage IDs and text. It changes only when the text of the lecture changes,
    /// so a republish with the same lecture text keeps the saved turns current.
    static func sourceRevision(of passages: [LecturePassage]) -> String {
        var hash = SHA256()
        for passage in passages {
            hash.update(data: Data(passage.id.utf8))
            hash.update(data: Data([0x1F]))
            hash.update(data: Data(passage.text.utf8))
            hash.update(data: Data([0x1E]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
