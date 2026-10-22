import Foundation
import Testing
@testable import SkillgardenCore

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

/// The license notices that bundle_app.sh copies from the repository (#213), by component.
private let repositoryNotices = ["Skillgarden": "LICENSE", "Yams": "Vendor/Yams/LICENSE",
                                 "libyaml": "Vendor/Yams/Sources/CYaml/LICENSE"]

/// The Swift file that holds the release constants that bundle_app.sh reads (#214).
private let releaseSourcePath = "Sources/SkillgardenCore/Skillgarden.swift"

/// A repository copy with bundle_app.sh, a stub build.sh that logs its calls, the icon, the license notices
/// and a prepared llama.cpp runtime.
/// `products` lists the configurations that get stub build products. The stub CLI prints its configuration for `--version`.
private func bundleRepository(in root: URL, products: [String] = ["debug", "release"]) throws -> (script: URL, llama: URL) {
    let scripts = root.appending(path: "scripts")
    let icon = root.appending(path: "assets/AppIcon")
    for folder in [scripts, icon] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try FileManager.default.copyItem(at: repo.appending(path: "scripts/bundle_app.sh"), to: scripts.appending(path: "bundle_app.sh"))
    let stub = scripts.appending(path: "build.sh")
    try "#!/bin/sh\necho \"build $*\" >> build.log\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    for configuration in products {
        let folder = root.appending(path: ".build/\(configuration)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("app \(configuration)".utf8).write(to: folder.appending(path: "SkillgardenApp"))
        let cli = folder.appending(path: "skillgarden")
        try "#!/bin/sh\necho \"skillgarden \(configuration)\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try Data("host \(configuration)".utf8).write(to: folder.appending(path: "SkillgardenAIHost"))
    }
    try Data("icon".utf8).write(to: icon.appending(path: "AppIcon.icns"))
    let releaseSource = root.appending(path: releaseSourcePath)
    try FileManager.default.createDirectory(at: releaseSource.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repo.appending(path: releaseSourcePath), to: releaseSource)
    for (component, path) in repositoryNotices {
        let notice = root.appending(path: path)
        try FileManager.default.createDirectory(at: notice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(component) license".utf8).write(to: notice)
    }
    let llama = root.appending(path: "llama")
    try makeLlamaRuntime(at: llama, manifest: root.appending(path: "assets/llama.cpp/runtime.json"), server: try builtCLI())
    return (scripts.appending(path: "bundle_app.sh"), llama)
}

private func runBundle(_ arguments: [String], in root: URL, llama: URL) throws -> Run {
    let script = root.appending(path: "scripts/bundle_app.sh")
    return try run(URL(fileURLWithPath: "/bin/zsh"), [script.path] + arguments, in: root, environment: ["SKILLGARDEN_LLAMA_DIR": llama.path])
}

private func buildLog(in root: URL) -> String? {
    try? String(contentsOf: root.appending(path: "build.log"), encoding: .utf8)
}

/// #107: the app bundle holds the CLI in Contents/Helpers, not next to the app binary in Contents/MacOS.
@Test func bundleScriptPutsTheCLIInHelpers() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    try FileManager.default.removeItem(at: root.appending(path: ".build/debug/skillgarden"))
    try FileManager.default.copyItem(at: try builtCLI(), to: root.appending(path: ".build/debug/skillgarden"))

    let bundle = try runBundle([], in: root, llama: llama)
    #expect(bundle.status == 0, "\(bundle.errorText)")
    let contents = root.appending(path: "build/Skillgarden.app/Contents")
    let cli = contents.appending(path: "Helpers/skillgarden")
    #expect(FileManager.default.isExecutableFile(atPath: cli.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: contents.appending(path: "MacOS").path) == ["Skillgarden"])
    #expect(try run(cli, ["--version"], in: root, path: "/var/empty").status == 0)
}

/// #211: all three executables come from the chosen configuration. No argument means debug.
@Test(arguments: [([String](), "debug"), (["debug"], "debug"), (["release"], "release")])
func bundleScriptUsesTheChosenConfiguration(arguments: [String], configuration: String) throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)

    let bundle = try runBundle(arguments, in: root, llama: llama)
    #expect(bundle.status == 0, "\(bundle.errorText)")
    #expect(bundle.errorText.isEmpty)
    #expect(bundle.output.hasSuffix("\nBundled Skillgarden (\(configuration)) into build/Skillgarden.app\n"))
    #expect(buildLog(in: root) == ["SkillgardenApp", "skillgarden", "SkillgardenAIHost"]
        .map { "build --configuration \(configuration) --product \($0)\n" }.joined())
    let contents = root.appending(path: "build/Skillgarden.app/Contents")
    #expect(try String(contentsOf: contents.appending(path: "MacOS/Skillgarden"), encoding: .utf8) == "app \(configuration)")
    #expect(try String(contentsOf: contents.appending(path: "Helpers/SkillgardenAIHost"), encoding: .utf8) == "host \(configuration)")
    let cli = try run(contents.appending(path: "Helpers/skillgarden"), ["--version"], in: root)
    #expect(cli.output == "skillgarden \(configuration)\n")
}

/// #211: a later bundle in the other configuration replaces every executable of the earlier one.
@Test func bundleScriptDoesNotKeepExecutablesFromAnEarlierConfiguration() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    #expect(try runBundle(["release"], in: root, llama: llama).status == 0)
    #expect(try runBundle(["debug"], in: root, llama: llama).status == 0)

    let contents = root.appending(path: "build/Skillgarden.app/Contents")
    for file in ["MacOS/Skillgarden", "Helpers/skillgarden", "Helpers/SkillgardenAIHost"] {
        let text = try String(contentsOf: contents.appending(path: file), encoding: .utf8)
        #expect(text.contains("debug") && !text.contains("release"), "\(file)")
    }
}

/// #211: help goes to stdout. An unknown value prints the usage to stderr, exits 2 and builds nothing.
@Test func bundleScriptPrintsUsageForHelpAndUnknownValues() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    let usage = "usage: scripts/bundle_app.sh [debug|release]\n"

    for flag in ["-h", "--help"] {
        let help = try runBundle([flag], in: root, llama: llama)
        #expect(help.status == 0)
        #expect(help.output == usage)
        #expect(help.errorText.isEmpty)
    }
    for arguments in [["Release"], ["profile"], [""], ["release", "debug"]] {
        let unknown = try runBundle(arguments, in: root, llama: llama)
        #expect(unknown.status == 2, "\(arguments)")
        #expect(unknown.output.isEmpty)
        #expect(unknown.errorText == usage)
    }
    #expect(buildLog(in: root) == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build/Skillgarden.app").path))
}

/// #211: a missing release product stops the script. It does not copy the debug product in its place.
@Test func bundleScriptStopsWhenAProductOfTheConfigurationIsMissing() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    try FileManager.default.removeItem(at: root.appending(path: ".build/release/SkillgardenAIHost"))

    let bundle = try runBundle(["release"], in: root, llama: llama)
    #expect(bundle.status == 1)
    #expect(bundle.output.isEmpty)
    #expect(bundle.errorText == "error: .build/release/SkillgardenAIHost not found\n")
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build/Skillgarden.app").path))
}

/// #213: the bundle holds one folder of license notices for each component, under the original file names.
@Test func bundleScriptCopiesEveryLicenseNotice() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)

    let bundle = try runBundle([], in: root, llama: llama)
    #expect(bundle.status == 0, "\(bundle.errorText)")
    #expect(bundle.output.contains("\nCopied license notices: Skillgarden, Yams, libyaml, llama.cpp\n"))
    let licenses = root.appending(path: "build/Skillgarden.app/Contents/Resources/Licenses")
    #expect(try FileManager.default.contentsOfDirectory(atPath: licenses.path).sorted() == ["Skillgarden", "Yams", "libyaml", "llama.cpp"])
    for component in repositoryNotices.keys {
        #expect(try FileManager.default.contentsOfDirectory(atPath: licenses.appending(path: component).path) == ["LICENSE"])
        #expect(try String(contentsOf: licenses.appending(path: "\(component)/LICENSE"), encoding: .utf8) == "\(component) license")
    }
    #expect(try String(contentsOf: licenses.appending(path: "llama.cpp/LICENSE"), encoding: .utf8) == "MIT License")
}

/// #213: a missing notice stops the script before the build. It does not make an app without the notice.
@Test(arguments: ["LICENSE", "Vendor/Yams/LICENSE", "Vendor/Yams/Sources/CYaml/LICENSE"])
func bundleScriptStopsWhenALicenseNoticeIsMissing(path: String) throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    try FileManager.default.removeItem(at: root.appending(path: path))

    let bundle = try runBundle([], in: root, llama: llama)
    #expect(bundle.status == 1)
    #expect(bundle.output.isEmpty)
    #expect(bundle.errorText == "error: missing license notice: \(path)\n")
    #expect(buildLog(in: root) == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build/Skillgarden.app").path))
}

private func bundlePlist(in root: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appending(path: "build/Skillgarden.app/Contents/Info.plist"))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

/// #214: the bundled plist holds the version, build, copyright and category from Skillgarden.swift.
/// The bundled CLI prints the same version as the plist.
@Test func bundleScriptSetsReleaseMetadataFromTheSwiftConstants() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    try FileManager.default.removeItem(at: root.appending(path: ".build/debug/skillgarden"))
    try FileManager.default.copyItem(at: try builtCLI(), to: root.appending(path: ".build/debug/skillgarden"))

    let bundle = try runBundle([], in: root, llama: llama)
    #expect(bundle.status == 0, "\(bundle.errorText)")
    let plist = try bundlePlist(in: root)
    #expect(plist["CFBundleShortVersionString"] as? String == Skillgarden.version)
    #expect(plist["CFBundleVersion"] as? String == String(Skillgarden.buildNumber))
    #expect(plist["NSHumanReadableCopyright"] as? String == Skillgarden.copyright)
    #expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.education")
    #expect(plist["CFBundleIdentifier"] as? String == "dev.skillgarden.app")
    let cli = try run(root.appending(path: "build/Skillgarden.app/Contents/Helpers/skillgarden"), ["--version"], in: root)
    #expect(cli.output == "skillgarden \(plist["CFBundleShortVersionString"] as? String ?? "")\n")
}

/// #214: the script reads the values from the file. It does not keep its own copy of the numbers.
@Test func bundleScriptReadsChangedReleaseConstants() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    let source = root.appending(path: releaseSourcePath)
    try """
    public enum Skillgarden {
        public static let version = "12.3.45"
        public static let buildNumber = 678
        public static let copyright = "Copyright © 2031 Other contributors."
    }
    """.write(to: source, atomically: true, encoding: .utf8)

    #expect(try runBundle([], in: root, llama: llama).status == 0)
    let plist = try bundlePlist(in: root)
    #expect(plist["CFBundleShortVersionString"] as? String == "12.3.45")
    #expect(plist["CFBundleVersion"] as? String == "678")
    #expect(plist["NSHumanReadableCopyright"] as? String == "Copyright © 2031 Other contributors.")
}

/// #214: a release constant that the script cannot read stops the script before the build, with the name of the value.
@Test(arguments: [("version", "public static let version = \"0.1.0\"", "public static let version = Self.other"),
                  ("buildNumber", "public static let buildNumber = 1", "public static let buildNumber = \"1\""),
                  ("buildNumber", "public static let buildNumber = 1", "public static let buildNumber = 1.5"),
                  ("copyright", "public static let copyright = ", "static let copyrightText = ")])
func bundleScriptStopsWhenAReleaseConstantIsMissing(name: String, line: String, replacement: String) throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, llama) = try bundleRepository(in: root)
    let source = root.appending(path: releaseSourcePath)
    let text = try String(contentsOf: source, encoding: .utf8)
    try #require(text.contains(line))
    try text.replacingOccurrences(of: line, with: replacement).write(to: source, atomically: true, encoding: .utf8)

    let bundle = try runBundle([], in: root, llama: llama)
    #expect(bundle.status == 1)
    #expect(bundle.output.isEmpty)
    #expect(bundle.errorText == "error: Skillgarden.\(name) not found in \(releaseSourcePath)\n")
    #expect(buildLog(in: root) == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build/Skillgarden.app").path))
}

/// #214: the copyright constant names the same year and holder as LICENSE.
@Test func copyrightConstantMatchesTheLicense() throws {
    let license = try String(contentsOf: repo.appending(path: "LICENSE"), encoding: .utf8)
    let line = Skillgarden.copyright.replacingOccurrences(of: "©", with: "(c)")
    #expect(line.hasSuffix("."))
    #expect(license.contains("\n\(line.dropLast())\n"))
    #expect(Skillgarden.buildNumber > 0)
}

/// #213: the real notices exist in the repository, and the docs list each notice that ships in the app.
@Test func repositoryHasEveryDocumentedLicenseNotice() throws {
    for path in repositoryNotices.values {
        let text = try String(contentsOf: repo.appending(path: path), encoding: .utf8)
        #expect(text.contains("Permission is hereby granted, free of charge") && text.contains("Copyright"), "\(path)")
    }
    // The libyaml notice is the upstream yaml/libyaml License file, byte for byte.
    let libyaml = try String(contentsOf: repo.appending(path: "Vendor/Yams/Sources/CYaml/LICENSE"), encoding: .utf8)
    #expect(libyaml.hasPrefix("Copyright (c) 2017-2020 Ingy döt Net\nCopyright (c) 2006-2016 Kirill Simonov\n\n"))
    #expect(libyaml.hasSuffix("OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\nSOFTWARE.\n"))
    let doc = try String(contentsOf: repo.appending(path: "docs/local-ai.md"), encoding: .utf8)
    for row in ["| Skillgarden | `Licenses/Skillgarden/LICENSE` | `LICENSE` |",
                "| Yams | `Licenses/Yams/LICENSE` | `Vendor/Yams/LICENSE` |",
                "| libyaml | `Licenses/libyaml/LICENSE` | `Vendor/Yams/Sources/CYaml/LICENSE` |",
                "| llama.cpp | `Licenses/llama.cpp/LICENSE` |"] {
        let listed = doc.contains(row)
        #expect(listed, "\(row)")
    }
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
