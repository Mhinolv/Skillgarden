import Foundation

/// One caption cue. Times are in seconds from the start of the video.
public struct CaptionCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct WebVTTError: Error, Equatable, Sendable {
    public let message: String
}

/// Reads the cues of a WebVTT file. The interactive transcript (#13) uses the same parser.
/// Cue settings, NOTE, STYLE and REGION blocks are ignored. Tags such as `<v Name>` are removed from the text.
public struct WebVTT: Equatable, Sendable {
    /// In file order.
    public let cues: [CaptionCue]

    public init(cues: [CaptionCue]) {
        self.cues = cues
    }

    public init(text: String) throws(WebVTTError) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        guard let header = lines.first, header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t") else {
            throw WebVTTError(message: "the file must start with WEBVTT")
        }
        var cues: [CaptionCue] = []
        var block: [String] = []
        func finish() throws(WebVTTError) {
            defer { block = [] }
            // The timing line is the first or, after a cue identifier, the second line of a cue block.
            guard let index = block.prefix(2).firstIndex(where: { $0.contains("-->") }) else { return }
            let parts = block[index].components(separatedBy: "-->")
            // Cue settings follow the end time.
            let end = parts.count == 2 ? parts[1].split(whereSeparator: \.isWhitespace).first.map(String.init) : nil
            guard let end, let start = try Self.seconds(parts[0].trimmingCharacters(in: .whitespaces)),
                  let finish = try Self.seconds(end), finish >= start else {
                throw WebVTTError(message: "invalid cue timing \"\(block[index])\"")
            }
            let text = block[(index + 1)...].map(Self.plainText).joined(separator: "\n")
            cues.append(CaptionCue(start: start, end: finish, text: text))
        }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { try finish() } else { block.append(line) }
        }
        try finish()
        self.cues = cues
    }

    /// The text of the cues at `seconds`, joined with a new line. Nil when no cue shows.
    public func text(at seconds: Double) -> String? {
        let active = cues.filter { $0.start <= seconds && seconds < $0.end && !$0.text.isEmpty }
        return active.isEmpty ? nil : active.map(\.text).joined(separator: "\n")
    }

    /// Reads `hh:mm:ss.ttt` or `mm:ss.ttt`. The hours have two or more digits.
    /// Nil when the format is wrong. Throws when a part is out of range or the whole seconds do not fit in `Int`.
    static func seconds(_ text: String) throws(WebVTTError) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } }) else { return nil }
        let last = parts[parts.count - 1]
        guard last.count == 6, last.dropFirst(2).first == ".", let seconds = Double(last) else { return nil }
        guard parts[parts.count - 2].count == 2, parts.count == 2 || parts[0].count >= 2,
              parts.dropLast().allSatisfy({ !$0.contains(".") }) else { return nil }
        let outOfRange = WebVTTError(message: "cue time \"\(text)\" is out of range")
        let units = parts.dropLast().map { Int($0) }
        guard seconds < 60, let minutes = units.last ?? nil, minutes < 60, let hours = parts.count == 3 ? units[0] : 0 else { throw outOfRange }
        let (hourSeconds, overflow) = hours.multipliedReportingOverflow(by: 3600)
        guard !overflow, hourSeconds.addingReportingOverflow(minutes * 60 + Int(seconds)).overflow == false else { throw outOfRange }
        return Double(hours * 60 + minutes) * 60 + seconds
    }

    private static func plainText(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&amp;", with: "&")
    }
}
