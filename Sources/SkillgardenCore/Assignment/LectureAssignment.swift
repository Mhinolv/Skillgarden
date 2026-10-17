import Foundation

/// One row of a self-check rubric.
public struct RubricCriterion: Identifiable, Equatable, Sendable {
    public let id: String
    public let criterion: String
    public let guidance: String

    public init(id: String, criterion: String, guidance: String) {
        self.id = id
        self.criterion = criterion
        self.guidance = guidance
    }
}

/// The brief and rubric of an assignment lecture in the installed course snapshot.
public struct LectureAssignment: Equatable, Sendable {
    /// The Markdown brief. Nil if its path is outside the snapshot.
    public let brief: LectureArticle?
    /// The rubric rows in manifest order.
    public let rubric: [RubricCriterion]

    public init(brief: LectureArticle?, rubric: [RubricCriterion]) {
        self.brief = brief
        self.rubric = rubric
    }

    public init(manifest: ManifestAssignment, folder: URL) {
        brief = LectureArticle.normalize(manifest.brief.path).map {
            LectureArticle(folder: folder, path: $0, images: manifest.brief.images ?? [])
        }
        rubric = manifest.rubric.map { RubricCriterion(id: $0.id, criterion: $0.criterion, guidance: $0.guidance) }
    }

    /// The header metadata line, for example "Assignment · 4 criteria".
    public var meta: String {
        "Assignment · \(rubric.count) \(rubric.count == 1 ? "criterion" : "criteria")"
    }
}

/// The learner's self-check of one rubric. Each row is independent. The app keeps it for the session only.
public struct RubricChecklist: Equatable, Sendable {
    public let rubric: [RubricCriterion]
    /// The ids of checked rows.
    public private(set) var checked: Set<String>

    /// All rows start unchecked. `checked` ids that are not in the rubric are ignored.
    public init(rubric: [RubricCriterion], checked: Set<String> = []) {
        self.rubric = rubric
        self.checked = checked.intersection(rubric.map(\.id))
    }

    public func isChecked(_ id: String) -> Bool { checked.contains(id) }

    /// Checks an unchecked row and unchecks a checked row. An unknown id does nothing.
    public mutating func toggle(_ id: String) {
        guard rubric.contains(where: { $0.id == id }) else { return }
        if checked.remove(id) == nil { checked.insert(id) }
    }

    /// Clears all checks.
    public mutating func reset() { checked = [] }

    public var metCount: Int { checked.count }

    /// True if the rubric has rows and every row is checked.
    public var allMet: Bool { !rubric.isEmpty && checked.count == rubric.count }

    /// The summary line, for example "2 of 4 criteria met".
    public var summary: String {
        "\(metCount) of \(rubric.count) \(rubric.count == 1 ? "criterion" : "criteria") met"
    }
}
