import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// The result of one command before it is printed as text or as JSON.
private struct CommandOutcome {
    var exitCode: Int32
    /// The stdout text of text mode.
    var text = ""
    /// The `result` object of JSON mode. Nil writes `null`.
    var result: [String: Any]?
    var diagnostics: [CommandDiagnostic] = []
    /// Text mode prints the usage text after the diagnostics.
    var showsUsage = false

    static func failure(_ exitCode: Int32, _ diagnostics: [CommandDiagnostic], showsUsage: Bool = false) -> CommandOutcome {
        CommandOutcome(exitCode: exitCode, diagnostics: diagnostics, showsUsage: showsUsage)
    }
}

public enum SkillgardenCommand {
    private static let usage = """
        usage: skillgarden publish <course-folder> [--json]
               skillgarden validate <course-folder> [--json]
               skillgarden internal list <course-id> [--json]
               skillgarden doctor [--json]

        """

    /// The version of the `--json` envelope. Add keys only, so agents that read version 1 keep working.
    public static let jsonFormatVersion = 1

    /// `root` is read only by the commands that open the library. A bad data folder setting exits 2.
    /// `doctor` is read only by `skillgarden doctor`.
    public static func run(arguments: [String],
                           root: @autoclosure () throws -> URL = try Skillgarden.dataDirectory(),
                           doctor: @autoclosure () -> Doctor = Doctor.current()) -> CommandResult {
        if arguments == ["--version"] || arguments == ["version"] {
            return CommandResult(exitCode: 0, stdout: "skillgarden \(Skillgarden.version)\n", stderr: "")
        }
        if arguments == ["publish", "--help"] || arguments == ["validate", "--help"] || arguments == ["doctor", "--help"]
            || arguments == ["--help"] {
            return CommandResult(exitCode: 0, stdout: usage, stderr: "")
        }
        // `--json` can come anywhere after the command name.
        let json = arguments.dropFirst().contains("--json")
        let arguments = Array(arguments.prefix(1)) + arguments.dropFirst().filter { $0 != "--json" }
        let command: String?
        let outcome: CommandOutcome
        switch arguments.first {
        case "validate":
            command = "validate"
            outcome = arguments.count == 2 && !arguments[1].hasPrefix("-")
                ? validate(courseFolder: arguments[1]) : usageError("expected validate <course-folder>")
        case "internal":
            command = "internal list"
            outcome = arguments.count == 3 && arguments[1] == "list" && !arguments[2].hasPrefix("-")
                ? withRoot(root) { listInternal(courseID: arguments[2], root: $0) } : usageError("expected internal list <course-id>")
        case "doctor":
            command = "doctor"
            outcome = arguments.count == 1 ? diagnose(doctor()) : usageError("expected doctor")
        default:
            command = arguments.first == "publish" ? "publish" : nil
            outcome = arguments.count == 2 && arguments[0] == "publish" && !arguments[1].hasPrefix("-")
                ? withRoot(root) { publish(courseFolder: arguments[1], root: $0) } : usageError("expected publish <course-folder>")
        }
        return json ? jsonResult(outcome, command: command) : textResult(outcome)
    }

    private static func textResult(_ outcome: CommandOutcome) -> CommandResult {
        let errors = outcome.diagnostics.map { "error: \($0.text)\n" }.joined()
        return CommandResult(exitCode: outcome.exitCode, stdout: outcome.text, stderr: errors + (outcome.showsUsage ? usage : ""))
    }

    /// One JSON document on stdout for every exit code. Stderr stays empty (#109 owner decision).
    private static func jsonResult(_ outcome: CommandOutcome, command: String?) -> CommandResult {
        func value(_ text: String?) -> Any { text ?? NSNull() }
        let diagnostics: [[String: Any]] = outcome.diagnostics.map {
            ["code": $0.code.rawValue, "file": value($0.file), "field_path": value($0.fieldPath),
             "message": $0.message, "hint": value($0.hint), "severity": "error"]
        }
        let envelope: [String: Any] = [
            "format_version": jsonFormatVersion, "command": value(command), "ok": outcome.exitCode == 0,
            "exit_code": Int(outcome.exitCode), "result": outcome.result ?? NSNull(), "diagnostics": diagnostics,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return CommandResult(exitCode: outcome.exitCode, stdout: String(decoding: data, as: UTF8.self) + "\n", stderr: "")
    }

    private static func usageError(_ message: String) -> CommandOutcome {
        .failure(2, [CommandDiagnostic(code: .usage, message: message, hint: "Run skillgarden --help to see the usage.")], showsUsage: true)
    }

    private static func withRoot(_ root: () throws -> URL, _ body: (URL) -> CommandOutcome) -> CommandOutcome {
        let url: URL
        do { url = try root() }
        catch let error as DataDirectoryError {
            return .failure(2, [CommandDiagnostic(code: .dataDirectoryRelative, message: error.localizedDescription,
                                                  hint: "Set \(error.source) to an absolute path that starts with /.")])
        } catch { return .failure(2, [CommandDiagnostic(code: .io, message: error.localizedDescription)]) }
        return body(url)
    }

    private static func failure(_ error: Error) -> CommandOutcome {
        if let error = error as? ManifestValidationError { return .failure(1, error.diagnostics.map(CommandDiagnostic.init)) }
        return .failure(3, [CommandDiagnostic(code: .io, message: error.localizedDescription)])
    }

    private static func draftText(_ state: ManifestState) -> String {
        state == .draft ? "Draft: learners do not see this course.\n" : ""
    }

    private static func publish(courseFolder path: String, root: URL) -> CommandOutcome {
        do {
            let result = try CoursePublisher.publish(courseFolder: URL(fileURLWithPath: path), root: root)
            return CommandOutcome(exitCode: 0, text: result.summary + "\n" + draftText(result.state) + "Library: \(root.path)\n", result: [
                "title": result.title, "id": result.id, "state": result.state.rawValue, "draft": result.state == .draft,
                "created": result.created, "updated": result.updated, "unchanged": result.unchanged, "removed": result.removed,
                "library_path": root.path,
            ])
        } catch {
            return failure(error)
        }
    }

    /// Checks the course folder like publish does. It does not open or write the library.
    private static func validate(courseFolder path: String) -> CommandOutcome {
        let folder = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(3, [CommandDiagnostic(code: .courseFolderMissing, file: folder.path,
                                                  message: "course folder does not exist: \(folder.path)",
                                                  hint: "Check the path of the course folder.")])
        }
        do {
            let result = try CoursePublisher.validate(courseFolder: folder)
            return CommandOutcome(exitCode: 0, text: result.summary + "\n" + draftText(result.state), result: [
                "title": result.title, "id": result.id, "state": result.state.rawValue, "draft": result.state == .draft,
                "sections": result.sections, "lectures": result.lectures,
            ])
        } catch {
            return failure(error)
        }
    }

    /// The report goes to stdout for every exit code, so an agent sees the lines that explain the error.
    private static func diagnose(_ doctor: Doctor) -> CommandOutcome {
        CommandOutcome(exitCode: doctor.exitCode, text: doctor.text, result: doctor.result, diagnostics: doctor.diagnostics)
    }

    /// Prints one tab-separated row for each internal file, in manifest order.
    private static func listInternal(courseID: String, root: URL) -> CommandOutcome {
        do {
            guard let files = try CoursePublisher.internalFiles(courseID: courseID, root: root) else {
                return .failure(1, [CommandDiagnostic(code: .courseNotFound, message: "course \"\(courseID)\" not found",
                                                      hint: "Check the course id, or publish the course first.")])
            }
            let result: [String: Any] = [
                "files": files.map { ["title": $0.title, "path": $0.path, "description": $0.description ?? NSNull()] as [String: Any] },
            ]
            guard !files.isEmpty else {
                return CommandOutcome(exitCode: 0, text: "No internal files for course \"\(courseID)\".\n", result: result)
            }
            // A tab or line break in a value would split the row, so each one becomes a space.
            func cell(_ text: String?) -> String {
                (text ?? "").map { $0 == "\t" || $0.isNewline ? " " : String($0) }.joined()
            }
            let rows = files.map { [cell($0.title), cell($0.path), cell($0.description)].joined(separator: "\t") + "\n" }
            return CommandOutcome(exitCode: 0, text: "TITLE\tPATH\tDESCRIPTION\n" + rows.joined(), result: result)
        } catch {
            return failure(error)
        }
    }
}
