import Foundation

public enum PublicationState: String, Codable, Sendable, CaseIterable {
    case draft, published
}

public enum LectureType: String, Codable, Sendable, CaseIterable {
    case video, article, quiz, assignment, interactive
}

public struct Course: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var state: PublicationState
    public var sections: [CourseSection]
    /// Nil for courses saved before media metadata (schema version 2).
    public var image: CourseImage?

    public init(id: String, title: String, subtitle: String = "", state: PublicationState = .draft,
                sections: [CourseSection] = [], image: CourseImage? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.sections = sections
        self.image = image
    }
}

public struct CourseSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var objective: String
    public var order: Int
    public var state: PublicationState
    public var lectures: [Lecture]
    public var headerImage: CourseImage?

    public init(id: String, title: String, objective: String = "", order: Int,
                state: PublicationState = .draft, lectures: [Lecture] = [], headerImage: CourseImage? = nil) {
        self.id = id
        self.title = title
        self.objective = objective
        self.order = order
        self.state = state
        self.lectures = lectures
        self.headerImage = headerImage
    }
}

public struct LectureProgress: Codable, Equatable, Sendable {
    public var completed: Bool
    public var resumeSeconds: Double
    /// True after the learner marks the lecture incomplete by hand. Then the video does not complete it again (#79).
    public var autoCompleteOff: Bool

    public init(completed: Bool = false, resumeSeconds: Double = 0, autoCompleteOff: Bool = false) {
        self.completed = completed
        self.resumeSeconds = resumeSeconds
        self.autoCompleteOff = autoCompleteOff
    }

    private enum CodingKeys: String, CodingKey { case completed, resumeSeconds, autoCompleteOff }

    /// Data saved before #79 has no `autoCompleteOff`, so it decodes as false.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completed = try container.decode(Bool.self, forKey: .completed)
        resumeSeconds = try container.decode(Double.self, forKey: .resumeSeconds)
        autoCompleteOff = try container.decodeIfPresent(Bool.self, forKey: .autoCompleteOff) ?? false
    }
}

public struct Lecture: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var type: LectureType
    public var objective: String
    public var order: Int
    public var state: PublicationState
    public var recommendedNext: String?

    public init(id: String, title: String, type: LectureType, objective: String = "", order: Int,
                state: PublicationState = .draft, recommendedNext: String? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.objective = objective
        self.order = order
        self.state = state
        self.recommendedNext = recommendedNext
    }
}
