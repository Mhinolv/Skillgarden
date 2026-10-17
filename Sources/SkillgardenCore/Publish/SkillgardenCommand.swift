import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum SkillgardenCommand {
    private static let usage = """
        usage: skillgarden publish <course-folder>
               skillgarden validate <course-folder>
               skillgarden internal list <course-id>

        """

    /// `root` is read only by the commands that open the library. A bad data folder setting exits 2.
    public static func run(arguments: [String],
                           root: @autoclosure () throws -> URL = try Skillgarden.dataDirectory()) -> CommandResult {
        if arguments == ["--version"] || arguments == ["version"] {
            return CommandResult(exitCode: 0, stdout: "skillgarden \(Skillgarden.version)\n", stderr: "")
        }
        if arguments == ["publish", "--help"] || arguments == ["validate", "--help"] || arguments == ["--help"] {
            return CommandResult(exitCode: 0, stdout: usage, stderr: "")
        }
        if arguments.first == "validate" {
            guard arguments.count == 2, !arguments[1].hasPrefix("-") else {
                return CommandResult(exitCode: 2, stdout: "", stderr: "error: expected validate <course-folder>\n" + usage)
            }
            return validate(courseFolder: arguments[1])
        }
        if arguments.first == "internal" {
            guard arguments.count == 3, arguments[1] == "list", !arguments[2].hasPrefix("-") else {
                return CommandResult(exitCode: 2, stdout: "", stderr: "error: expected internal list <course-id>\n" + usage)
            }
            return withRoot(root) { listInternal(courseID: arguments[2], root: $0) }
        }
        guard arguments.count == 2, arguments[0] == "publish", !arguments[1].hasPrefix("-") else {
            return CommandResult(exitCode: 2, stdout: "", stderr: "error: expected publish <course-folder>\n" + usage)
        }
        return withRoot(root) { root in
            do {
                let result = try CoursePublisher.publish(courseFolder: URL(fileURLWithPath: arguments[1]), root: root)
                let draft = result.state == .draft ? "Draft: learners do not see this course.\n" : ""
                return CommandResult(exitCode: 0, stdout: result.summary + "\n" + draft + "Library: \(root.path)\n", stderr: "")
            } catch let error as ManifestValidationError {
                return failure(error)
            } catch {
                return CommandResult(exitCode: 3, stdout: "", stderr: "error: \(error.localizedDescription)\n")
            }
        }
    }

    private static func withRoot(_ root: () throws -> URL, _ body: (URL) -> CommandResult) -> CommandResult {
        do { return body(try root()) }
        catch { return CommandResult(exitCode: 2, stdout: "", stderr: "error: \(error.localizedDescription)\n") }
    }

    private static func failure(_ error: ManifestValidationError) -> CommandResult {
        CommandResult(exitCode: 1, stdout: "", stderr: error.diagnostics.map { "error: \($0)\n" }.joined())
    }

    /// Checks the course folder like publish does. It does not open or write the library.
    private static func validate(courseFolder path: String) -> CommandResult {
        let folder = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return CommandResult(exitCode: 3, stdout: "", stderr: "error: course folder does not exist: \(folder.path)\n")
        }
        do {
            let result = try CoursePublisher.validate(courseFolder: folder)
            let draft = result.state == .draft ? "Draft: learners do not see this course.\n" : ""
            return CommandResult(exitCode: 0, stdout: result.summary + "\n" + draft, stderr: "")
        } catch let error as ManifestValidationError {
            return failure(error)
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
