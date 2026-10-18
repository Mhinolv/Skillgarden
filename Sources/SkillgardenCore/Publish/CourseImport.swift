import Foundation

/// The result of the import check of a course folder (#111).
public enum CourseImportCheck: Equatable, Sendable {
    /// The folder fails validation. The library does not change.
    case invalid([ManifestDiagnostic])
    /// The library has no course with this ID.
    case new(ValidationResult)
    /// The library already has a course with this ID, draft or published. Import replaces it.
    case replaces(ValidationResult, oldTitle: String)
}

/// The app import of a course folder from outside the library (#111). It uses the same checks as `skillgarden publish`.
public enum CourseImport {
    /// The number of error lines that the error alert shows.
    public static let shownErrorLines = 10

    /// Runs every publish-time check and writes nothing. The store opens only for a valid folder.
    public static func check(folder: URL, root: URL) throws -> CourseImportCheck {
        let result: ValidationResult
        do {
            result = try CoursePublisher.validate(courseFolder: folder, library: root.resolvingSymlinksInPath().standardizedFileURL)
        } catch let error as ManifestValidationError {
            return .invalid(error.diagnostics)
        }
        guard let old = try CourseStore(root: root).loadCourse(id: result.id, includeDrafts: true) else { return .new(result) }
        return .replaces(result, oldTitle: old.title)
    }

    /// The first `shownErrorLines` lines in the CLI error text, then "and <n> more".
    public static func shownErrors(_ diagnostics: [ManifestDiagnostic]) -> String {
        let lines = diagnostics.prefix(shownErrorLines).map(\.description)
        let more = diagnostics.count - lines.count
        return (lines + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n")
    }

    /// All error lines in the CLI error text. `Copy Errors` copies them for the agent.
    public static func allErrors(_ diagnostics: [ManifestDiagnostic]) -> String {
        diagnostics.map(\.description).joined(separator: "\n")
    }

    /// The draft alert text. Learners do not see a draft course.
    public static func draftMessage(title: String) -> String { "\"\(title)\" is a draft." }
    public static let draftInformation = "Learners do not see draft courses. Set state: published, then import again."

    /// The replace alert text.
    public static func replaceMessage(oldTitle: String) -> String { "Replace \"\(oldTitle)\"?" }
    public static func replaceInformation(id: String, newTitle: String) -> String {
        "The library already has a course with the ID \"\(id)\". Import replaces it with \"\(newTitle)\"."
    }
}
