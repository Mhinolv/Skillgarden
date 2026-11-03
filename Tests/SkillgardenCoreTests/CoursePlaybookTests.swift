import Foundation
import Testing
@testable import SkillgardenCore

// #252: the course playbook, `skillgarden playbook [--output <file>]` and the app menu texts.

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let docsCopy = "docs/agent-playbook/skillgarden-course-playbook.md"
private let unusedRoot = FileManager.default.temporaryDirectory.appending(path: "SkillgardenUnused-\(UUID())")

private func withBase(_ body: (URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenPlaybookTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try body(base)
}

/// The text between the opening fence that ends with `language` and the next closing fence, for each block.
private func codeBlocks(_ text: String, language: String) -> [String] {
    text.components(separatedBy: "```\(language)\n").dropFirst().compactMap { $0.components(separatedBy: "\n```").first }
}

@Test func docsCopyMatchesPlaybookConstant() throws {
    let copy = try String(contentsOf: repository.appending(path: docsCopy), encoding: .utf8)
    #expect(copy == CoursePlaybook.text, "Run skillgarden playbook --output \(docsCopy)")
    #expect(CoursePlaybook.fileName == "skillgarden-course-playbook.md")
    #expect(docsCopy.hasSuffix("/" + CoursePlaybook.fileName))
}

/// The playbook is harness-neutral: no private path, model id or name of an agent harness or private tool.
@Test func playbookHasNoPrivatePathOrHarnessName() throws {
    let copy = try String(contentsOf: repository.appending(path: docsCopy), encoding: .utf8)
    // Whole words, any case. "Mark" is case-sensitive below, because "marker" and "mark" are normal words.
    let words = ["claude", "anthropic", "codex", "openai", "gpt", "chatgpt", "cursor", "opencode", "gemini", "grok", "composer",
                 "opus", "sonnet", "haiku", "llama", "t3", "tmux", "mcp", "kokoro", "vibevoice", "elevenlabs", "coursebox",
                 "silkweb", "playwright", "udemy", "markhinojosa"]
    let patterns = words.map { "(?i)\\b\($0)\\b" } + [
        "\\bMark\\b",
        // Private paths: a home folder, the user library, dot folders of agent tools, and repository-only folders.
        "/Users/", "/home/", "~/", "\\$HOME", "\\.claude", "\\.codex", "\\.team", "Projects/",
        // Model ids, such as a name with a version number.
        "(?i)\\b[a-z]+-\\d+(\\.\\d+)*-(flash|high|pro|mini|sol)\\b",
    ]
    for text in [CoursePlaybook.markdown, copy] {
        for pattern in patterns {
            let match = text.range(of: pattern, options: .regularExpression)
            #expect(match == nil, "\(pattern): \(match.map { String(text[text.lineRange(for: $0)]) } ?? "")")
        }
    }
}

/// The phases, the gates, the media rule, the review rule and the hard rules of the owner decision (2026-11-02).
@Test func playbookCoversThePhasedPipeline() {
    let text = CoursePlaybook.markdown
    #expect(text.hasPrefix("# Skillgarden course playbook\n"))
    let headings = text.split(separator: "\n").filter { $0.hasPrefix("## ") }
    #expect(headings == ["## 1. How to use the course playbook", "## 2. Hard rules", "## 3. Phase 0: Kickoff (Gate 1)",
                         "## 4. Phase 1: Research", "## 5. Phase 2: Outline and objective map", "## 6. Phase 3: Scripts",
                         "## 7. Phase 4: Media", "## 8. Phase 5: Labs, quizzes, assignments and articles",
                         "## 9. Phase 6: Package and publish", "## 10. Final checklist"])
    // Each phase section ends with its gate.
    let phases = text.components(separatedBy: "\n## ").filter { $0.contains(". Phase ") }
    #expect(phases.count == 7)
    for phase in phases { #expect(phase.contains("**Gate"), "\(phase.prefix(40))") }

    for line in ["One agent can do all roles. If you can start subagents, you can give roles to them.",
                 "Each review runs 2 rounds at most.",
                 "If you have no such tools, make article, quiz and assignment lectures.",
                 "Never publish placeholder media",
                 "**Own content only.**", "**Official sources for facts.**", "**Invent nothing.**",
                 "**Fictional example data.**", "**No secrets or personal data.**",
                 "`skillgarden skill install <folder>`", "`skillgarden-publish` skill", "Skillgarden.complete()"] {
        #expect(text.contains(line), "\(line)")
    }
    let words = text.split(whereSeparator: { $0.isWhitespace }).count
    #expect((2_500...4_500).contains(words), "\(words) words")
}

/// Each `skillgarden <command>` in the playbook is a command of the usage text.
@Test func playbookNamesRealCommands() throws {
    let text = CoursePlaybook.markdown
    let regex = try Regex("skillgarden ([a-z][a-z-]*)")
    let commands = Set(text.matches(of: regex).compactMap { $0.output[1].substring.map(String.init) })
    #expect(commands.isSuperset(of: ["init", "validate", "publish", "doctor", "media", "skill", "schema", "inspect", "internal"]))
    for command in commands {
        #expect(SkillgardenCommand.usage.contains("skillgarden \(command) "), "\(command)")
    }
    #expect(text.contains("skillgarden publish --dry-run build/my-course"))
}

/// The manifest example uses the real fields and passes the manifest checks. File checks need a course folder, so they do not run.
@Test func playbookManifestExampleIsValid() throws {
    let example = try #require(codeBlocks(CoursePlaybook.markdown, language: "yaml").first { $0.hasPrefix("schema_version: 1\n") })
    try withBase { base in
        let file = base.appending(path: "skillgarden.yaml")
        try Data(example.utf8).write(to: file)
        let manifest = try ManifestLoader.load(file: file)
        #expect(manifest.id == "my-course")
        let types = Set(manifest.sections.flatMap(\.lectures).map(\.type.rawValue))
        #expect(types == ["video", "article", "interactive", "quiz", "assignment"])
    }
}

@Test func playbookCommandPrintsPlaybook() throws {
    #expect(SkillgardenCommand.run(arguments: ["playbook"], root: unusedRoot)
            == CommandResult(exitCode: 0, stdout: CoursePlaybook.text, stderr: ""))
    let json = SkillgardenCommand.run(arguments: ["playbook", "--json"], root: unusedRoot)
    #expect(json.exitCode == 0 && json.stderr.isEmpty)
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    #expect(object["command"] as? String == "playbook")
    #expect(object["ok"] as? Bool == true)
    #expect((object["result"] as? [String: Any])?["markdown"] as? String == CoursePlaybook.text)
    #expect(!FileManager.default.fileExists(atPath: unusedRoot.path))
}

@Test func playbookCommandWritesFile() throws {
    try withBase { base in
        let file = base.appending(path: CoursePlaybook.fileName)
        try Data("old".utf8).write(to: file)
        let result = SkillgardenCommand.run(arguments: ["playbook", "--output", file.path], root: unusedRoot)
        #expect(result == CommandResult(exitCode: 0, stdout: "Wrote course playbook to \(file.path)\n", stderr: ""))
        #expect(try String(contentsOf: file, encoding: .utf8) == CoursePlaybook.text)

        // The path is absolute in the message, also when the argument has `..` parts.
        try FileManager.default.createDirectory(at: base.appending(path: "sub"), withIntermediateDirectories: true)
        #expect(SkillgardenCommand.run(arguments: ["playbook", "--output", base.path + "/sub/../" + CoursePlaybook.fileName],
                                       root: unusedRoot).stdout == "Wrote course playbook to \(file.path)\n")

        let json = SkillgardenCommand.run(arguments: ["playbook", "--output", file.path, "--json"], root: unusedRoot)
        #expect(json.exitCode == 0 && json.stderr.isEmpty)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(object["command"] as? String == "playbook")
        #expect((object["result"] as? [String: Any])?["path"] as? String == file.path)

        // CoursePlaybook.write is the save of the app menu item. It replaces an earlier file.
        let saved = base.appending(path: "saved.md")
        try Data("old".utf8).write(to: saved)
        try CoursePlaybook.write(to: saved)
        #expect(try String(contentsOf: saved, encoding: .utf8) == CoursePlaybook.text)
    }
}

@Test func playbookCommandWriteFailureExits3() throws {
    try withBase { base in
        for target in [base.appending(path: "missing/playbook.md").path, base.path] {
            let result = SkillgardenCommand.run(arguments: ["playbook", "--output", target], root: unusedRoot)
            #expect(result.exitCode == 3)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.hasPrefix("error: ") && result.stderr.hasSuffix("\n") && !result.stderr.contains("usage:"))
            let json = SkillgardenCommand.run(arguments: ["playbook", "--output", target, "--json"], root: unusedRoot)
            let object = try #require(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
            #expect(object["ok"] as? Bool == false && object["exit_code"] as? Int == 3)
            #expect((object["diagnostics"] as? [[String: Any]])?.first?["code"] as? String == "io")
        }
        #expect(throws: (any Error).self) { try CoursePlaybook.write(to: base.appending(path: "missing/saved.md")) }
    }
}

@Test func playbookCommandUsage() throws {
    let usage = SkillgardenCommand.usage + SkillgardenCommand.usageMore
    #expect(usage.contains("       skillgarden schema [--output <file>]\n       skillgarden playbook [--output <file>]\n"))
    #expect(SkillgardenCommand.help.contains("  skillgarden playbook --output skillgarden-course-playbook.md\n"))
    #expect(SkillgardenCommand.help.contains("Course playbook: \(docsCopy)\n"))
    #expect(FileManager.default.fileExists(atPath: repository.appending(path: docsCopy).path))
    #expect(SkillgardenCommand.help.split(separator: "\n").allSatisfy { $0.count <= 80 })
    #expect(SkillgardenCommand.run(arguments: ["playbook", "--help"], root: unusedRoot)
            == CommandResult(exitCode: 0, stdout: SkillgardenCommand.help, stderr: ""))
    for arguments in [["playbook", "extra"], ["playbook", "--bogus"], ["playbook", "--output"], ["playbook", "--output", ""],
                      ["playbook", "--output", "-x"], ["playbook", "--output", "a", "b"], ["playbook", "a", "--output"]] {
        #expect(SkillgardenCommand.run(arguments: arguments, root: unusedRoot) == CommandResult(
            exitCode: 2, stdout: "", stderr: "error: expected playbook [--output <file>]\n" + usage), "\(arguments)")
    }
    let json = SkillgardenCommand.run(arguments: ["playbook", "--bogus", "--json"], root: unusedRoot)
    #expect(json.exitCode == 2 && json.stderr.isEmpty)
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    #expect(object["command"] as? String == "playbook")
    #expect(object["ok"] as? Bool == false)
}

/// The guide and the README point to the playbook. The alert text is the owner decision of 2026-11-02.
@Test func playbookDocsAndMenuTexts() throws {
    let guide = try String(contentsOf: repository.appending(path: "docs/agent-publishing.md"), encoding: .utf8)
    for text in ["`skillgarden playbook [--output <file>]`", "Wrote course playbook to <path>", docsCopy,
                 "Skillgarden > \"Copy Course Playbook\" or \"Save Course Playbook…\""] {
        #expect(guide.contains(text), "\(text)")
    }
    let readme = try String(contentsOf: repository.appending(path: "README.md"), encoding: .utf8)
    #expect(readme.contains("(\(docsCopy))"))
    #expect(CoursePlaybook.copiedMessage == "The course playbook is copied.")
    #expect(CoursePlaybook.copiedInformativeText
            == "Paste it into the chat of your agent. The agent publishes with the skillgarden command line tool.")
}

/// Install and first use has a playbook section. Both guides say that the playbook plans and builds, and `skillgarden-publish` publishes.
@Test func playbookDocsNamePairingWithPublishSkill() throws {
    let pairing = "The playbook plans and builds a course. The `skillgarden-publish` skill publishes it."
    let install = try String(contentsOf: repository.appending(path: "docs/install.md"), encoding: .utf8)
    let section = try #require(install.range(of: "### Get the course playbook"))
    let skillSection = try #require(install.range(of: "### Install the agent skill"))
    let dataSection = try #require(install.range(of: "## 3. Your data"))
    #expect(skillSection.upperBound <= section.lowerBound)
    #expect(section.upperBound <= dataSection.lowerBound)
    let body = String(install[section.upperBound..<dataSection.lowerBound])
    for text in ["\"Copy Course Playbook\"", "\"Save Course Playbook…\"", "skillgarden playbook --output <file>", pairing] {
        #expect(body.contains(text), "\(text)")
    }
    let guide = try String(contentsOf: repository.appending(path: "docs/agent-publishing.md"), encoding: .utf8)
    #expect(guide.contains(pairing))
}
