import Foundation

public enum PublicationState: String, Codable, Sendable, CaseIterable {
    case draft, published
}

public enum LectureType: String, Codable, Sendable, CaseIterable {
    case video, article, quiz, assignment
}

public struct Course: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var state: PublicationState
    public var sections: [CourseSection]

    public init(id: String, title: String, subtitle: String = "", state: PublicationState = .draft,
                sections: [CourseSection] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.sections = sections
    }
}

public struct CourseSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var objective: String
    public var order: Int
    public var state: PublicationState
    public var lectures: [Lecture]

    public init(id: String, title: String, objective: String = "", order: Int,
                state: PublicationState = .draft, lectures: [Lecture] = []) {
        self.id = id
        self.title = title
        self.objective = objective
        self.order = order
        self.state = state
        self.lectures = lectures
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
