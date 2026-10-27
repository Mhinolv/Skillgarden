import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course and a temporary base folder for library roots.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenAgentTests-\(UUID())")
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

/// Every file below `folder` with its contents, so a test can show that nothing changed.
private func contents(of folder: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
    }
    return result
}

@Test func dataDirectoryLookupOrder() throws {
    let home = URL(fileURLWithPath: "/Users/agent")
    func resolve(_ variable: String?, _ saved: String?) throws -> URL {
        try Skillgarden.dataDirectory(environment: variable.map { ["SKILLGARDEN_DATA_DIR": $0] } ?? [:],
                                      savedSetting: saved, home: home)
    }
    #expect(try resolve(nil, nil) == Skillgarden.defaultDataDirectory)
    #expect(try resolve("/tmp/env-library", "/tmp/saved-library").path == "/tmp/env-library")
    #expect(try resolve(nil, "/tmp/saved-library").path == "/tmp/saved-library")
    // An empty value or a value of only spaces is skipped.
    #expect(try resolve("", "/tmp/saved-library").path == "/tmp/saved-library")
    #expect(try resolve("  \n", "/tmp/saved-library").path == "/tmp/saved-library")
    #expect(try resolve(" ", "  ") == Skillgarden.defaultDataDirectory)
    // A leading ~ expands to the home folder. Spaces around the value are removed.
    #expect(try resolve("~/Skillgarden Data", nil).path == "/Users/agent/Skillgarden Data")
    #expect(try resolve(nil, " ~ ").path == "/Users/agent")
    #expect(try resolve("/tmp/a/../library/", nil).path == "/tmp/library")
    // A relative path stops the lookup. The saved setting is not used in its place.
    #expect(throws: DataDirectoryError(source: "SKILLGARDEN_DATA_DIR")) { try resolve("library", "/tmp/saved-library") }
    #expect(throws: DataDirectoryError(source: "DataDirectory")) { try resolve(nil, "~agent/library") }
    #expect(DataDirectoryError(source: "DataDirectory").localizedDescription == "DataDirectory must be an absolute path")
}

@Test func customDataDirectoryPathIsNilForTheDefault() {
    #expect(Skillgarden.customDataDirectoryPath(Skillgarden.defaultDataDirectory) == nil)
    let same = URL(fileURLWithPath: Skillgarden.defaultDataDirectory.path + "/")
    #expect(Skillgarden.customDataDirectoryPath(same) == nil)
    #expect(Skillgarden.customDataDirectoryPath(URL(fileURLWithPath: "/tmp/library/")) == "/tmp/library")
}

@MainActor @Test func publishWritesToTheVariableFolderAndTheAppListsIt() async throws {
    try withCourse { folder, base in
        let library = base.appending(path: "agent library")
        let root = { try Skillgarden.dataDirectory(environment: ["SKILLGARDEN_DATA_DIR": library.path], savedSetting: nil) }
        let result = SkillgardenCommand.run(arguments: ["publish", folder.path], root: try root())
        #expect(result.exitCode == 0 && result.stderr.isEmpty)
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines.first == "Published \"Local Course Basics\" (sample-course, published): created 7, updated 0, unchanged 0, removed 0")
        #expect(lines.last.map(String.init) == "Library: \(library.path)")
        #expect(FileManager.default.fileExists(atPath: library.appending(path: "library.sqlite").path))
        #expect(try CourseStore(root: try root()).listCourses().map(\.id) == ["sample-course"])
    }
    // The app reads the same folder.
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenAgentApp-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    let root = try Skillgarden.dataDirectory(environment: ["SKILLGARDEN_DATA_DIR": base.path + "/library"], savedSetting: nil)
    #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root).exitCode == 0)
    let model = LibraryModel(root: root)
    await model.reload()
    #expect(model.errorMessage == nil)
    #expect(model.courses.map(\.id) == ["sample-course"])
}

@Test func relativeDataDirectoryExitsTwo() throws {
    try withCourse { folder, base in
        let bad = { try Skillgarden.dataDirectory(environment: ["SKILLGARDEN_DATA_DIR": "library"], savedSetting: nil) }
        let error = CommandResult(exitCode: 2, stdout: "", stderr: "error: SKILLGARDEN_DATA_DIR must be an absolute path\n")
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: try bad()) == error)
        #expect(SkillgardenCommand.run(arguments: ["internal", "list", "sample-course"], root: try bad()) == error)
        let saved = { try Skillgarden.dataDirectory(environment: [:], savedSetting: "library") }
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: try saved()) == CommandResult(
            exitCode: 2, stdout: "", stderr: "error: DataDirectory must be an absolute path\n"))
        // Commands that do not open the library still run.
        #expect(SkillgardenCommand.run(arguments: ["--version"], root: try bad()).exitCode == 0)
        #expect(SkillgardenCommand.run(arguments: ["validate", folder.path], root: try bad()).exitCode == 0)
    }
}

@Test func validateReportsTheCourseAndWritesNothing() throws {
    try withCourse { folder, base in
        let root = base.appending(path: "library")
        let before = try contents(of: base)
        #expect(SkillgardenCommand.run(arguments: ["validate", folder.path], root: root) == CommandResult(
            exitCode: 0, stdout: "Valid \"Local Course Basics\" (sample-course, published): 2 sections, 4 lectures\n", stderr: ""))
        #expect(try contents(of: base) == before)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        #expect(SkillgardenCommand.run(arguments: ["validate", folder.path], root: root) == CommandResult(exitCode: 0, stdout: """
            Valid "Local Course Basics" (sample-course, draft): 2 sections, 4 lectures
            Draft: learners do not see this course.

            """, stderr: ""))
        #expect(try CoursePublisher.validate(courseFolder: folder) == ValidationResult(
            title: "Local Course Basics", id: "sample-course", state: .draft, sections: 2, lectures: 4))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func validateErrorsMatchPublishErrors() throws {
    try withCourse { folder, base in
        let root = base.appending(path: "library")
        let manifest = folder.appending(path: "skillgarden.yaml").path
        try edit(folder, "    title: Plan the course\n", "")
        #expect(SkillgardenCommand.run(arguments: ["validate", folder.path], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(manifest): sections[0].title: required field is missing\n"))
        try edit(folder, "  - id: plan\n", "  - id: plan\n    title: Plan the course\n")
        // File checks run too, and every problem is listed.
        try edit(folder, "path: media/course.svg", "path: media/absent.svg")
        try FileManager.default.removeItem(at: folder.appending(path: "internal/research.md"))
        let expected = CommandResult(exitCode: 1, stdout: "", stderr: """
            error: \(folder.path): course_image.path: file does not exist
            error: \(folder.path): internal.files[0].path: file does not exist

            """)
        #expect(SkillgardenCommand.run(arguments: ["validate", folder.path], root: root) == expected)
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == expected)
        // A folder with no manifest is a validation error. A missing folder is an I/O error.
        let empty = base.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(SkillgardenCommand.run(arguments: ["validate", empty.path], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(empty.path): $: no skillgarden.yaml or skillgarden.json found\n"))
        let missing = base.appending(path: "absent").path
        #expect(SkillgardenCommand.run(arguments: ["validate", missing], root: root) == CommandResult(
            exitCode: 3, stdout: "", stderr: "error: course folder does not exist: \(missing)\n"))
        #expect(SkillgardenCommand.run(arguments: ["validate", manifest], root: root) == CommandResult(
            exitCode: 3, stdout: "", stderr: "error: course folder does not exist: \(manifest)\n"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func validateUsage() {
    let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenUnused-\(UUID())")
    let usage = SkillgardenCommand.usage + SkillgardenCommand.usageMore
    #expect(SkillgardenCommand.run(arguments: ["validate", "--help"], root: root)
            == CommandResult(exitCode: 0, stdout: SkillgardenCommand.help, stderr: ""))
    for arguments in [["validate"], ["validate", "a", "b"], ["validate", "--bogus"]] {
        #expect(SkillgardenCommand.run(arguments: arguments, root: root) == CommandResult(
            exitCode: 2, stdout: "", stderr: "error: expected validate <course-folder>\n" + usage))
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

/// The help names the guide and the skill, and the README links both (#113).
@Test func helpGuideAndSkillPathsExist() throws {
    let repo = fixture.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let help = SkillgardenCommand.help
    for line in ["Guide: docs/agent-publishing.md\n", "Skill: docs/agent-skill/SKILL.md\n"] {
        #expect(help.contains(line))
        let path = String(line.split(separator: " ")[1].dropLast())
        #expect(FileManager.default.fileExists(atPath: repo.appending(path: path).path), "\(path)")
    }
    for code in 0...3 { #expect(help.contains("\n  \(code)  ")) }

    let readme = try String(contentsOf: repo.appending(path: "README.md"), encoding: .utf8)
    #expect(readme.contains("(docs/agent-publishing.md)") && readme.contains("(docs/agent-skill/SKILL.md)"))
    let guide = try String(contentsOf: repo.appending(path: "docs/agent-publishing.md"), encoding: .utf8)
    #expect(guide.contains("docs/agent-skill/SKILL.md"))

    let skill = try String(contentsOf: repo.appending(path: "docs/agent-skill/SKILL.md"), encoding: .utf8)
    #expect(skill.hasPrefix("---\nname: skillgarden-publish\ndescription: "))
    let headings = skill.split(separator: "\n").filter { $0.hasPrefix("## ") }
    #expect(headings == ["## 1. Set the library in the workspace", "## 2. Validate", "## 3. Publish", "## 4. Check the result",
                         "## 5. Hand off to the owner"])
    // Each library setting in the skill is the workspace library. Nothing goes to the home folder.
    let settings = skill.components(separatedBy: "SKILLGARDEN_DATA_DIR=").dropFirst()
    #expect(!settings.isEmpty)
    for setting in settings { #expect(setting.hasPrefix("\"$PWD/.skillgarden-library\"")) }
    #expect(!skill.contains("$HOME") && !skill.contains("~/.local"))
}

/// The README sends learners to the install guide, which has the 8 first-use sections in order (#220).
@Test func installGuideCoversFirstUse() throws {
    let repo = fixture.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let readme = try String(contentsOf: repo.appending(path: "README.md"), encoding: .utf8)
    #expect(readme.contains("(docs/install.md)") && readme.contains("## Build from source"))

    let guide = try String(contentsOf: repo.appending(path: "docs/install.md"), encoding: .utf8)
    let headings = guide.split(separator: "\n").filter { $0.hasPrefix("## ") }
    #expect(headings == ["## 1. Requirements", "## 2. Install", "## 3. Your data", "## 4. Add a course", "## 5. Take a course",
                         "## 6. Q&A with the bundled model", "## 7. Remote providers (optional)", "## 8. Uninstall"])
    for text in ["Apple silicon", "~/Library/Application Support/Skillgarden", "\"Import Course…\" (⇧⌘I)", "\"Choose Model…\"",
                 "\"Allow and Send\"", "Keychain", "(agent-publishing.md)", "(local-ai.md)",
                 // #250: the CLI and agent skill install for app users.
                 "### Install the command line tool", "Skillgarden > \"Install Command Line Tool…\"", CommandLineTool.pathLine,
                 "### Install the agent skill", "skillgarden skill install ~/.claude/skills"] {
        #expect(guide.contains(text), "\(text)")
    }
    #expect(!guide.contains("http") && !guide.contains("Intel"))
}

@MainActor @Test func libraryShowsABadDataDirectorySetting() async {
    let model = LibraryModel(rootError: "SKILLGARDEN_DATA_DIR must be an absolute path")
    await model.reload()
    #expect(model.errorMessage == "SKILLGARDEN_DATA_DIR must be an absolute path")
    #expect(model.courses.isEmpty)
}
