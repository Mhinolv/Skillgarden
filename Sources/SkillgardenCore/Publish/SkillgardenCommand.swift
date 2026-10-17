import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum SkillgardenCommand {
    private static let usage = "usage: skillgarden publish <course-folder>\n"

    public static func run(arguments: [String], root: URL = Skillgarden.defaultDataDirectory) -> CommandResult {
        if arguments == ["--version"] || arguments == ["version"] {
            return CommandResult(exitCode: 0, stdout: "skillgarden \(Skillgarden.version)\n", stderr: "")
        }
        if arguments == ["publish", "--help"] || arguments == ["--help"] {
            return CommandResult(exitCode: 0, stdout: usage, stderr: "")
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
}
