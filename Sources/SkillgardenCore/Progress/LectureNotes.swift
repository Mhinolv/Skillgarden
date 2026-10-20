import Foundation

/// One plain-text note of the learner on a lecture (#181). A lecture can have many notes.
/// Learner data: Q&A and the lecture context never read it.
public struct LectureNote: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let lectureID: String
    public var text: String
    /// The playback time when the learner started the note. Nil for a note on a lecture that is not a video.
    public let videoSeconds: Double?
    public let createdAt: Date

    public init(id: Int64, lectureID: String, text: String, videoSeconds: Double?, createdAt: Date) {
        self.id = id
        self.lectureID = lectureID
        self.text = text
        self.videoSeconds = videoSeconds
        self.createdAt = createdAt
    }

    /// `m:ss` like a transcript line. Nil for a note with no time.
    public var timeLabel: String? { videoSeconds.map { LectureVideo.durationLabel(seconds: Int($0)) } }

    /// "Note at 3 minutes 41 seconds: <text>", or "Note: <text>" for a note with no time.
    public func accessibilityLabel(locale: Locale = .current) -> String {
        guard let videoSeconds else { return "Note: \(text)" }
        let time = LectureVideo.spokenDuration(seconds: Int(videoSeconds), locale: locale).replacingOccurrences(of: ",", with: "")
        return "Note at \(time): \(text)"
    }

    /// The panel order: video time, then creation order. A note with no time comes after the timed notes.
    public static func panelOrder(_ notes: [LectureNote]) -> [LectureNote] {
        notes.sorted { lhs, rhs in
            switch (lhs.videoSeconds, rhs.videoSeconds) {
            case let (left?, right?) where left != right: left < right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.id < rhs.id
            }
        }
    }

    /// The trimmed text to save, or nil for a note with no text.
    public static func cleanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A time to save: finite and not negative. Other values save no time.
    static func cleanSeconds(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite else { return nil }
        return max(0, seconds)
    }
}

/// The notes of one lecture on the course Notes page (#181).
public struct LectureNoteGroup: Equatable, Identifiable, Sendable {
    public let sectionID: String
    public let sectionTitle: String
    public let lecture: Lecture
    public let notes: [LectureNote]

    public init(sectionID: String, sectionTitle: String, lecture: Lecture, notes: [LectureNote]) {
        self.sectionID = sectionID
        self.sectionTitle = sectionTitle
        self.lecture = lecture
        self.notes = notes
    }

    public var id: String { lecture.id }
    /// "Section · Lecture".
    public var title: String { "\(sectionTitle) · \(lecture.title)" }
    public var destination: CourseDestination { .lecture(sectionID: sectionID, lectureID: lecture.id) }

    /// One group for each learner lecture with notes, in course order. Notes of a lecture that the learner
    /// cannot see stay saved but do not show.
    public static func groups(course: Course, notes: [String: [LectureNote]]) -> [LectureNoteGroup] {
        course.learnerSections.flatMap { section in
            section.lectures.compactMap { lecture in
                guard let lectureNotes = notes[lecture.id], !lectureNotes.isEmpty else { return nil }
                return LectureNoteGroup(sectionID: section.id, sectionTitle: section.title, lecture: lecture,
                                        notes: LectureNote.panelOrder(lectureNotes))
            }
        }
    }
}
