import Foundation

/// Removes an echo of the system prompt from an answer before the learner sees it and before the save (#192).
/// A model can repeat the framing of `LectureContext.framing` or the `[<id>] <text>` passage lines of the prompt.
/// The guard removes each answer line that holds an echo. The other lines stay. A quote of one or two passages after
/// their IDs is not an echo (#198).
public struct PromptEchoGuard: Sendable {
    /// The failure reason of a turn whose whole answer was an echo. The turn label is "No answer: <reason>".
    public static let echoText = "The model repeated its instructions. Try again."

    /// Folded text shorter than this can be a normal answer, so it matches only a full framing line.
    static let minimumMatch = 16
    /// A streamed line that ends with this much of the start of a framing sentence waits for more text.
    static let minimumPartialMatch = 12

    private let context: LectureContext
    /// The folded framing, with and without the partial-lecture sentence.
    private let framings: [String]
    /// The folded lines and sentences of the framing.
    private let framingParts: Set<String>

    public init(context: LectureContext) {
        self.context = context
        let texts = [false, true].map {
            LectureContext.framing(courseTitle: context.courseTitle, lectureTitle: context.lectureTitle, exampleID: "t0", isPartial: $0)
        }
        framings = texts.map(Self.folded)
        let lines = texts.flatMap { $0.components(separatedBy: .newlines) }
        let sentences = lines.flatMap {
            $0.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression).components(separatedBy: "\n")
        }
        framingParts = Set((lines + sentences).map(Self.folded).filter { !$0.isEmpty })
    }

    /// Lowercase letters and digits only, with no text in square brackets, so an ID or a format change does not hide an echo.
    /// A bracket that a draft has not closed yet counts as closed.
    static func folded(_ text: String) -> String {
        let text = text.replacingOccurrences(of: #"\[[^\]]*(\]|$)"#, with: "", options: .regularExpression)
        return String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// True when the answer holds an echo of the system prompt.
    public func holdsEcho(_ answer: String) -> Bool {
        clean(answer) != answer
    }

    /// A group of this many `[<id>] <text>` passage lines in a row is a passage list of the prompt (#198). A valid answer
    /// can quote one or two passages after their IDs.
    static let minimumPassageList = 3

    /// The answer with no line of the system prompt. With `isComplete` false, `answer` is a draft: its last line can
    /// still grow, so it waits while it can be the start of an echo. The text is the same when it holds no echo.
    public func clean(_ answer: String, isComplete: Bool = true) -> String {
        let lines = answer.components(separatedBy: "\n")
        let removed = removedLines(lines, isComplete: isComplete)
        guard removed.contains(true) else { return answer }
        return zip(lines, removed).filter { !$1 }.map(\.0).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer with `mask` in place of each group of removed lines, for the results file of the check (#198).
    /// Empty lines between removed lines are part of the group. The text is the same when it holds no echo.
    func masked(_ answer: String, with mask: String) -> String {
        let lines = answer.components(separatedBy: "\n")
        let removed = removedLines(lines, isComplete: true)
        guard removed.contains(true) else { return answer }
        var result: [String] = []
        /// The empty lines after the last mask. They go into the result only when a kept line follows.
        var empty: [String] = []
        var lastIsMask = false
        for (line, isRemoved) in zip(lines, removed) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                empty.append(line)
            } else if isRemoved {
                if !lastIsMask { result += empty + [mask] }
                empty = []
                lastIsMask = true
            } else {
                result += empty + [line]
                empty = []
                lastIsMask = false
            }
        }
        return (result + empty).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for each line of the system prompt. A group of passage lines is an echo when it lists `minimumPassageList`
    /// passages or more, or when it comes after a line of the framing.
    private func removedLines(_ lines: [String], isComplete: Bool) -> [Bool] {
        var removed = Array(repeating: false, count: lines.count)
        /// The folded next lines of the passage of the last passage line. A list passage has more than one line.
        var passageLines: ArraySlice<String> = []
        /// The current group of passage lines: the line indexes, the number of passages and if a framing line is before it.
        var group: [Int] = []
        var groupPassages = 0
        var groupFollowsEcho = false
        /// True when the last line with text was a line of the framing.
        var lastIsEcho = false
        func endGroup() {
            if groupFollowsEcho || groupPassages >= Self.minimumPassageList { group.forEach { removed[$0] = true } }
            group = []
            groupPassages = 0
        }
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let isDraftLine = !isComplete && index == lines.count - 1
            let text = Self.folded(line)
            if let next = passageLines.first, !text.isEmpty, isDraftLine ? next.hasPrefix(text) : text == next {
                passageLines.removeFirst()
                group.append(index)
                continue
            }
            passageLines = []
            if let passage = passage(line, isComplete: !isDraftLine) {
                passageLines = passage.text.components(separatedBy: .newlines).dropFirst().map(Self.folded).filter { !$0.isEmpty }[...]
                if group.isEmpty { groupFollowsEcho = lastIsEcho }
                group.append(index)
                groupPassages += 1
                continue
            }
            endGroup()
            lastIsEcho = isEcho(line) || (isDraftLine && mayStartEcho(line))
            removed[index] = lastIsEcho
        }
        endGroup()
        return removed
    }

    /// True for a line of the framing, a part of the framing, or a line with a framing sentence.
    private func isEcho(_ line: String) -> Bool {
        let text = Self.folded(line)
        guard !text.isEmpty else { return false }
        if framingParts.contains(text) { return true }
        if text.count >= Self.minimumMatch, framings.contains(where: { $0.contains(text) }) { return true }
        return framingParts.contains { $0.count >= Self.minimumMatch && text.contains($0) }
    }

    /// True for a draft line that can become an echo: the start of a framing part, or a line that ends with the start
    /// of a framing sentence.
    private func mayStartEcho(_ line: String) -> Bool {
        let text = Self.folded(line)
        guard !text.isEmpty else { return false }
        return framingParts.contains { part in
            if part.hasPrefix(text) { return true }
            let longest = min(part.count, text.count - 1)
            guard longest >= Self.minimumPartialMatch else { return false }
            return (Self.minimumPartialMatch...longest).contains { text.hasSuffix(part.prefix($0)) }
        }
    }

    /// The passage of a `[<id>] <text>` line with the ID of a passage and the start of its text, as in the system prompt.
    /// A draft line also matches while its ID or its text is not complete. A draft ID matches no passage yet.
    private func passage(_ line: String, isComplete: Bool) -> LecturePassage? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("[") else { return nil }
        let draftID = LecturePassage(id: "", label: "", text: "")
        guard let close = line.firstIndex(of: "]") else { return !isComplete && !line.contains(" ") ? draftID : nil }
        guard let passage = context.passage(id: String(line[line.index(after: line.startIndex)..<close])) else { return nil }
        let rest = Self.folded(String(line[line.index(after: close)...]))
        let first = Self.folded(passage.text.components(separatedBy: .newlines).first ?? "")
        if rest.isEmpty { return isComplete ? nil : passage }
        let matches = isComplete ? !first.isEmpty && rest.hasPrefix(first) : first.hasPrefix(rest) || rest.hasPrefix(first)
        return matches ? passage : nil
    }
}
