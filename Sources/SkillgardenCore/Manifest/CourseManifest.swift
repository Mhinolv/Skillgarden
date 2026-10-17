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
    /// Required when `type` is `quiz`. Nil for every other type.
    public var quiz: ManifestQuiz?
    enum CodingKeys: String, CodingKey {
        case id, title, type, objective, state, order, quiz
        case recommendedNext = "recommended_next"
    }
}

public struct ManifestQuizChoice: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
}

public struct ManifestQuizQuestion: Codable, Equatable, Sendable {
    public var id: String
    public var prompt: String
    public var image: ManifestImage?
    public var objectiveTag: String
    public var choices: [ManifestQuizChoice]
    public var correctChoiceID: String
    /// Shown for every choice after Submit.
    public var explanation: String
    enum CodingKeys: String, CodingKey {
        case id, prompt, image, choices, explanation
        case objectiveTag = "objective_tag", correctChoiceID = "correct_choice_id"
    }
}

public struct ManifestQuiz: Codable, Equatable, Sendable {
    public var questions: [ManifestQuizQuestion]
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

/// Team-only material. Learners never see these files.
public struct ManifestInternalFile: Codable, Equatable, Sendable {
    public var path: String
    public var title: String
    public var description: String?
}

public struct ManifestInternal: Codable, Equatable, Sendable {
    public var files: [ManifestInternalFile]
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
    /// Optional. Nil when the manifest has no `internal` field.
    public var internalMaterial: ManifestInternal?
    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, description, requirements, state, theme, credits, sections
        case schemaVersion = "schema_version", learningOutcomes = "learning_outcomes"
        case targetAudience = "target_audience", courseImage = "course_image", internalMaterial = "internal"
    }
}
