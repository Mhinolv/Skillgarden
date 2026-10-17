import Foundation

/// The lecture that the nudge card offers after the current lecture.
public struct LectureNudge: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The lecture's `recommended_next` target.
        case recommended
        /// The next lecture in outline order, used when `recommended_next` is empty.
        case upNext
    }

    public let kind: Kind
    public let sectionID: String
    public let lecture: Lecture

    public var destination: CourseDestination { .lecture(sectionID: sectionID, lectureID: lecture.id) }
}

/// The header image of a section, resolved inside the installed course snapshot.
public struct SectionHeaderImage: Equatable, Sendable {
    public let url: URL
    public let alt: String

    public init(url: URL, alt: String) {
        self.url = url
        self.alt = alt
    }
}

extension Course {
    /// Published sections with only their published lectures, in store order (`order`, then id).
    public var learnerSections: [CourseSection] {
        sections.filter { $0.state == .published }.map { section in
            var section = section
            section.lectures = section.lectures.filter { $0.state == .published }
            return section
        }
    }

    /// Learner lectures in outline order across all sections.
    public var learnerLectures: [(sectionID: String, lecture: Lecture)] {
        learnerSections.flatMap { section in section.lectures.map { (section.id, $0) } }
    }

    /// The 1-based position of a learner section, or nil if the learner cannot see it.
    public func sectionNumber(of sectionID: String) -> Int? {
        learnerSections.firstIndex { $0.id == sectionID }.map { $0 + 1 }
    }

    /// The 1-based position of a learner lecture in the whole course, or nil if the learner cannot see it.
    public func lectureNumber(of lectureID: String) -> Int? {
        learnerLectures.firstIndex { $0.lecture.id == lectureID }.map { $0 + 1 }
    }

    /// The learner lecture `offset` steps from `lectureID` in outline order, or nil at either end.
    public func adjacentLecture(to lectureID: String, offset: Int) -> CourseDestination? {
        let lectures = learnerLectures
        guard let index = lectures.firstIndex(where: { $0.lecture.id == lectureID }),
              lectures.indices.contains(index + offset) else { return nil }
        let target = lectures[index + offset]
        return .lecture(sectionID: target.sectionID, lectureID: target.lecture.id)
    }

    /// The `recommended_next` target, or the next lecture if that field is empty.
    /// Returns nil if the target is missing, draft or the current lecture, or if no lecture follows.
    public func nudge(for lectureID: String) -> LectureNudge? {
        let lectures = learnerLectures
        guard let index = lectures.firstIndex(where: { $0.lecture.id == lectureID }) else { return nil }
        let recommended = lectures[index].lecture.recommendedNext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if recommended.isEmpty {
            guard lectures.indices.contains(index + 1) else { return nil }
            let next = lectures[index + 1]
            return LectureNudge(kind: .upNext, sectionID: next.sectionID, lecture: next.lecture)
        }
        guard recommended != lectureID, let target = lectures.first(where: { $0.lecture.id == recommended }) else { return nil }
        return LectureNudge(kind: .recommended, sectionID: target.sectionID, lecture: target.lecture)
    }
}
