import Foundation

/// The prompt for one learner question (#126). If all the lecture text fits the budget, it holds all passages.
/// If not, it holds the passages that match the question best, and their neighbors when the budget allows.
public struct LecturePrompt: Equatable, Sendable {
    /// The fixed answer of the #128 Q&A panel when `noEvidence` is true. The app sends no request then.
    public static let noEvidenceText = "No part of this lecture matches your question. Try words that the lecture uses."

    /// The passages in the prompt, in lecture order, with their original cue and block IDs. Empty when `noEvidence` is true.
    public let passages: [LecturePassage]
    /// The system message. Empty when `noEvidence` is true.
    public let systemPrompt: String
    /// The chat request: the system prompt, then the question. Empty when `noEvidence` is true.
    public let messages: [ChatMessage]
    /// True when the prompt leaves out parts of the lecture. The app shows "Based on parts of this lecture".
    public let isPartial: Bool
    /// True when no passage of a long lecture matches the question.
    public let noEvidence: Bool

    static let noEvidence = LecturePrompt(passages: [], systemPrompt: "", messages: [], isPartial: false, noEvidence: true)

    init(passages: [LecturePassage], systemPrompt: String, messages: [ChatMessage], isPartial: Bool, noEvidence: Bool) {
        self.passages = passages
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.isPartial = isPartial
        self.noEvidence = noEvidence
    }

    public var estimatedTokens: Int { LectureContextBudget.estimatedTokens(systemPrompt) }
}

/// Lexical retrieval over the passages of a long lecture (#126). There are no embeddings and no vector store.
/// Consecutive cues or blocks make bounded windows that overlap. BM25 ranks the windows against the question terms.
struct LectureRetrievalIndex: Sendable {
    /// The most bytes of prompt lines in one window. A cue or block that is larger is a window alone.
    static let windowBytes = 600
    /// The most bytes that a window shares with the window before it.
    static let overlapBytes = 150
    /// The weight of a term that only an earlier question of the learner has.
    static let priorWeight = 0.5

    /// The bytes of each passage as a prompt line `\n[<id>] <text>`.
    let lineBytes: [Int]
    /// The passage indices of each window, in lecture order.
    let windows: [Range<Int>]
    private let termCounts: [[String: Int]]
    private let lengths: [Int]
    private let documentFrequency: [String: Int]
    private let averageLength: Double

    init(passages: [LecturePassage]) {
        let lineBytes = passages.map { LectureContext.line($0).utf8.count }
        self.lineBytes = lineBytes
        var windows: [Range<Int>] = []
        var start = 0
        while start < passages.count {
            var end = start + 1, bytes = lineBytes[start]
            while end < passages.count, bytes + lineBytes[end] <= Self.windowBytes {
                bytes += lineBytes[end]
                end += 1
            }
            windows.append(start..<end)
            guard end < passages.count else { break }
            // The next window starts with the last passages of this one, so a fact at the edge has its context.
            var next = end, overlap = 0
            while next - 1 > start, overlap + lineBytes[next - 1] <= Self.overlapBytes {
                next -= 1
                overlap += lineBytes[next]
            }
            start = next
        }
        self.windows = windows
        let passageTerms = passages.map { Self.terms($0.text) }
        var termCounts: [[String: Int]] = [], lengths: [Int] = [], documentFrequency: [String: Int] = [:]
        for window in windows {
            var counts: [String: Int] = [:]
            for index in window { for term in passageTerms[index] { counts[term, default: 0] += 1 } }
            for term in counts.keys { documentFrequency[term, default: 0] += 1 }
            termCounts.append(counts)
            lengths.append(counts.values.reduce(0, +))
        }
        self.termCounts = termCounts
        self.lengths = lengths
        self.documentFrequency = documentFrequency
        averageLength = windows.isEmpty ? 1 : max(1, Double(lengths.reduce(0, +)) / Double(windows.count))
    }

    /// The windows with a score above 0, best first. Equal scores keep lecture order.
    func ranked(question: String, priorQuestions: [String]) -> [Int] {
        var weights: [String: Double] = [:]
        for prior in priorQuestions { for term in Self.terms(prior) { weights[term] = Self.priorWeight } }
        for term in Self.terms(question) { weights[term] = 1 }
        guard !weights.isEmpty else { return [] }
        let count = Double(windows.count), k1 = 1.2, b = 0.75
        let scores = termCounts.indices.map { window -> Double in
            let length = Double(lengths[window])
            return weights.reduce(0) { score, entry in
                guard let tf = termCounts[window][entry.key].map(Double.init) else { return score }
                let df = Double(documentFrequency[entry.key] ?? 0)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                return score + entry.value * idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * length / averageLength))
            }
        }
        return scores.indices.filter { scores[$0] > 0 }.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
    }

    /// The passage indices that fit `limitBytes`: the ranked windows first, then rings of neighbors around them.
    /// Nil when no matched window fits.
    func select(question: String, priorQuestions: [String], limitBytes: Int) -> [Int]? {
        var chosen = Set<Int>(), usedBytes = 0, added = Set<Int>()
        func add(_ window: Int) -> Bool {
            guard !added.contains(window) else { return false }
            let new = windows[window].filter { !chosen.contains($0) }
            let bytes = new.reduce(0) { $0 + lineBytes[$1] }
            guard usedBytes + bytes <= limitBytes else { return false }
            chosen.formUnion(new)
            usedBytes += bytes
            added.insert(window)
            return true
        }
        let matches = ranked(question: question, priorQuestions: priorQuestions).filter(add)
        guard !matches.isEmpty else { return nil }
        var distance = 1, grew = true
        while grew, distance < windows.count {
            grew = false
            for window in matches {
                for neighbor in [window - distance, window + distance] where windows.indices.contains(neighbor) {
                    if add(neighbor) { grew = true }
                }
            }
            distance += 1
        }
        return chosen.sorted()
    }

    /// Words without case or accents, with stop words and one-letter words left out, and a simple plural stem.
    static func terms(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap { word in
                let word = String(word)
                guard word.count > 1, !stopWords.contains(word) else { return nil }
                if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
                if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
                    return String(word.dropLast())
                }
                return word
            }
    }

    private static let stopWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "been",
        "before", "being", "both", "but", "by", "can", "could", "did", "do", "does", "doing", "each", "explain", "for",
        "from", "had", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its",
        "just", "me", "more", "most", "my", "no", "not", "of", "on", "only", "or", "other", "our", "please", "say", "said",
        "she", "should", "so", "some", "tell", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "those", "to", "too", "us", "very", "was", "we", "were", "what", "when", "where", "which", "who", "whom",
        "why", "will", "with", "would", "you", "your",
    ]
}

extension LectureContext {
    /// The prompt for a question of the learner (#126). `priorQuestions` are the earlier questions about this lecture,
    /// oldest first. Their terms help a short follow-up question, such as "Why?", find its passages.
    /// The system prompt and the question fit the budget together. A question longer than its share takes from the passages.
    public func prompt(question: String, priorQuestions: [String] = []) -> LecturePrompt {
        let limit = budget.contextTokens - budget.answerTokens - max(budget.questionTokens, LectureContextBudget.estimatedTokens(question))
        let full = Self.systemPrompt(courseTitle: courseTitle, lectureTitle: lectureTitle, passages: passages, isPartial: false)
        if LectureContextBudget.estimatedTokens(full) <= limit {
            return LecturePrompt(passages: passages, systemPrompt: full, messages: Self.messages(full, question),
                                 isPartial: false, noEvidence: false)
        }
        // The framing with the longest passage ID as its example is the most bytes that the framing can use.
        // `estimatedTokens` is (bytes + 2) / 3, so a prompt of 3 * limit bytes or fewer fits.
        let longestID = passages.map(\.id).max { $0.utf8.count < $1.utf8.count } ?? ""
        let framing = Self.framing(courseTitle: courseTitle, lectureTitle: lectureTitle, exampleID: longestID, isPartial: true).utf8.count
        let index = retrievalIndex ?? LectureRetrievalIndex(passages: passages)
        guard let selected = index.select(question: question, priorQuestions: priorQuestions, limitBytes: 3 * limit - framing)
        else { return .noEvidence }
        let chosen = selected.map { passages[$0] }
        let system = Self.systemPrompt(courseTitle: courseTitle, lectureTitle: lectureTitle, passages: chosen,
                                       isPartial: chosen.count < passages.count)
        return LecturePrompt(passages: chosen, systemPrompt: system, messages: Self.messages(system, question),
                             isPartial: chosen.count < passages.count, noEvidence: false)
    }

    private static func messages(_ system: String, _ question: String) -> [ChatMessage] {
        [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: question)]
    }
}
