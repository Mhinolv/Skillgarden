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
    /// JSON mode prints this text in place of the envelope.
    var jsonText: String?
    /// Text mode prints the usage text after the diagnostics.
    var showsUsage = false
    /// Text mode prints a `hint:` line after each diagnostic that has a hint.
    var showsHints = false

    static func failure(_ exitCode: Int32, _ diagnostics: [CommandDiagnostic], showsUsage: Bool = false) -> CommandOutcome {
        CommandOutcome(exitCode: exitCode, diagnostics: diagnostics, showsUsage: showsUsage)
    }
}

public enum SkillgardenCommand {
    private static let usage = """
        usage: skillgarden publish <course-folder> [--json]
               skillgarden publish --dry-run <course-folder> [--json]
               skillgarden validate <course-folder> [--json]
               skillgarden internal list <course-id> [--json]
               skillgarden init <folder> --id <id> --title <title> [--json]
               skillgarden doctor [--json]
               skillgarden schema [--output <file>]

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
            || arguments == ["init", "--help"] || arguments == ["schema", "--help"] || arguments == ["--help"] {
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
        case "init":
            command = "init"
            outcome = initArguments(Array(arguments.dropFirst())).map(initCourse)
                ?? usageError("expected init <folder> --id <id> --title <title>")
        case "doctor":
            command = "doctor"
            outcome = arguments.count == 1 ? diagnose(doctor()) : usageError("expected doctor")
        case "schema":
            command = "schema"
            if arguments.count == 1 {
                outcome = schema(output: nil)
            } else if arguments.count == 3, arguments[1] == "--output", !arguments[2].isEmpty, !arguments[2].hasPrefix("-") {
                outcome = schema(output: arguments[2])
            } else {
                outcome = usageError("expected schema [--output <file>]")
            }
        case "publish":
            command = "publish"
            // `--dry-run` can come before or after the course folder.
            let dryRun = arguments.filter { $0 == "--dry-run" }.count == 1
            let rest = arguments.dropFirst().filter { $0 != "--dry-run" }
            if rest.count == 1, !rest[0].hasPrefix("-"), arguments.count == (dryRun ? 3 : 2) {
                outcome = withRoot(root) { dryRun ? planPublish(courseFolder: rest[0], root: $0) : publish(courseFolder: rest[0], root: $0) }
            } else {
                outcome = usageError("expected publish <course-folder>")
            }
        default:
            command = nil
            outcome = usageError("expected publish <course-folder>")
        }
        return json ? jsonResult(outcome, command: command) : textResult(outcome)
    }

    private static func textResult(_ outcome: CommandOutcome) -> CommandResult {
        let errors = outcome.diagnostics.map {
            "error: \($0.text)\n" + (outcome.showsHints ? $0.hint.map { "hint: \($0)\n" } ?? "" : "")
        }.joined()
        return CommandResult(exitCode: outcome.exitCode, stdout: outcome.text, stderr: errors + (outcome.showsUsage ? usage : ""))
    }

    /// One JSON document on stdout for every exit code. Stderr stays empty (#109 owner decision).
    private static func jsonResult(_ outcome: CommandOutcome, command: String?) -> CommandResult {
        if let text = outcome.jsonText { return CommandResult(exitCode: outcome.exitCode, stdout: text, stderr: "") }
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

    /// Prints what publish would change (#114). It reads the library and writes nothing.
    private static func planPublish(courseFolder path: String, root: URL) -> CommandOutcome {
        let plan: PublishPlan
        do {
            plan = try CoursePublisher.plan(courseFolder: URL(fileURLWithPath: path), root: root)
        } catch let error as CourseStoreError {
            guard case .unsupportedSchema = error else { return failure(error) }
            var outcome = CommandOutcome.failure(3, [CommandDiagnostic(code: .io, message: error.localizedDescription,
                                                                       hint: "Update skillgarden. Dry run does not change the library.")])
            outcome.showsHints = true
            return outcome
        } catch {
            return failure(error)
        }
        let lines = [plan.summary] + plan.changes.map(\.line) + [plan.files.line, plan.snapshot.line] + [plan.migrationLine].compactMap { $0 }
        let text = lines.map { $0 + "\n" }.joined() + draftText(plan.state) + "Library: \(root.path)\nNothing was written.\n"
        let snapshot = plan.snapshot
        return CommandOutcome(exitCode: 0, text: text, result: [
            "title": plan.title, "id": plan.id, "state": plan.state.rawValue, "draft": plan.state == .draft,
            "created": plan.created, "updated": plan.updated, "unchanged": plan.unchanged, "removed": plan.removed,
            "library_path": root.path, "dry_run": true,
            "changes": plan.changes.map { ["action": $0.action.rawValue, "kind": $0.kind, "id": $0.id] },
            "files": ["added": plan.files.added, "changed": plan.files.changed, "unchanged": plan.files.unchanged,
                      "removed": plan.files.removed],
            "snapshot": ["state": snapshot.keptID == nil ? "new" : "kept", "id": snapshot.keptID ?? NSNull(),
                         "files": snapshot.files, "bytes": snapshot.bytes] as [String: Any],
            "migration": plan.migrationFrom.map { ["from": $0, "to": CourseStore.currentSchemaVersion] as Any } ?? NSNull(),
        ])
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

    /// The folder, `--id` and `--title` in any order. Nil for a missing, empty or repeated value, or an unknown flag.
    private static func initArguments(_ arguments: [String]) -> (folder: String, id: String, title: String)? {
        var folder: String?, values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--id" || argument == "--title" {
                guard index + 1 < arguments.count, values[argument] == nil else { return nil }
                values[argument] = arguments[index + 1]
                index += 2
            } else {
                guard folder == nil, !argument.hasPrefix("-"), !argument.isEmpty else { return nil }
                folder = argument
                index += 1
            }
        }
        func value(_ text: String?) -> String? {
            guard let text, !text.hasPrefix("--"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.contains(where: \.isNewline) else { return nil }
            return text
        }
        guard let folder, let id = value(values["--id"]), let title = value(values["--title"]) else { return nil }
        return (folder, id, title)
    }

    /// Writes the starter course. It does not open the library.
    private static func initCourse(_ arguments: (folder: String, id: String, title: String)) -> CommandOutcome {
        guard !CourseScaffold.reservedIDs.contains(arguments.id) else {
            return usageError("--id must not be \(CourseScaffold.reservedIDs.map { "\"\($0)\"" }.joined(separator: " or ")), "
                + "because the starter section and lecture use these ids")
        }
        let folder = URL(fileURLWithPath: arguments.folder).standardizedFileURL
        let scaffold = CourseScaffold(id: arguments.id, title: arguments.title)
        do {
            try scaffold.create(at: folder)
        } catch {
            switch error {
            case .notEmpty(let path):
                return .failure(1, [CommandDiagnostic(code: .courseFolderNotEmpty, file: path, message: "folder is not empty: \(path)",
                                                      hint: "Use a new or empty folder. Init does not overwrite files.")])
            case .notAFolder(let path):
                return .failure(1, [CommandDiagnostic(code: .courseFolderNotFolder, file: path, message: "not a folder: \(path)",
                                                      hint: "Use the path of a new or empty folder.")])
            case .write(let description):
                return .failure(3, [CommandDiagnostic(code: .io, file: folder.path, message: description)])
            }
        }
        let files = scaffold.files.map(\.path)
        return CommandOutcome(exitCode: 0, text: """
            Created "\(scaffold.title)" (\(scaffold.id), draft): \(files.count) files in \(folder.path)
            \(draftText(.draft))Next: edit skillgarden.yaml, then run: skillgarden validate \(shellWord(arguments.folder))

            """, result: [
                "title": scaffold.title, "id": scaffold.id, "state": ManifestState.draft.rawValue, "draft": true,
                "path": folder.path, "files": files,
            ])
    }

    /// Quotes a path for the shell when it holds characters other than letters, digits and `/._-+@:,`.
    private static func shellWord(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@:,"))
        if text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Prints the manifest JSON Schema, or writes it to `output` and overwrites an earlier copy. It does not open the library.
    /// The schema is already JSON, so `--json` prints the same schema. With `--output`, `--json` prints the envelope.
    private static func schema(output: String?) -> CommandOutcome {
        let text = ManifestSchema.json + "\n"
        guard let output else { return CommandOutcome(exitCode: 0, text: text, jsonText: text) }
        let file = URL(fileURLWithPath: output).standardizedFileURL
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            return .failure(3, [CommandDiagnostic(code: .io, file: file.path, message: error.localizedDescription)])
        }
        return CommandOutcome(exitCode: 0, text: "Wrote manifest schema \(ManifestSchema.version) to \(file.path)\n",
                              result: ["path": file.path, "schema_version": ManifestSchema.version])
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
