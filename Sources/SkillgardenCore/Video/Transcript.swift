import Foundation

/// The lines of the interactive transcript (#13), made from the caption cues of a video lecture.
public struct Transcript: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        /// The index of the line in `lines`.
        public let id: Int
        public let start: Double
        public let end: Double
        /// The line breaks of the cue become spaces.
        public let text: String

        /// `m:ss`, or `h:mm:ss` for one hour or more.
        public var timeLabel: String { LectureVideo.durationLabel(seconds: Int(start)) }

        /// "<time>, <text>".
        public var accessibilityLabel: String { "\(timeLabel), \(text)" }
    }

    /// In start order. Cues with the same start keep the file order.
    public let lines: [Line]

    /// Cues with no text are left out.
    public init(captions: WebVTT) {
        let cues = captions.cues.enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        lines = cues.enumerated().map { index, cue in
            Line(id: index, start: cue.start, end: cue.end,
                 text: cue.text.split(whereSeparator: \.isNewline).joined(separator: " "))
        }
    }

    /// The index of the active line at `seconds`. If cues overlap, the line that started last is active.
    /// Nil before the first cue and in a gap between cues.
    public func activeLine(at seconds: Double) -> Int? {
        lines.lastIndex { $0.start <= seconds && seconds < $0.end }
    }

    /// `activeLine(at:)` with a binary search (#218). The player builds it once and reads it on each time tick.
    public var activeLineTimeline: CueTimeline<Int> {
        CueTimeline(intervals: lines.map { ($0.start, $0.end) }) { $0.last }
    }
}

/// Auto-scroll of the transcript stops for `pause` seconds after the learner scrolls the panel.
public struct TranscriptAutoScroll: Equatable, Sendable {
    public static let pause: TimeInterval = 5
    private var lastLearnerScroll: Date?

    public init() {}

    public mutating func learnerScrolled(at date: Date) {
        lastLearnerScroll = date
    }

    public func allowsAutoScroll(at date: Date) -> Bool {
        guard let lastLearnerScroll else { return true }
        return date.timeIntervalSince(lastLearnerScroll) >= Self.pause
    }
}
