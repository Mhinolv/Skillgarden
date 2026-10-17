import Foundation

/// One block of an article. Text values keep their inline Markdown (emphasis, code, links).
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `start` is the first number of an ordered list and 1 for a bullet list.
    case list(ordered: Bool, start: Int, items: [String])
    case code(String)
    case quote(String)
    /// An image on a line of its own. `source` is the reference as written in the Markdown.
    case image(source: String, alt: String)
    case rule
}

/// A block parser for article Markdown. `AttributedString(markdown:)` styles only the inline text of each block.
public struct MarkdownDocument: Equatable, Sendable {
    public let blocks: [MarkdownBlock]

    public init(markdown: String) {
        blocks = Self.parse(markdown)
    }

    /// The image references in document order.
    public var imageSources: [String] {
        blocks.compactMap { if case let .image(source, _) = $0 { source } else { nil } }
    }

    public var wordCount: Int {
        blocks.reduce(0) { count, block in
            let text: String = switch block {
            case let .heading(_, text), let .paragraph(text), let .code(text), let .quote(text): text
            case let .list(_, _, items): items.joined(separator: " ")
            case .image, .rule: ""
            }
            return count + text.split(whereSeparator: \.isWhitespace).count
        }
    }

    /// Words / 200, rounded up, minimum 1.
    public var readingMinutes: Int { max(1, (wordCount + 199) / 200) }

    // MARK: Parser

    private static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
            } else if let fence = fence(trimmed) {
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
            } else if let heading = heading(trimmed) {
                blocks.append(heading)
                index += 1
            } else if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
            } else if let image = image(trimmed) {
                blocks.append(image)
                index += 1
            } else if trimmed.hasPrefix(">") {
                var text: [String] = []
                while index < lines.count, case let quoted = lines[index].trimmingCharacters(in: .whitespaces), quoted.hasPrefix(">") {
                    text.append(String(quoted.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(joined(text)))
            } else if let first = listItem(line) {
                var items = [first.text]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if let item = listItem(next), item.ordered == first.ordered {
                        items.append(item.text)
                    } else if next.first?.isWhitespace == true, !next.trimmingCharacters(in: .whitespaces).isEmpty {
                        items[items.count - 1] = joined([items[items.count - 1], next.trimmingCharacters(in: .whitespaces)])
                    } else if next.trimmingCharacters(in: .whitespaces).isEmpty,
                              let following = lines[(index + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                              listItem(following)?.ordered == first.ordered {
                        // A blank line between items keeps one list.
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
            } else {
                var text = [trimmed]
                index += 1
                while index < lines.count, !startsBlock(lines[index]) {
                    text.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.paragraph(joined(text)))
            }
        }
        return blocks
    }

    private static func joined(_ lines: [String]) -> String {
        lines.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// True when the line ends a paragraph: a blank line or the start of another block.
    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || fence(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed)
            || image(trimmed) != nil || trimmed.hasPrefix(">") || listItem(line) != nil
    }

    private static func fence(_ trimmed: String) -> String? {
        ["```", "~~~"].first { trimmed.hasPrefix($0) }
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        // A closing sequence of # is not part of the text.
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "(^|\\s)#+$", options: .regularExpression) { text = String(text[..<range.lowerBound]) }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { !$0.isWhitespace }
        guard let mark = marks.first, "-*_".contains(mark), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    /// `![alt](source)` or `![alt](source "title")` alone on a line.
    private static func image(_ trimmed: String) -> MarkdownBlock? {
        guard let match = trimmed.wholeMatch(of: /!\[(.*)\]\(\s*(<[^>]*>|[^\s)]+)(?:\s+"[^"]*")?\s*\)/) else { return nil }
        var source = String(match.2)
        if source.hasPrefix("<") { source = String(source.dropFirst().dropLast()) }
        return .image(source: source, alt: String(match.1))
    }

    private static func listItem(_ line: String) -> (ordered: Bool, number: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.wholeMatch(of: /[-*+]\s+(.*)/) {
            return (false, 1, String(match.1))
        }
        if let match = trimmed.wholeMatch(of: /(\d{1,9})[.)]\s+(.*)/) {
            return (true, Int(match.1) ?? 1, String(match.2))
        }
        return nil
    }
}
