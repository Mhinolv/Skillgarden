import Foundation
import Testing

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")

private final class TestBundleMarker {}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "BundledCLITests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// `swift test` builds the CLI next to the test bundle.
private func builtCLI() throws -> URL {
    let cli = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "skillgarden")
    try #require(FileManager.default.isExecutableFile(atPath: cli.path), "build skillgarden before the tests")
    return cli
}

private struct Run {
    var status: Int32
    var output: String
    var errorText: String
}

private func run(_ executable: URL, _ arguments: [String], in folder: URL, path: String = "/usr/bin:/bin", environment: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = folder
    // PWD keeps the logical temporary path (/var/...), so script output matches `URL.path`.
    process.environment = ["HOME": NSHomeDirectory(), "PATH": path, "PWD": folder.path].merging(environment) { $1 }
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Run(status: process.terminationStatus, output: output, errorText: errorText)
}

/// Makes `<folder>/<name>` look like a built app: only the CLI at `Contents/Helpers/skillgarden`.
private func fakeApp(named name: String, in folder: URL) throws -> URL {
    let app = folder.appending(path: name)
    let helpers = app.appending(path: "Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: try builtCLI(), to: helpers.appending(path: "skillgarden"))
    return app
}

/// Copies `scripts/install_cli.sh` into a repository copy at `root`, so that `build/Skillgarden.app` is under test control.
private func installScript(in root: URL) throws -> URL {
    let scripts = root.appending(path: "scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let script = scripts.appending(path: "install_cli.sh")
    try FileManager.default.copyItem(at: repo.appending(path: "scripts/install_cli.sh"), to: script)
    return script
}

private func expectedVersion() throws -> String {
    let version = try run(try builtCLI(), ["--version"], in: repo).output
    return version.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "skillgarden ", with: "")
}

/// #107: the app bundle holds the CLI in Contents/Helpers, not next to the app binary in Contents/MacOS.
@Test func bundleScriptPutsTheCLIInHelpers() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appending(path: "scripts")
    let debug = root.appending(path: ".build/debug")
    let icon = root.appending(path: "assets/AppIcon")
    for folder in [scripts, debug, icon] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try FileManager.default.copyItem(at: repo.appending(path: "scripts/bundle_app.sh"), to: scripts.appending(path: "bundle_app.sh"))
    let stub = scripts.appending(path: "build.sh")
    try "#!/bin/sh\necho \"build $*\" >> build.log\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    try Data("app".utf8).write(to: debug.appending(path: "SkillgardenApp"))
    try FileManager.default.copyItem(at: try builtCLI(), to: debug.appending(path: "skillgarden"))
    try Data("host".utf8).write(to: debug.appending(path: "SkillgardenAIHost"))
    try Data("icon".utf8).write(to: icon.appending(path: "AppIcon.icns"))
    let llama = root.appending(path: "llama")
    try makeLlamaRuntime(at: llama, manifest: root.appending(path: "assets/llama.cpp/runtime.json"), server: try builtCLI())

    let bundle = try run(URL(fileURLWithPath: "/bin/zsh"), [scripts.appending(path: "bundle_app.sh").path], in: root,
                         environment: ["SKILLGARDEN_LLAMA_DIR": llama.path])
    #expect(bundle.status == 0, "\(bundle.errorText)")
    let log = try String(contentsOf: root.appending(path: "build.log"), encoding: .utf8)
    #expect(log == "build --product SkillgardenApp\nbuild --product skillgarden\nbuild --product SkillgardenAIHost\n")
    let contents = root.appending(path: "build/Skillgarden.app/Contents")
    let cli = contents.appending(path: "Helpers/skillgarden")
    #expect(FileManager.default.isExecutableFile(atPath: cli.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: contents.appending(path: "MacOS").path) == ["Skillgarden"])
    #expect(try run(cli, ["--version"], in: root, path: "/var/empty").status == 0)
}

/// #107: help and validate run from the bundled binary with no `swift` on PATH and no resource bundle beside it.
@Test func bundledCLIRunsAloneWithoutSwiftOnPath() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = try fakeApp(named: "Skillgarden.app", in: root).appending(path: "Contents/Helpers/skillgarden")
    #expect(try FileManager.default.contentsOfDirectory(atPath: cli.deletingLastPathComponent().path) == ["skillgarden"])

    let help = try run(cli, ["--help"], in: root, path: "/var/empty")
    #expect(help.status == 0)
    #expect(help.output.contains("skillgarden validate"))
    let validate = try run(cli, ["validate", fixture.path], in: root, path: "/var/empty")
    #expect(validate.status == 0, "\(validate.errorText)")
    #expect(validate.output.hasPrefix("Valid \"Local Course Basics\" (sample-course, published)"))
}

@Test func installScriptCopiesTheBundledCLIToAFolder() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try installScript(in: root.appending(path: "repo"))
    let app = try fakeApp(named: "My.app", in: root)
    let version = try expectedVersion()

    // A new relative folder resolves against the caller's folder, not the repository.
    let first = try run(script, ["--app", "My.app", "./bin"], in: root)
    #expect(first.status == 0, "\(first.errorText)")
    let installed = root.appending(path: "bin/skillgarden")
    #expect(first.output == "Installed skillgarden \(version) to \(installed.path) (from \(app.path))\n")
    #expect(!first.output.contains("PATH"))
    #expect(try run(installed, ["--version"], in: root, path: "/var/empty").status == 0)

    // A second call overwrites the earlier copy.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: installed.path)
    let second = try run(script, ["--app", app.path, root.appending(path: "bin").path], in: root)
    #expect(second.status == 0, "\(second.errorText)")
    #expect(second.output == first.output)

    // A trailing "/" makes missing nested folders.
    let nested = try run(script, ["--app", app.path, "a/b/c/"], in: root)
    #expect(nested.status == 0, "\(nested.errorText)")
    #expect(FileManager.default.isExecutableFile(atPath: root.appending(path: "a/b/c/skillgarden").path))
}

@Test func installScriptCopiesTheBundledCLIToAFilePath() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try installScript(in: root.appending(path: "repo"))
    let app = try fakeApp(named: "My.app", in: root)

    let named = try run(script, ["--app", app.path, "tools/skillgarden-dev"], in: root)
    #expect(named.status == 0, "\(named.errorText)")
    #expect(named.output.contains(" to \(root.appending(path: "tools/skillgarden-dev").path) "))
    #expect(FileManager.default.isExecutableFile(atPath: root.appending(path: "tools/skillgarden-dev").path))

    try Data("old".utf8).write(to: root.appending(path: "sg"))
    let existing = try run(script, ["--app=\(app.path)", "sg"], in: root)
    #expect(existing.status == 0, "\(existing.errorText)")
    #expect(FileManager.default.isExecutableFile(atPath: root.appending(path: "sg").path))
    #expect(try run(root.appending(path: "sg"), ["--version"], in: root).status == 0)
}

@Test func installScriptFindsTheRepositoryAppWithoutTheAppOption() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appending(path: "repo")
    let script = try installScript(in: checkout)
    let app = try fakeApp(named: "build/Skillgarden.app", in: checkout)

    let install = try run(script, ["out"], in: root)
    #expect(install.status == 0, "\(install.errorText)")
    #expect(install.output.hasSuffix(" to \(root.appending(path: "out/skillgarden").path) (from \(app.path))\n"))
}

@Test func installScriptReportsErrorsOnStderr() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try installScript(in: root.appending(path: "repo"))
    let app = try fakeApp(named: "My.app", in: root)

    try FileManager.default.createDirectory(at: root.appending(path: "Empty.app"), withIntermediateDirectories: true)
    let missing = try run(script, ["--app", "Empty.app", "out"], in: root)
    #expect(missing.status == 1)
    #expect(missing.output.isEmpty)
    #expect(missing.errorText == "error: no skillgarden binary at \(root.appending(path: "Empty.app").path)/Contents/Helpers/skillgarden\n")

    let readOnly = root.appending(path: "ro")
    try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
    let denied = try run(script, ["--app", app.path, "ro"], in: root)
    #expect(denied.status == 1)
    #expect(denied.output.isEmpty)
    #expect(denied.errorText.hasPrefix("error: "))

    let usage = try run(script, ["--bogus"], in: root)
    #expect(usage.status == 2)
    #expect(usage.errorText.contains("usage: scripts/install_cli.sh [--app <Skillgarden.app>] [<destination>]"))
}
