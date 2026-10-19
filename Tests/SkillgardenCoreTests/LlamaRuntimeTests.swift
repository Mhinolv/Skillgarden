import CryptoKit
import Foundation
import Testing

// #121: the app bundle holds a pinned llama.cpp runtime. These tests cover scripts/bundle_app.sh,
// scripts/check_llama_runtime.sh and the pinned manifest in assets/llama.cpp/runtime.json.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let preparedRuntime = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/share/skillgarden/llama.cpp/b11669")

private final class TestBundleMarker {}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LlamaRuntimeTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// `swift test` builds the CLI next to the test bundle. It is an arm64 Mach-O file with only system libraries.
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

private func run(_ executable: URL, _ arguments: [String], in folder: URL, environment: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = folder
    // PWD keeps the logical temporary path (/var/...), so script output matches `URL.path`.
    process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "PWD": folder.path].merging(environment) { $1 }
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Run(status: process.terminationStatus, output: output, errorText: errorText)
}

private func tool(_ path: String, _ arguments: [String]) throws {
    let result = try run(URL(fileURLWithPath: path), arguments, in: FileManager.default.temporaryDirectory)
    try #require(result.status == 0, "\(path) \(arguments): \(result.errorText)")
}

private func sha256(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
}

private func writeManifest(_ files: [String: URL], version: String = "b1", to manifest: URL) throws {
    var sha = [String: String]()
    for (name, file) in files { sha[name] = try sha256(file) }
    let json: [String: Any] = ["name": "llama.cpp", "version": version, "architecture": "arm64",
                               "minimumSystemVersion": "13.3", "sha256": sha]
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
}

/// Makes a prepared runtime folder like a llama.cpp release: `server` as llama-server, a versioned library with
/// a release symlink, a LICENSE and an extra tool. The manifest pins llama-server, the symlink name and LICENSE.
func makeLlamaRuntime(at folder: URL, manifest: URL, server: URL) throws {
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    try files.copyItem(at: server, to: folder.appending(path: "llama-server"))
    try Data("library".utf8).write(to: folder.appending(path: "libfake.0.1.0.dylib"))
    try files.createSymbolicLink(atPath: folder.appending(path: "libfake.0.dylib").path, withDestinationPath: "libfake.0.1.0.dylib")
    try Data("MIT License".utf8).write(to: folder.appending(path: "LICENSE"))
    try Data("other tool".utf8).write(to: folder.appending(path: "llama-cli"))
    try writeManifest(["llama-server": folder.appending(path: "llama-server"),
                       "libfake.0.dylib": folder.appending(path: "libfake.0.1.0.dylib"),
                       "LICENSE": folder.appending(path: "LICENSE")], to: manifest)
}

/// A repository copy with bundle_app.sh, a stub build.sh that logs its calls, and stub build products.
private func bundleRepository(in root: URL) throws -> URL {
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
    try Data("cli".utf8).write(to: debug.appending(path: "skillgarden"))
    try Data("host".utf8).write(to: debug.appending(path: "SkillgardenAIHost"))
    try Data("icon".utf8).write(to: icon.appending(path: "AppIcon.icns"))
    return scripts.appending(path: "bundle_app.sh")
}

@Test func bundleScriptCopiesThePinnedRuntime() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try bundleRepository(in: root)
    let manifest = root.appending(path: "assets/llama.cpp/runtime.json")
    // The default folder is ~/.local/share/skillgarden/llama.cpp/<version>.
    let home = root.appending(path: "home")
    try makeLlamaRuntime(at: home.appending(path: ".local/share/skillgarden/llama.cpp/b1"), manifest: manifest, server: try builtCLI())

    let bundle = try run(URL(fileURLWithPath: "/bin/zsh"), [script.path], in: root, environment: ["HOME": home.path])
    #expect(bundle.status == 0, "\(bundle.errorText)")
    #expect(bundle.output == "Bundled llama.cpp b1 (arm64) into build/Skillgarden.app\n")
    #expect(bundle.errorText.isEmpty)

    let contents = root.appending(path: "build/Skillgarden.app/Contents")
    let llama = contents.appending(path: "Helpers/llama")
    // Only llama-server and its libraries: no other release tool, no symlink, no license.
    #expect(try FileManager.default.contentsOfDirectory(atPath: llama.path).sorted() == ["libfake.0.dylib", "llama-server", "runtime.json"])
    // The release symlink becomes a copy of the file that it points to.
    let library = try FileManager.default.attributesOfItem(atPath: llama.appending(path: "libfake.0.dylib").path)
    #expect(library[.type] as? FileAttributeType == .typeRegular)
    #expect(try String(contentsOf: llama.appending(path: "libfake.0.dylib"), encoding: .utf8) == "library")
    #expect(FileManager.default.isExecutableFile(atPath: llama.appending(path: "llama-server").path))
    #expect(try Data(contentsOf: llama.appending(path: "runtime.json")) == Data(contentsOf: manifest))
    let licenses = contents.appending(path: "Resources/Licenses/llama.cpp")
    #expect(try FileManager.default.contentsOfDirectory(atPath: licenses.path) == ["LICENSE"])
    #expect(FileManager.default.fileExists(atPath: contents.appending(path: "Helpers/skillgarden").path))
    // #123: the helper that owns llama-server, and loopback HTTP for the health check.
    #expect(try String(contentsOf: contents.appending(path: "Helpers/SkillgardenAIHost"), encoding: .utf8) == "host")
    #expect(try String(contentsOf: root.appending(path: "build.log"), encoding: .utf8)
        == "build --product SkillgardenApp\nbuild --product skillgarden\nbuild --product SkillgardenAIHost\n")
    let plist = try #require(NSDictionary(contentsOf: contents.appending(path: "Info.plist")))
    #expect((plist["NSAppTransportSecurity"] as? [String: Any])?["NSAllowsLocalNetworking"] as? Bool == true)
}

@Test func bundleScriptStopsWhenTheRuntimeIsMissing() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try bundleRepository(in: root)
    let llama = root.appending(path: "llama")
    try makeLlamaRuntime(at: llama, manifest: root.appending(path: "assets/llama.cpp/runtime.json"), server: try builtCLI())

    // SKILLGARDEN_LLAMA_DIR overrides the default folder. A trailing "/" is ignored.
    let missing = root.appending(path: "nowhere")
    let result = try run(URL(fileURLWithPath: "/bin/zsh"), [script.path], in: root, environment: ["SKILLGARDEN_LLAMA_DIR": missing.path + "/"])
    #expect(result.status == 1)
    #expect(result.output.isEmpty)
    #expect(result.errorText == "error: llama.cpp runtime not found at \(missing.path). Prepare it first (see docs/local-ai.md).\n")
    // The script stops before the build and does not make the app.
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build.log").path))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build/Skillgarden.app").path))

    // The default folder is also missing: HOME has no prepared runtime.
    let home = root.appending(path: "home")
    let noDefault = try run(URL(fileURLWithPath: "/bin/zsh"), [script.path], in: root, environment: ["HOME": home.path])
    #expect(noDefault.status == 1)
    #expect(noDefault.errorText == "error: llama.cpp runtime not found at \(home.path)/.local/share/skillgarden/llama.cpp/b1. Prepare it first (see docs/local-ai.md).\n")

    // A pinned file that is not in the folder.
    try FileManager.default.removeItem(at: llama.appending(path: "libfake.0.dylib"))
    let noLibrary = try run(URL(fileURLWithPath: "/bin/zsh"), [script.path], in: root, environment: ["SKILLGARDEN_LLAMA_DIR": llama.path])
    #expect(noLibrary.status == 1)
    #expect(noLibrary.errorText == "error: libfake.0.dylib: not found in \(llama.path)\n")
}

@Test func bundleScriptStopsWhenAChecksumDoesNotMatch() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try bundleRepository(in: root)
    let llama = root.appending(path: "llama")
    try makeLlamaRuntime(at: llama, manifest: root.appending(path: "assets/llama.cpp/runtime.json"), server: try builtCLI())

    for name in ["libfake.0.1.0.dylib", "LICENSE"] {
        let file = llama.appending(path: name)
        let original = try Data(contentsOf: file)
        try Data("changed".utf8).write(to: file)
        let result = try run(URL(fileURLWithPath: "/bin/zsh"), [script.path], in: root, environment: ["SKILLGARDEN_LLAMA_DIR": llama.path])
        let pinned = name == "LICENSE" ? "LICENSE" : "libfake.0.dylib"
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(result.errorText == "error: \(pinned): checksum does not match runtime.json\n")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build.log").path))
        try original.write(to: file)
    }
}

// MARK: - Check script

/// Makes `<root>/Skillgarden.app` with a runtime of system-only Mach-O files and a matching runtime.json.
private func checkedApp(in root: URL, minimumSystemVersion: String = "15.0") throws -> URL {
    let app = root.appending(path: "Skillgarden.app")
    let llama = app.appending(path: "Contents/Helpers/llama")
    let licenses = app.appending(path: "Contents/Resources/Licenses/llama.cpp")
    for folder in [llama, licenses] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let plist: [String: Any] = ["CFBundleExecutable": "Skillgarden", "LSMinimumSystemVersion": minimumSystemVersion]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
    let server = llama.appending(path: "llama-server")
    try FileManager.default.copyItem(at: try builtCLI(), to: server)
    // A debug build has an rpath into the Xcode toolchain. A release runtime has none.
    let commands = try run(URL(fileURLWithPath: "/usr/bin/otool"), ["-l", server.path], in: root).output
    let rpaths = commands.components(separatedBy: "cmd LC_RPATH").dropFirst().compactMap { command in
        command.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("path ") }?
            .split(separator: " ").dropFirst().first.map(String.init)
    }
    for rpath in rpaths where !rpath.hasPrefix("/usr/lib/") && !rpath.hasPrefix("@") {
        try tool("/usr/bin/install_name_tool", ["-delete_rpath", rpath, server.path])
    }
    try tool("/usr/bin/codesign", ["--force", "--sign", "-", server.path])
    try Data("MIT License".utf8).write(to: licenses.appending(path: "LICENSE"))
    try writeManifest(["llama-server": llama.appending(path: "llama-server"), "LICENSE": licenses.appending(path: "LICENSE")],
                      to: llama.appending(path: "runtime.json"))
    return app
}

private func check(_ app: URL) throws -> Run {
    // Homebrew on PATH must not change the result: the script sets its own PATH.
    try run(URL(fileURLWithPath: "/bin/zsh"), [repo.appending(path: "scripts/check_llama_runtime.sh").path, app.path],
            in: app.deletingLastPathComponent(), environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
}

private let allPass = "PASS arm64\nPASS deployment target 15.0\nPASS library paths\nPASS checksums\n"

@Test func checkScriptPassesASystemOnlyRuntime() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try check(try checkedApp(in: root))
    #expect(result.status == 0, "\(result.output)\(result.errorText)")
    #expect(result.output == allPass)
}

@Test func checkScriptFailsAnotherArchitecture() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try checkedApp(in: root)
    try tool("/usr/bin/lipo", ["/bin/ls", "-thin", "x86_64", "-output", app.appending(path: "Contents/Helpers/llama/libintel.dylib").path])
    let result = try check(app)
    #expect(result.status == 1)
    #expect(result.output.hasPrefix("FAIL arm64: libintel.dylib has architectures: x86_64\n"))
}

@Test func checkScriptFailsANewerDeploymentTarget() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    // The release needs macOS 13.3, so an app minimum of 13.0 is too low.
    let low = try check(try checkedApp(in: root.appending(path: "low"), minimumSystemVersion: "13.0"))
    #expect(low.status == 1)
    #expect(low.output.contains("FAIL deployment target 13.0: llama-server needs macOS 15.0\n"))

    let app = try checkedApp(in: root.appending(path: "new"))
    let server = app.appending(path: "Contents/Helpers/llama/llama-server")
    let newer = root.appending(path: "llama-server")
    try tool("/usr/bin/vtool", ["-set-build-version", "macos", "26.0", "26.0", "-replace", "-output", newer.path, server.path])
    try FileManager.default.removeItem(at: server)
    try FileManager.default.moveItem(at: newer, to: server)
    let result = try check(app)
    #expect(result.status == 1)
    #expect(result.output.contains("PASS arm64\nFAIL deployment target 15.0: llama-server needs macOS 26.0\n"))
}

@Test func checkScriptFailsLibraryPathsOutsideTheApp() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try checkedApp(in: root)
    let server = app.appending(path: "Contents/Helpers/llama/llama-server")
    try tool("/usr/bin/install_name_tool", ["-add_rpath", "/opt/homebrew/lib", server.path])
    let result = try check(app)
    #expect(result.status == 1)
    #expect(result.output.contains("FAIL library paths: llama-server has rpath /opt/homebrew/lib\n"))
    // install_name_tool changed the file after runtime.json pinned it.
    #expect(result.output.hasSuffix("FAIL checksums: llama-server does not match runtime.json\n"))
}

@Test func checkScriptFailsAMissingLicense() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try checkedApp(in: root)
    try FileManager.default.removeItem(at: app.appending(path: "Contents/Resources/Licenses/llama.cpp/LICENSE"))
    let result = try check(app)
    #expect(result.status == 1)
    #expect(result.output == "PASS arm64\nPASS deployment target 15.0\nPASS library paths\nFAIL checksums: LICENSE not found\n")

    let empty = root.appending(path: "Empty.app")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let none = try check(empty)
    #expect(none.status == 1)
    #expect(none.errorText == "error: no llama.cpp runtime at \(empty.path)/Contents/Helpers/llama\n")
}

// MARK: - Pinned manifest

@Test func pinnedManifestNamesTheReleaseAndItsFiles() throws {
    let data = try Data(contentsOf: repo.appending(path: "assets/llama.cpp/runtime.json"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["name"] as? String == "llama.cpp")
    #expect(json["version"] as? String == "b11669")
    #expect(json["architecture"] as? String == "arm64")
    #expect(json["minimumSystemVersion"] as? String == "13.3")
    let sha = try #require(json["sha256"] as? [String: String])
    for name in ["llama-server", "libllama-server-impl.dylib", "libllama.0.dylib", "libggml-metal.0.dylib", "LICENSE"] {
        #expect(sha[name]?.count == 64, "\(name)")
    }
    // Only llama-server and libraries: no other release tool.
    #expect(sha.keys.allSatisfy { $0 == "llama-server" || $0 == "LICENSE" || $0.hasSuffix(".dylib") })

    let doc = try String(contentsOf: repo.appending(path: "docs/local-ai.md"), encoding: .utf8)
    for text in ["b11669", "## Pinned runtime", "## Framework exception", "## Bundle layout", "## Licenses"] {
        #expect(doc.contains(text), "\(text)")
    }
}

/// On a Mac with the prepared release, the real files match the pins and pass every check.
@Test(.enabled(if: FileManager.default.fileExists(atPath: preparedRuntime.appending(path: "llama-server").path)))
func preparedReleasePassesTheChecks() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try checkedApp(in: root)
    let llama = app.appending(path: "Contents/Helpers/llama")
    let manifest = repo.appending(path: "assets/llama.cpp/runtime.json")
    try FileManager.default.removeItem(at: llama.appending(path: "llama-server"))
    try FileManager.default.removeItem(at: llama.appending(path: "runtime.json"))
    try FileManager.default.removeItem(at: app.appending(path: "Contents/Resources/Licenses/llama.cpp/LICENSE"))
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    for name in try #require((json["sha256"] as? [String: String])?.keys) {
        let target = name == "LICENSE" ? app.appending(path: "Contents/Resources/Licenses/llama.cpp/LICENSE") : llama.appending(path: name)
        try FileManager.default.copyItem(at: preparedRuntime.appending(path: name).resolvingSymlinksInPath(), to: target)
    }
    try FileManager.default.copyItem(at: manifest, to: llama.appending(path: "runtime.json"))
    let result = try check(app)
    #expect(result.status == 0, "\(result.output)\(result.errorText)")
    #expect(result.output == allPass)

    // Without one of its libraries, llama-server cannot load.
    try FileManager.default.removeItem(at: llama.appending(path: "libggml-rpc.0.dylib"))
    let missing = try check(app)
    #expect(missing.status == 1)
    #expect(missing.output.contains("FAIL library paths: libggml.0.dylib needs @rpath/libggml-rpc.0.dylib, not in Contents/Helpers/llama\n"))
}
