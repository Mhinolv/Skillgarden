import Foundation

/// The course playbook (#252): the phased pipeline, with a gate for each phase, that turns a topic into a published course.
/// `skillgarden playbook` prints it. Skillgarden > "Copy Course Playbook" and "Save Course Playbook…" copy or save it.
/// It is a constant, not a resource bundle, so a copied CLI binary and a source build still have it.
public enum CoursePlaybook {
    /// The file name that the Save panel suggests.
    public static let fileName = "skillgarden-course-playbook.md"

    /// The text of the file, with a line break at the end.
    public static var text: String { markdown + "\n" }

    /// The alert after "Copy Course Playbook" (owner decision, 2026-11-02).
    public static let copiedMessage = "The course playbook is copied."
    /// The alert after a failed save.
    public static let saveFailureMessage = "Could not save the course playbook."

    /// Writes the text to `file` and replaces an earlier copy.
    public static func write(to file: URL) throws {
        try Data(text.utf8).write(to: file, options: .atomic)
    }
}
