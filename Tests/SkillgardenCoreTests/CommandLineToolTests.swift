import Foundation
import Testing
@testable import SkillgardenCore

// #250: Skillgarden > "Install Command Line Tool…" and `skillgarden skill install <folder>`.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CommandLineToolTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// `<root>/Applications/Skillgarden.app` with a stub CLI, and a tool for `<root>/home`.
private func tool(in root: URL, app name: String = "Applications/Skillgarden.app") throws -> CommandLineTool {
    let app = root.appending(path: name)
    let helpers = app.appending(path: "Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    try "#!/bin/sh\necho skillgarden\n".write(to: helpers.appending(path: "skillgarden"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helpers.appending(path: "skillgarden").path)
    return CommandLineTool(app: app, home: root.appending(path: "home"), applicationFolders: [root.appending(path: "Applications")])
}

@Test func commandLineToolMakesTheBinFolderAndTheSymlink() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root)
    #expect(tool.link.path == root.appending(path: "home/.local/bin/skillgarden").path)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "home").path))

    #expect(try tool.check() == .absent)
    try tool.install()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tool.link.path) == tool.cli.path)
    #expect(try tool.check() == .symlink)
}

/// A symlink to another place, such as an older app path, is replaced with no question.
@Test func commandLineToolReplacesAnySymlink() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root)
    try FileManager.default.createDirectory(at: tool.link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: tool.link.path, withDestinationPath: "/nowhere/skillgarden")

    #expect(try tool.check() == .symlink)
    try tool.install()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tool.link.path) == tool.cli.path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: tool.link.deletingLastPathComponent().path) == ["skillgarden"])
}

/// A copy from scripts/install_cli.sh is a regular file. The app asks, then install replaces it.
@Test func commandLineToolReportsACopiedCLIAndReplacesIt() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root)
    try FileManager.default.createDirectory(at: tool.link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old copy".utf8).write(to: tool.link)

    #expect(try tool.check() == .regularFile)
    #expect(try Data(contentsOf: tool.link) == Data("old copy".utf8))
    try tool.install()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tool.link.path) == tool.cli.path)
}

@Test func commandLineToolDoesNotReplaceAFolder() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root)
    try FileManager.default.createDirectory(at: tool.link, withIntermediateDirectories: true)

    #expect(throws: CommandLineTool.InstallError.notAFile(path: tool.link.path)) { try tool.check() }
    #expect(throws: CommandLineTool.InstallError.notAFile(path: tool.link.path)) { try tool.install() }
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: tool.link.path, isDirectory: &isDirectory) && isDirectory.boolValue)
}

/// The owner decision of 2026-10-26: stop when the app is not in Applications. A link to a translocated app would break.
@Test(arguments: ["Downloads/Skillgarden.app", "build/Skillgarden.app", "ApplicationsOld/Skillgarden.app",
                  "Applications/AppTranslocation/ABC/d/Skillgarden.app"])
func commandLineToolStopsOutsideApplications(app: String) throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root, app: app)

    #expect(!tool.isInApplications)
    #expect(throws: CommandLineTool.InstallError.notInApplications) { try tool.install() }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "home").path))
    #expect(CommandLineTool.InstallError.notInApplications.localizedDescription == "Move Skillgarden to the Applications folder, then try again.")
}

@Test func commandLineToolAcceptsTheApplicationFolders() {
    let home = URL(fileURLWithPath: "/Users/learner")
    for path in ["/Applications/Skillgarden.app", "/Applications/Education/Skillgarden.app", "/Users/learner/Applications/Skillgarden.app"] {
        #expect(CommandLineTool(app: URL(fileURLWithPath: path), home: home).isInApplications, "\(path)")
    }
    for path in ["/Users/learner/Downloads/Skillgarden.app", "/Volumes/Skillgarden/Skillgarden.app",
                 "/private/var/folders/x/AppTranslocation/1/d/Skillgarden.app", "/Users/other/Applications/Skillgarden.app"] {
        #expect(!CommandLineTool(app: URL(fileURLWithPath: path), home: home).isInApplications, "\(path)")
    }
}

@Test func commandLineToolStopsWithoutABundledCLI() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root)
    try FileManager.default.removeItem(at: tool.cli)

    #expect(throws: CommandLineTool.InstallError.noBundledCLI(path: tool.cli.path)) { try tool.install() }
    #expect(CommandLineTool.InstallError.noBundledCLI(path: "/A/skillgarden").localizedDescription
        == "The app has no skillgarden command at /A/skillgarden.")
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "home").path))
}

@Test func commandLineToolReportsAReadOnlyBinFolder() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root)
    let bin = tool.link.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path) }

    #expect { try tool.install() } throws: { error in
        guard case .write = error as? CommandLineTool.InstallError else { return false }
        return true
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
}

/// The alert copy of the design notes, so QA can check it in code.
@Test func commandLineToolAlertCopy() {
    #expect(CommandLineTool.successMessage == "The skillgarden command is installed.")
    #expect(CommandLineTool.successInformation
        == "Run skillgarden --help in Terminal. If Terminal does not find it, add the PATH line to ~/.zshrc.")
    #expect(CommandLineTool.pathLine == "export PATH=\"$HOME/.local/bin:$PATH\"")
    #expect(CommandLineTool.replaceMessage == "Replace the existing skillgarden command?")
    #expect(CommandLineTool.replaceInformation == "The new command follows app updates.")
    #expect(CommandLineTool.failureMessage == "Can't install the command line tool.")
}

// MARK: - skillgarden skill install

/// A bundled skill folder with the repository files, as bundle_app.sh copies them.
private func bundledSkill(in root: URL) throws -> URL {
    let folder = root.appending(path: "Skillgarden.app/Contents/Resources/AgentSkill")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repo.appending(path: "docs/agent-skill/SKILL.md"), to: folder.appending(path: "SKILL.md"))
    try FileManager.default.copyItem(at: repo.appending(path: "docs/agent-publishing.md"), to: folder.appending(path: "agent-publishing.md"))
    return folder
}

private func runSkill(_ arguments: [String], source: URL?, in root: URL) -> CommandResult {
    SkillgardenCommand.run(arguments: arguments, root: root.appending(path: "unused-library"), skill: source)
}

@Test func skillInstallWritesTheSkillAndTheGuide() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try bundledSkill(in: root)
    let folder = root.appending(path: "a/b/skills")
    let installed = folder.appending(path: "skillgarden-publish")

    let result = runSkill(["skill", "install", folder.path], source: source, in: root)
    #expect(result == CommandResult(exitCode: 0, stdout: "Installed skill skillgarden-publish to \(installed.path)\n", stderr: ""))
    #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted() == ["SKILL.md", "agent-publishing.md"])
    #expect(try Data(contentsOf: installed.appending(path: "agent-publishing.md")) == Data(contentsOf: source.appending(path: "agent-publishing.md")))
    // The installed skill links the guide next to it. The rest of the text does not change.
    let skill = try String(contentsOf: installed.appending(path: "SKILL.md"), encoding: .utf8)
    let original = try String(contentsOf: source.appending(path: "SKILL.md"), encoding: .utf8)
    #expect(skill.contains("[agent-publishing.md](agent-publishing.md)"))
    #expect(!skill.contains("docs/agent-publishing.md") && !skill.contains("../agent-publishing.md"))
    #expect(original.contains("(../agent-publishing.md)"))
    #expect(skill == AgentSkill.installedSkill(original))
    #expect(skill.hasPrefix("---\nname: skillgarden-publish\n"))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "unused-library").path))
}

/// A second install replaces old files silently. Other files in the folder stay.
@Test func skillInstallReplacesOldFiles() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try bundledSkill(in: root)
    let installed = root.appending(path: "skills/skillgarden-publish")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: installed.appending(path: "SKILL.md"))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: installed.appending(path: "SKILL.md").path)
    try Data("mine".utf8).write(to: root.appending(path: "skills/notes.md"))

    let first = runSkill(["skill", "install", root.appending(path: "skills").path], source: source, in: root)
    #expect(first.exitCode == 0, "\(first.stderr)")
    let second = runSkill(["skill", "install", root.appending(path: "skills/").path], source: source, in: root)
    #expect(second == first)
    #expect(try String(contentsOf: installed.appending(path: "SKILL.md"), encoding: .utf8).hasPrefix("---\nname: skillgarden-publish"))
    #expect(try String(contentsOf: root.appending(path: "skills/notes.md"), encoding: .utf8) == "mine")
}

@Test func skillInstallJSON() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try bundledSkill(in: root)
    let installed = root.appending(path: "skills/skillgarden-publish")

    let result = runSkill(["skill", "--json", "install", root.appending(path: "skills").path], source: source, in: root)
    #expect(result.exitCode == 0 && result.stderr.isEmpty)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    #expect(object["command"] as? String == "skill install")
    #expect(object["ok"] as? Bool == true)
    let value = try #require(object["result"] as? [String: Any])
    #expect(value["name"] as? String == "skillgarden-publish")
    #expect(value["path"] as? String == installed.path)
    #expect(value["files"] as? [String] == [installed.appending(path: "SKILL.md").path, installed.appending(path: "agent-publishing.md").path])
}

/// A CLI from a source build has no Contents/Resources/AgentSkill. The command writes nothing.
@Test func skillInstallStopsWithoutABundledSkill() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try bundledSkill(in: root)
    try FileManager.default.removeItem(at: source.appending(path: "agent-publishing.md"))
    let missing = source.appending(path: "agent-publishing.md").path

    let result = runSkill(["skill", "install", root.appending(path: "skills").path], source: source, in: root)
    #expect(result == CommandResult(exitCode: 3, stdout: "", stderr: """
        error: no bundled agent skill at \(missing)
        hint: Run the skillgarden command of Skillgarden.app. A source build has no bundled skill.

        """))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "skills").path))

    let json = runSkill(["skill", "install", root.appending(path: "skills").path, "--json"], source: nil, in: root)
    #expect(json.exitCode == 3)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    let diagnostic = try #require((object["diagnostics"] as? [[String: Any]])?.first)
    #expect(diagnostic["code"] as? String == "skill.not_bundled")
}

@Test func skillInstallStopsAtAFile() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try bundledSkill(in: root)
    let file = root.appending(path: "skills")
    try Data("file".utf8).write(to: file)

    #expect(runSkill(["skill", "install", file.path], source: source, in: root)
        == CommandResult(exitCode: 3, stdout: "", stderr: "error: not a folder: \(file.path)\n"))
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    try Data("file".utf8).write(to: file.appending(path: "skillgarden-publish"))
    #expect(runSkill(["skill", "install", file.path], source: source, in: root)
        == CommandResult(exitCode: 3, stdout: "", stderr: "error: not a folder: \(file.appending(path: "skillgarden-publish").path)\n"))
}

@Test func skillInstallUsage() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let usage = SkillgardenCommand.usage + SkillgardenCommand.usageMore
    for arguments in [["skill", "--help"], ["skill", "install", "--help"]] {
        #expect(runSkill(arguments, source: nil, in: root) == CommandResult(exitCode: 0, stdout: SkillgardenCommand.help, stderr: ""))
    }
    for arguments in [["skill"], ["skill", "install"], ["skill", "add", "x"], ["skill", "install", "a", "b"], ["skill", "install", "--bogus"],
                      ["skill", "install", ""]] {
        #expect(runSkill(arguments, source: nil, in: root) == CommandResult(
            exitCode: 2, stdout: "", stderr: "error: expected skill install <folder>\n" + usage), "\(arguments)")
    }
    #expect(SkillgardenCommand.usage.contains("skillgarden skill install <folder> [--json]\n"))
    #expect(SkillgardenCommand.help.contains("  skillgarden skill install ~/.claude/skills\n"))
    for line in SkillgardenCommand.help.split(separator: "\n") { #expect(line.count <= 80) }
}

/// The bundled folder is Contents/Resources/AgentSkill of the app, also when the CLI runs through a symlink.
@Test func bundledSkillFolderFollowsTheSymlink() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try tool(in: root)
    try tool.install()
    let expected = tool.app.appending(path: "Contents/Resources/AgentSkill").resolvingSymlinksInPath().path
    #expect(AgentSkill.bundledFolder(executable: tool.link)?.resolvingSymlinksInPath().path == expected)
    #expect(AgentSkill.bundledFolder(executable: tool.cli)?.resolvingSymlinksInPath().path == expected)
    #expect(AgentSkill.bundledFolder(executable: nil) == nil)
}
