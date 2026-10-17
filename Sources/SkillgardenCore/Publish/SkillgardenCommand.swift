import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum SkillgardenCommand {
    private static let usage = "usage: skillgarden publish <course-folder>\n       skillgarden internal list <course-id>\n"

    public static func run(arguments: [String], root: URL = Skillgarden.defaultDataDirectory) -> CommandResult {
        if arguments == ["--version"] || arguments == ["version"] {
            return CommandResult(exitCode: 0, stdout: "skillgarden \(Skillgarden.version)\n", stderr: "")
        }
        if arguments == ["publish", "--help"] || arguments == ["--help"] {
            return CommandResult(exitCode: 0, stdout: usage, stderr: "")
        }
        if arguments.first == "internal" {
            guard arguments.count == 3, arguments[1] == "list", !arguments[2].hasPrefix("-") else {
                return CommandResult(exitCode: 2, stdout: "", stderr: "error: expected internal list <course-id>\n" + usage)
            }
            return listInternal(courseID: arguments[2], root: root)
        }
        guard arguments.count == 2, arguments[0] == "publish", !arguments[1].hasPrefix("-") else {
            return CommandResult(exitCode: 2, stdout: "", stderr: "error: expected publish <course-folder>\n" + usage)
        }
        do {
            let result = try CoursePublisher.publish(courseFolder: URL(fileURLWithPath: arguments[1]), root: root)
            let draft = result.state == .draft ? "Draft: learners do not see this course.\n" : ""
            return CommandResult(exitCode: 0, stdout: result.summary + "\n" + draft, stderr: "")
        } catch let error as ManifestValidationError {
            return CommandResult(exitCode: 1, stdout: "", stderr: error.diagnostics.map { "error: \($0)\n" }.joined())
        } catch {
            return CommandResult(exitCode: 3, stdout: "", stderr: "error: \(error.localizedDescription)\n")
        }
    }

    /// Prints one tab-separated row for each internal file, in manifest order.
    private static func listInternal(courseID: String, root: URL) -> CommandResult {
        do {
            guard let files = try CoursePublisher.internalFiles(courseID: courseID, root: root) else {
                return CommandResult(exitCode: 1, stdout: "", stderr: "error: course \"\(courseID)\" not found\n")
            }
            guard !files.isEmpty else {
                return CommandResult(exitCode: 0, stdout: "No internal files for course \"\(courseID)\".\n", stderr: "")
            }
            // A tab or line break in a value would split the row, so each one becomes a space.
            func cell(_ text: String?) -> String {
                (text ?? "").map { $0 == "\t" || $0.isNewline ? " " : String($0) }.joined()
            }
            let rows = files.map { [cell($0.title), cell($0.path), cell($0.description)].joined(separator: "\t") + "\n" }
            return CommandResult(exitCode: 0, stdout: "TITLE\tPATH\tDESCRIPTION\n" + rows.joined(), stderr: "")
        } catch {
            return CommandResult(exitCode: 3, stdout: "", stderr: "error: \(error.localizedDescription)\n")
        }
    }
}
