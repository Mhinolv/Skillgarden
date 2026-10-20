import Foundation

/// One source of an answer in the Q&A panel (#129). Only a valid source has an action. The model text gives only the
/// passage ID: the time and the excerpt come from the stored passage of the lecture.
public struct AnswerSource: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: Equatable, Hashable, Sendable {
        /// A transcript cue of the open video. `seconds` is the stored cue start.
        case video(seconds: Double, cueText: String)
        /// An article block of the open lecture.
        case article(excerpt: String)
        /// A passage ID of a turn asked about an earlier version of the lecture text.
        case stale
        /// A marker with no passage in this lecture: a wrong ID, an ID of another lecture or a made-up ID.
        case unknown
    }

    /// The `[1]`, `[2]` number in order of first use. Nil for the one unknown source.
    public let number: Int?
    public let kind: Kind

    /// The chip text, for example "1 · 4:12", "1 · Excerpt" or "? · Unknown source". It is made once, with the source (#168).
    public let title: String
    /// The VoiceOver label of the chip in the current locale. It is made once, with the source (#168).
    public let accessibilityText: String

    public init(number: Int?, kind: Kind) {
        self.number = number
        self.kind = kind
        title = Self.title(number: number, kind: kind)
        accessibilityText = Self.accessibilityLabel(number: number, kind: kind, locale: .current)
    }

    public var id: String { Self.id(number) }

    private static func id(_ number: Int?) -> String { number.map(String.init) ?? "?" }

    /// True for a video seek or an article excerpt. Stale and unknown sources are plain labels.
    public var isActionable: Bool {
        switch kind {
        case .video, .article: true
        case .stale, .unknown: false
        }
    }

    private static func title(number: Int?, kind: Kind) -> String {
        let id = id(number)
        return switch kind {
        case .video(let seconds, _): "\(id) · \(LectureVideo.durationLabel(seconds: Int(seconds)))"
        case .article: "\(id) · Excerpt"
        case .stale: "\(id) · Earlier version"
        case .unknown: "? · Unknown source"
        }
    }

    /// The tooltip: the cue text of a video source (120 characters at most), or why a label has no action.
    public var help: String? {
        switch kind {
        case .video(_, let cueText): Self.shortened(cueText, limit: 120)
        case .article: nil
        case .stale: "This source is from an earlier version of the lecture."
        case .unknown: "This lecture has no source with this name."
        }
    }

    /// The VoiceOver label in `locale`. The panel uses `accessibilityText`.
    public func accessibilityLabel(locale: Locale = .current) -> String {
        Self.accessibilityLabel(number: number, kind: kind, locale: locale)
    }

    private static func accessibilityLabel(number: Int?, kind: Kind, locale: Locale) -> String {
        let id = id(number)
        return switch kind {
        case .video(let seconds, _):
            "Source \(id), at \(LectureVideo.spokenDuration(seconds: Int(seconds), locale: locale).replacingOccurrences(of: ",", with: ""))"
        case .article: "Source \(id), excerpt"
        case .stale: "Source \(id), not available"
        case .unknown: "Unknown source, not available"
        }
    }

    public var accessibilityHint: String? {
        switch kind {
        case .video: "Shows this moment in the video. Playback pauses."
        case .article: "Shows the excerpt."
        case .stale, .unknown: nil
        }
    }

    static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The source markers of one answer (#129), checked against the passages of the lecture text that the learner asked about.
/// `[t12]` becomes `[1]` in order of first use. The answer never shows a raw passage ID, a link or a time from the model.
/// Video markers merge only for display (#171). The stored answer text keeps the raw IDs.
public struct AnswerCitations: Equatable, Sendable {
    /// A part of the answer text.
    public enum Segment: Equatable, Sendable {
        case text(String)
        /// A marker as the learner sees it: `[1]`, or `[?]` for an unknown source.
        case marker(AnswerSource)
    }

    public let segments: [Segment]
    /// One source for each distinct number in order, then one unknown source if the answer has an unknown marker.
    /// Empty when the answer has no markers, so the panel shows no Sources row.
    public let sources: [AnswerSource]

    /// `context` is the lecture context of the panel. `isStale` is true for a turn of an earlier version of the lecture
    /// text (#127), so its markers have no action. With no context, each marker is unknown.
    public init(answer: String, context: LectureContext?, isStale: Bool) {
        var segments: [Segment] = []
        var numbers: [String: AnswerSource] = [:]
        var sources: [AnswerSource] = []
        var unknown: AnswerSource?
        var rest = answer[...]
        func source(for passageID: String) -> AnswerSource {
            if let known = numbers[passageID] { return known }
            let kind: AnswerSource.Kind
            if let context, let passage = context.passage(id: passageID) {
                if isStale {
                    kind = .stale
                } else if let seconds = context.seekTimes[passageID] {
                    kind = .video(seconds: seconds, cueText: passage.text)
                } else if passageID.hasPrefix("a") {
                    kind = .article(excerpt: passage.text)
                } else {
                    kind = .unknown
                }
            } else {
                kind = .unknown
            }
            guard kind != .unknown else {
                let value = unknown ?? AnswerSource(number: nil, kind: .unknown)
                unknown = value
                return value
            }
            let value = AnswerSource(number: numbers.count + 1, kind: kind)
            numbers[passageID] = value
            sources.append(value)
            return value
        }
        // #171: the video sources cited in the current line. A later cue in the same line within the merge window
        // shows the number of the earlier cue.
        var anchors: [AnswerSource] = []
        func seekTime(of passageID: String) -> Double? {
            guard !isStale, let context, context.passage(id: passageID) != nil else { return nil }
            return context.seekTimes[passageID]
        }
        func videoSource(for passageID: String, seconds: Double) -> AnswerSource {
            if numbers[passageID] == nil, let anchor = anchors.first(where: {
                guard case .video(let start, _) = $0.kind else { return false }
                return seconds >= start && seconds - start <= Self.mergeSeconds
            }) {
                return anchor
            }
            let value = source(for: passageID)
            if !anchors.contains(value) { anchors.append(value) }
            return value
        }
        let matches = answer.matches(of: Self.marker)
        var index = matches.startIndex
        while index < matches.endIndex {
            let before = rest[..<matches[index].range.lowerBound]
            if !before.isEmpty { segments.append(.text(String(before))) }
            if before.contains(where: \.isNewline) { anchors = [] }
            // A group is a marker list or markers with only spaces between them, such as `[t5] [t6]`.
            var group: [(leading: Substring, passageIDs: [String])] = []
            var end = index
            repeat {
                let match = matches[end]
                let leading = end == index ? answer[match.range.lowerBound..<match.range.lowerBound]
                    : answer[matches[end - 1].range.upperBound..<match.range.lowerBound]
                group.append((leading, Self.passageIDs(of: match)))
                end += 1
            } while end < matches.endIndex
                && answer[matches[end - 1].range.upperBound..<matches[end].range.lowerBound].allSatisfy { $0 == " " || $0 == "\t" }
            // A group keeps only its earliest video cue. Stale, unknown and article markers do not change.
            let earliest = group.flatMap(\.passageIDs).compactMap { id in seekTime(of: id).map { (id, $0) } }
                .min { $0.1 < $1.1 }
            var hasVideo = false
            for item in group {
                var markers: [AnswerSource] = []
                for passageID in item.passageIDs {
                    guard seekTime(of: passageID) != nil else {
                        markers.append(source(for: passageID))
                        continue
                    }
                    guard !hasVideo, let earliest else { continue }
                    hasVideo = true
                    markers.append(videoSource(for: earliest.0, seconds: earliest.1))
                }
                guard !markers.isEmpty else { continue }
                if !item.leading.isEmpty { segments.append(.text(String(item.leading))) }
                segments += markers.map(Segment.marker)
            }
            rest = answer[matches[end - 1].range.upperBound...]
            index = end
        }
        if !rest.isEmpty { segments.append(.text(String(rest))) }
        self.segments = segments
        self.sources = sources + (unknown.map { [$0] } ?? [])
        styled = Self.styled(segments)
    }

    /// `[t12]`, `[a3]` and lists such as `[t1, t2]`. A letter must come first, so `[1]` and `[x]` stay plain text.
    nonisolated(unsafe) static let marker = /\[\s*([A-Za-z]{1,3}\d{1,6}(?:\s*[,;]\s*[A-Za-z]{1,3}\d{1,6})*)\s*\]/

    /// A video cue that starts this many seconds or less after a cue cited in the same line shows the number of that cue (#171).
    static let mergeSeconds: Double = 30

    /// The passage IDs of the markers in `answer`, in order, before the #171 merge. The #130 check grades citations with them.
    static func passageIDs(in answer: String) -> [String] {
        answer.matches(of: marker).flatMap(passageIDs(of:))
    }

    private static func passageIDs(of match: Regex<(Substring, Substring)>.Match) -> [String] {
        match.output.1.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The marker text: `[1]`, or `[?]`.
    public static func markerText(_ source: AnswerSource) -> String {
        "[\(source.id)]"
    }

    /// The answer as the learner sees it (#158): inline Markdown styles, no links and numbered markers.
    /// Each marker run has `AnswerMarkerAttribute`, so the panel can color it.
    public let styled: AttributedString

    /// The answer as the learner sees it, with numbered markers and no Markdown syntax.
    public var text: String { String(styled.characters) }

    /// Parses the full answer once with a placeholder for each marker, so a marker inside `**…**` is also bold.
    /// Links become text, as in the article excerpt. An open `**` in a draft stays text until it closes.
    /// Each marker is one private-use character, so a marker that the parse drops (for example in a link address)
    /// does not move the other markers.
    private static func styled(_ segments: [Segment]) -> AttributedString {
        let placeholders: ClosedRange<UInt32> = 0xE000...0xF8FF
        func isPlaceholder(_ scalar: Unicode.Scalar) -> Bool { placeholders.contains(scalar.value) }
        var markdown = ""
        var markers: [AnswerSource] = []
        for segment in segments {
            switch segment {
            case .text(let value): markdown.unicodeScalars.append(contentsOf: value.unicodeScalars.filter { !isPlaceholder($0) })
            case .marker(let source):
                // Markers after the last placeholder show as plain text. An answer has far fewer markers.
                guard let scalar = Unicode.Scalar(placeholders.lowerBound + UInt32(markers.count)), isPlaceholder(scalar) else {
                    markdown += markerText(source)
                    continue
                }
                markdown.unicodeScalars.append(scalar)
                markers.append(source)
            }
        }
        let parsed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        var styled = AttributedString()
        for run in parsed.runs {
            var attributes = run.attributes
            attributes.link = nil
            var text = ""
            func flush() {
                if !text.isEmpty { styled += AttributedString(text, attributes: attributes) }
                text = ""
            }
            for scalar in parsed.unicodeScalars[run.range] {
                guard isPlaceholder(scalar) else {
                    text.unicodeScalars.append(scalar)
                    continue
                }
                flush()
                let source = markers[Int(scalar.value - placeholders.lowerBound)]
                var marker = AttributedString(markerText(source), attributes: attributes)
                marker[AnswerMarkerAttribute.self] = source
                styled += marker
            }
            flush()
        }
        return styled
    }
}

/// The source of a marker run in `AnswerCitations.styled` (#158).
public enum AnswerMarkerAttribute: AttributedStringKey {
    public typealias Value = AnswerSource
    public static let name = "SkillgardenAnswerMarker"
}
