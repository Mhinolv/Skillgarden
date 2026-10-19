import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course and a temporary base folder for library roots.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenJSONTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try body(folder, base)
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
}

/// Runs the command with `--json` and in text mode. Both runs must exit with the same code.
/// The JSON run must write one JSON document to stdout and nothing to stderr.
private func runJSON(_ arguments: [String], root: @autoclosure () throws -> URL) throws -> [String: Any] {
    let text = SkillgardenCommand.run(arguments: arguments, root: try root())
    let result = SkillgardenCommand.run(arguments: arguments + ["--json"], root: try root())
    #expect(result.exitCode == text.exitCode)
    #expect(result.stderr == "")
    #expect(result.stdout.hasPrefix("{\n  \"command\" : "))
    #expect(result.stdout.hasSuffix("}\n"))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    #expect(Set(object.keys) == ["format_version", "command", "ok", "exit_code", "result", "diagnostics"])
    #expect(object["format_version"] as? Int == 1)
    #expect(object["exit_code"] as? Int == Int(result.exitCode))
    #expect(object["ok"] as? Bool == (result.exitCode == 0))
    return object
}

private func diagnostics(_ object: [String: Any]) -> [[String: Any]] {
    object["diagnostics"] as? [[String: Any]] ?? []
}

@Test func validateJSONReportsTheCourse() throws {
    try withCourse { folder, base in
        let object = try runJSON(["validate", folder.path], root: base.appending(path: "library"))
        #expect(object["command"] as? String == "validate")
        #expect(object["ok"] as? Bool == true)
        #expect(diagnostics(object).isEmpty)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["title"] as? String == "Local Course Basics")
        #expect(result["id"] as? String == "sample-course")
        #expect(result["state"] as? String == "published")
        #expect(result["draft"] as? Bool == false)
        #expect(result["sections"] as? Int == 2)
        #expect(result["lectures"] as? Int == 4)
        // `--json` can come anywhere after the command name.
        let first = SkillgardenCommand.run(arguments: ["validate", "--json", folder.path], root: base)
        #expect(first == SkillgardenCommand.run(arguments: ["validate", folder.path, "--json"], root: base))
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        let draft = try runJSON(["validate", folder.path], root: base)
        #expect((draft["result"] as? [String: Any])?["draft"] as? Bool == true)
        #expect((draft["result"] as? [String: Any])?["state"] as? String == "draft")
    }
}

@Test func validateJSONReportsEachProblemWithACodeAndAHint() throws {
    try withCourse { folder, base in
        try edit(folder, "    title: Plan the course\n", "")
        try edit(folder, "appearance: light", "appearance: blue")
        try edit(folder, "path: media/course.svg", "path: ../course.svg")
        let object = try runJSON(["validate", folder.path], root: base)
        #expect(object["exit_code"] as? Int == 1)
        #expect(object["result"] is NSNull)
        let manifest = folder.appending(path: "skillgarden.yaml").path
        let rows = diagnostics(object)
        #expect(rows.map { $0["code"] as? String } == ["field.choice", "path.outside", "field.required"])
        #expect(rows.map { $0["field_path"] as? String } == ["theme.appearance", "course_image.path", "sections[0].title"])
        #expect(rows.allSatisfy { $0["file"] as? String == manifest && $0["severity"] as? String == "error" })
        #expect(rows.last?["message"] as? String == "required field is missing")
        #expect(rows.last?["hint"] as? String == "Add sections[0].title.")
        #expect(rows.first?["hint"] as? String == "Change theme.appearance to one of: light, dark.")
        // Text mode keeps its lines.
        #expect(SkillgardenCommand.run(arguments: ["validate", folder.path], root: base).stderr == """
            error: \(manifest): theme.appearance: must be one of: light, dark
            error: \(manifest): course_image.path: path must stay inside the course folder
            error: \(manifest): sections[0].title: required field is missing

            """)
    }
}

@Test func jsonCoversEveryExitCode() throws {
    try withCourse { folder, base in
        let library = base.appending(path: "library")
        // Exit 2: a usage error has no file, field path or result.
        let usage = try runJSON(["validate"], root: library)
        #expect(usage["exit_code"] as? Int == 2)
        #expect(usage["command"] as? String == "validate")
        #expect(diagnostics(usage).map { $0["code"] as? String } == ["usage"])
        #expect(diagnostics(usage).first?["message"] as? String == "expected validate <course-folder>")
        #expect(diagnostics(usage).first?["file"] is NSNull)
        #expect(diagnostics(usage).first?["field_path"] is NSNull)
        #expect(try runJSON(["bogus"], root: library)["command"] is NSNull)
        #expect(diagnostics(try runJSON(["internal", "show", "x"], root: library)).first?["code"] as? String == "usage")
        // Exit 2: a relative data folder setting.
        let bad = { try Skillgarden.dataDirectory(environment: ["SKILLGARDEN_DATA_DIR": "library"], savedSetting: nil) }
        let relative = try runJSON(["publish", folder.path], root: try bad())
        #expect(relative["exit_code"] as? Int == 2)
        #expect(diagnostics(relative).first?["code"] as? String == "data_dir.relative")
        #expect(diagnostics(relative).first?["message"] as? String == "SKILLGARDEN_DATA_DIR must be an absolute path")
        // Exit 3: the course folder does not exist.
        let missing = base.appending(path: "missing").path
        let folderMissing = try runJSON(["validate", missing], root: library)
        #expect(folderMissing["exit_code"] as? Int == 3)
        #expect(diagnostics(folderMissing).first?["code"] as? String == "course_folder.missing")
        #expect(diagnostics(folderMissing).first?["file"] as? String == missing)
        // Exit 1: an unknown course.
        let unknown = try runJSON(["internal", "list", "nope"], root: library)
        #expect(unknown["exit_code"] as? Int == 1)
        #expect(unknown["command"] as? String == "internal list")
        #expect(diagnostics(unknown).first?["code"] as? String == "course.not_found")
        // Exit 0: publish, then list the internal files. The text run publishes first, so the JSON run is unchanged.
        let published = try runJSON(["publish", folder.path], root: library)
        let result = try #require(published["result"] as? [String: Any])
        #expect(published["command"] as? String == "publish")
        #expect(result["library_path"] as? String == library.path)
        #expect([result["created"], result["updated"], result["unchanged"], result["removed"]].map { $0 as? Int } == [0, 0, 7, 0])
        #expect(result["draft"] as? Bool == false)
        let list = try runJSON(["internal", "list", "sample-course"], root: library)
        let files = try #require((list["result"] as? [String: Any])?["files"] as? [[String: Any]])
        #expect(files.map { $0["path"] as? String } == ["internal/research.md", "internal/transcript.vtt"])
        #expect(files.allSatisfy { $0["title"] is String && $0.keys.contains("description") })
        // Exit 3: an I/O or library error.
        try Data("not a database".utf8).write(to: library.appending(path: "library.sqlite"))
        let broken = try runJSON(["internal", "list", "sample-course"], root: library)
        #expect(broken["exit_code"] as? Int == 3)
        #expect(diagnostics(broken).first?["code"] as? String == "io")
    }
}

@Test func diagnosticCodesComeFromTheMessage() {
    func code(_ message: String) -> String { ManifestDiagnostic(file: "f", fieldPath: "a.b", message: message).code.rawValue }
    let table: [(String, String)] = [
        ("no skillgarden.yaml or skillgarden.json found", "manifest.missing"),
        ("found skillgarden.yaml and skillgarden.json, keep only one", "manifest.duplicate"),
        ("cannot read or parse manifest", "manifest.syntax"),
        ("required field is missing", "field.required"), ("alt text is required", "field.required"),
        ("must not be empty", "field.required"), ("must have at least one item", "field.required"),
        ("must have at least two choices", "field.required"), ("required when type is quiz", "field.required"),
        ("image \"a.png\" needs an entry with alt text", "field.required"),
        ("expected string, found integer", "field.type"),
        ("must be one of: draft, published", "field.choice"),
        ("allowed only when type is video", "field.not_allowed"), ("allowed only when type is quiz", "field.not_allowed"),
        ("must be 1", "field.value"), ("must be greater than 0", "field.value"), ("must be 0 or greater", "field.value"),
        ("must be a hex color such as \"#286644\"", "field.value"), ("must be an http or https URL", "field.value"),
        ("must be greater than timestamp_start", "field.value"), ("must have at most 2 checks", "field.value"),
        ("duplicate id \"a\" (first used at b)", "id.duplicate"),
        ("duplicate order 0 (first used at b)", "order.duplicate"),
        ("must refer to a lecture id in this course", "reference.unknown"),
        ("must refer to a choice id in this question", "reference.unknown"),
        ("path must stay inside the course folder", "path.outside"), ("path must stay inside internal/", "path.outside"),
        ("path must not be inside internal/", "path.outside"), ("library must be outside the course folder", "path.outside"),
        ("image \"../a.png\" must be a file inside the course folder", "path.outside"),
        ("file does not exist", "path.missing"), ("folder must contain index.html", "path.missing"),
        ("image \"a.png\" does not exist (expected content/a.png)", "path.missing"),
        ("path must be normalized: use \"content/a.md\"", "path.not_normalized"),
        (ImagePipelineError.unsupportedFormat.message, "media.invalid"), (ImagePipelineError.unreadable.message, "media.invalid"),
        ("must be an .mp4 file", "media.invalid"), ("must be a .vtt file", "media.invalid"),
        ("file is not an MP4 video", "media.invalid"), ("must match the video length (4 seconds)", "media.invalid"),
        ("cannot read the video length", "media.invalid"), ("invalid WebVTT file: missing header", "media.invalid"),
        ("cannot read the captions file as UTF-8 text", "media.invalid"),
        ("cannot read the Markdown file as UTF-8 text", "media.invalid"),
        ("app.js line 3: URL \"https://x\" is blocked in the app", "media.invalid"),
        ("manifest changed during publish", "io"), ("symbolic links are not supported: a", "io"), ("cannot read course files", "io"),
    ]
    for (message, expected) in table { #expect(code(message) == expected, "\(message)") }
}

@Test func diagnosticHintsNameTheField() {
    func hint(_ message: String) -> String? { ManifestDiagnostic(file: "f", fieldPath: "a.b", message: message).hint }
    #expect(hint("required field is missing") == "Add a.b.")
    #expect(hint("expected string, found integer") == "Change a.b to a string.")
    #expect(hint("expected array, found string") == "Change a.b to an array.")
    #expect(hint("path must be normalized: use \"content/a.md\"") == "Change a.b to \"content/a.md\".")
    #expect(hint("duplicate id \"a\" (first used at b)") == "Give a.b a unique id.")
    #expect(hint("must be greater than 0") == nil)
    #expect(hint("manifest changed during publish") == nil)
}

@Test func diagnosticCodesAreStable() {
    // Add codes only. A rename breaks the agents that read version 1.
    #expect(DiagnosticCode.allCases.map(\.rawValue) == [
        "usage", "data_dir.relative", "course_folder.missing", "manifest.missing", "manifest.duplicate", "manifest.syntax",
        "field.required", "field.type", "field.choice", "field.not_allowed", "field.value", "id.duplicate", "order.duplicate",
        "reference.unknown", "path.outside", "path.missing", "path.not_normalized", "media.invalid", "course.not_found",
        "library.busy", "io", "data_dir.not_folder", "course_folder.not_empty", "course_folder.not_folder",
        "file_not_found", "not_mp4", "no_video_length",
    ])
}
