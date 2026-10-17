import Foundation

public enum ManifestState: String, Codable, Sendable { case draft, published }
public enum ManifestAppearance: String, Codable, Sendable { case light, dark }
public enum ManifestLectureType: String, Codable, Sendable { case video, article, quiz, assignment }

public struct ManifestImage: Codable, Equatable, Sendable {
    public var path: String
    public var alt: String
}

public struct ManifestTheme: Codable, Equatable, Sendable {
    public var accentColor: String
    public var appearance: ManifestAppearance
    enum CodingKeys: String, CodingKey { case accentColor = "accent_color", appearance }
}

public struct ManifestCredit: Codable, Equatable, Sendable {
    public var name: String
    public var role: String?
    public var url: String?
}

public struct ManifestLecture: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var type: ManifestLectureType
    public var objective: String
    public var state: ManifestState
    public var order: Int
    public var recommendedNext: String?
    enum CodingKeys: String, CodingKey {
        case id, title, type, objective, state, order
        case recommendedNext = "recommended_next"
    }
}

public struct ManifestSection: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var objective: String
    public var state: ManifestState
    public var order: Int
    public var headerImage: ManifestImage
    public var lectures: [ManifestLecture]
    enum CodingKeys: String, CodingKey {
        case id, title, objective, state, order, lectures
        case headerImage = "header_image"
    }
}

/// Version 1 interchange data. Store models remain separate from this format.
public struct CourseManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var subtitle: String
    public var description: String
    public var learningOutcomes: [String]
    public var requirements: [String]
    public var targetAudience: String
    public var state: ManifestState
    public var theme: ManifestTheme
    public var courseImage: ManifestImage
    public var credits: [ManifestCredit]
    public var sections: [ManifestSection]
    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, description, requirements, state, theme, credits, sections
        case schemaVersion = "schema_version", learningOutcomes = "learning_outcomes"
        case targetAudience = "target_audience", courseImage = "course_image"
    }
}
