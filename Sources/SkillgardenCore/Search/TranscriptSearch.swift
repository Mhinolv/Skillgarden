import Foundation

/// One indexed caption cue of a video lecture (#18). Publish writes these rows from the lecture `.vtt` file.
public struct TranscriptCue: Equatable, Sendable {
    public let lectureID: String
    /// The index of the line in the lecture transcript (#13), so `Transcript.lines[index]` is this cue.
    public let index: Int
    public let start: Double
    public let end: Double
    /// The line breaks of the cue are spaces, as in the transcript.
    public let text: String

    public init(lectureID: String, index: Int, start: Double, end: Double, text: String) {
        self.lectureID = lectureID
        self.index = index
        self.start = start
        self.end = end
        self.text = text
    }

    /// The cues of one lecture, in transcript order. Cues with no text are left out.
    public static func cues(lectureID: String, captions: WebVTT) -> [TranscriptCue] {
        Transcript(captions: captions).lines.map {
            TranscriptCue(lectureID: lectureID, index: $0.id, start: $0.start, end: $0.end, text: $0.text)
        }
    }
}

/// One search result: a cue that contains the query.
public struct TranscriptHit: Equatable, Sendable, Identifiable {
    public let sectionID: String
    public let lectureID: String
    public let lectureTitle: String
    public let cueIndex: Int
    public let start: Double
    /// The cue text. A long cue starts with "…" near the first match, so two lines show the match.
    public let snippet: String
    /// The matches of the query in `snippet`.
    public let matches: [Range<String.Index>]

    public var id: String { "\(lectureID)#\(cueIndex)" }

    /// `m:ss`, or `h:mm:ss` for one hour or more, as in the transcript.
    public var timeLabel: String { LectureVideo.durationLabel(seconds: Int(start)) }

    /// "<lecture title>, <time>, <snippet>".
    public var accessibilityLabel: String { "\(lectureTitle), \(timeLabel), \(snippet)" }

    public var destination: CourseDestination { .lecture(sectionID: sectionID, lectureID: lectureID) }
}

/// The results of one lecture.
public struct TranscriptSearchGroup: Equatable, Sendable, Identifiable {
    public let sectionID: String
    public let sectionTitle: String
    public let lectureID: String
    public let lectureTitle: String
    /// In cue order.
    public let hits: [TranscriptHit]

    public var id: String { lectureID }
}

/// The transcript search of one course (#18).
public struct TranscriptSearchResults: Equatable, Sendable {
    public let query: String
    /// In course order. Empty if no cue contains the query.
    public let groups: [TranscriptSearchGroup]
    /// False if no learner lecture of the course has an indexed cue.
    public let hasTranscripts: Bool

    public var hitCount: Int { groups.reduce(0) { $0 + $1.hits.count } }

    /// "12 results in 3 lectures".
    public var summary: String {
        let hits = hitCount, lectures = groups.count
        return "\(hits) \(hits == 1 ? "result" : "results") in \(lectures) \(lectures == 1 ? "lecture" : "lectures")"
    }

    public var hits: [TranscriptHit] { groups.flatMap(\.hits) }
}

public enum TranscriptSearch {
    /// A shorter query shows the outline.
    public static let minimumQueryLength = 2
    /// The wait after the last key press before the search runs.
    public static let debounce: Duration = .milliseconds(200)
    /// A cue longer than this starts near its first match.
    static let snippetLength = 120
    /// The characters of context before the first match in a cut snippet.
    static let snippetContext = 40

    /// The trimmed query, or nil if it is shorter than `minimumQueryLength`.
    public static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumQueryLength ? trimmed : nil
    }

    /// Finds the cues of learner lectures that contain the query. Case and diacritics do not matter.
    /// Cues of draft or unknown lectures are left out. Returns nil for a short query.
    /// A cancelled task stops the scan and gets nil (#216).
    public static func search(_ query: String, course: Course, cues: [TranscriptCue]) -> TranscriptSearchResults? {
        guard let query = normalizedQuery(query) else { return nil }
        let byLecture = Dictionary(grouping: cues, by: \.lectureID)
        var hasTranscripts = false
        var groups: [TranscriptSearchGroup] = []
        // A lecture id can repeat in two sections. The first one wins, as in the outline.
        var seen: Set<String> = []
        for section in course.learnerSections {
            for lecture in section.lectures where seen.insert(lecture.id).inserted {
                if Task.isCancelled { return nil }
                guard let lectureCues = byLecture[lecture.id], !lectureCues.isEmpty else { continue }
                hasTranscripts = true
                let hits = lectureCues.sorted { $0.index < $1.index }.compactMap { cue -> TranscriptHit? in
                    guard let (snippet, matches) = snippet(cue.text, query: query) else { return nil }
                    return TranscriptHit(sectionID: section.id, lectureID: lecture.id, lectureTitle: lecture.title,
                                         cueIndex: cue.index, start: cue.start, snippet: snippet, matches: matches)
                }
                if !hits.isEmpty {
                    groups.append(TranscriptSearchGroup(sectionID: section.id, sectionTitle: section.title,
                                                        lectureID: lecture.id, lectureTitle: lecture.title, hits: hits))
                }
            }
        }
        return TranscriptSearchResults(query: query, groups: groups, hasTranscripts: hasTranscripts)
    }

    /// `search` off the main actor (#216). A nonisolated async function runs on the global executor,
    /// and the cancellation of the calling task stops the scan.
    public nonisolated static func searchInBackground(_ query: String, course: Course,
                                                      cues: [TranscriptCue]) async -> TranscriptSearchResults? {
        search(query, course: course, cues: cues)
    }

    /// The snippet of `text` and the matches of `query` in it. Nil if the text does not contain the query.
    static func snippet(_ text: String, query: String) -> (String, [Range<String.Index>])? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let first = text.range(of: query, options: options) else { return nil }
        var snippet = text
        let offset = text.distance(from: text.startIndex, to: first.lowerBound)
        if text.count > snippetLength, offset > snippetContext {
            // Start the cut at a word start, so the snippet does not begin inside a word.
            var start = text.index(first.lowerBound, offsetBy: -snippetContext)
            if let space = text[start..<first.lowerBound].firstIndex(where: \.isWhitespace) {
                start = text.index(after: space)
            }
            snippet = "…" + text[start...]
        }
        var matches: [Range<String.Index>] = []
        var rest = snippet.startIndex..<snippet.endIndex
        while let match = snippet.range(of: query, options: options, range: rest) {
            matches.append(match)
            rest = match.upperBound..<snippet.endIndex
        }
        return (snippet, matches)
    }
}
