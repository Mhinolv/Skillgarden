import Foundation
import Testing

// #212: scripts/release_app.sh signs, notarizes and staples the app for direct distribution.
// The tests use --dry-run and the setup errors, so they need no certificate, no profile and no network.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ReleaseScriptTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private struct Run {
    var status: Int32
    var output: String
    var errorText: String
}

private func run(_ arguments: [String], in folder: URL, environment: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PWD": folder.path].merging(environment) { $1 }
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Run(status: process.terminationStatus, output: output, errorText: errorText)
}

/// A repository copy with release_app.sh, a stub build.sh that logs its calls and a runtime.json with two pinned binaries.
private func releaseRepository(in root: URL) throws -> URL {
    let scripts = root.appending(path: "scripts")
    let assets = root.appending(path: "assets/llama.cpp")
    for folder in [scripts, assets] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try FileManager.default.copyItem(at: repo.appending(path: "scripts/release_app.sh"), to: scripts.appending(path: "release_app.sh"))
    let stub = scripts.appending(path: "build.sh")
    try "#!/bin/sh\necho \"build $*\" >> build.log\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    let manifest: [String: Any] = ["name": "llama.cpp", "version": "b1", "architecture": "arm64", "minimumSystemVersion": "13.3",
                                   "sha256": ["llama-server": String(repeating: "a", count: 64), "libfake.0.dylib": String(repeating: "b", count: 64),
                                              "LICENSE": String(repeating: "c", count: 64)]]
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: assets.appending(path: "runtime.json"))
    return scripts.appending(path: "release_app.sh")
}

private let identity = "Developer ID Application: Test Person (ABCDE12345)"
private let credentials = ["SKILLGARDEN_SIGN_IDENTITY": identity, "SKILLGARDEN_NOTARY_PROFILE": "test-profile"]
private let identitySetup = "  export SKILLGARDEN_SIGN_IDENTITY=\"Developer ID Application: <Name> (<TEAMID>)\"\n"
private let profileSetup = "  export SKILLGARDEN_NOTARY_PROFILE=skillgarden-notary\n"

@Test func releaseDryRunPrintsEveryStepAndRunsNothing() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try releaseRepository(in: root)
    let result = try run([script.path, "--dry-run"], in: root, environment: credentials)
    #expect(result.status == 0, "\(result.errorText)")
    #expect(result.errorText.isEmpty)
    let sign = "+ codesign --force --sign 'Developer ID Application: Test Person (ABCDE12345)' --options runtime --timestamp "
    #expect(result.output == """
        [1/6] Build release bundle
        + rm -rf build/release
        + ./scripts/build.sh app release
        + zsh scripts/check_llama_runtime.sh build/Skillgarden.app
        [2/6] Sign nested code
        \(sign)build/Skillgarden.app/Contents/Helpers/llama/libfake.0.dylib
        \(sign)build/Skillgarden.app/Contents/Helpers/llama/llama-server
        \(sign)build/Skillgarden.app/Contents/Helpers/SkillgardenAIHost
        \(sign)build/Skillgarden.app/Contents/Helpers/skillgarden
        [3/6] Sign app (hardened runtime)
        \(sign)build/Skillgarden.app
        [4/6] Notarize
        + mkdir -p build/release
        + ditto -c -k --keepParent build/Skillgarden.app build/release/Skillgarden-notarize.zip
        + xcrun notarytool submit build/release/Skillgarden-notarize.zip --keychain-profile test-profile --wait --output-format plist
        + rm -f build/release/Skillgarden-notarize.zip
        [5/6] Staple
        + xcrun stapler staple build/Skillgarden.app
        [6/6] Verify
        + codesign --verify --deep --strict --verbose=2 build/Skillgarden.app
        + spctl -a -vv build/Skillgarden.app
        + xcrun stapler validate build/Skillgarden.app
        + zsh scripts/check_llama_runtime.sh --signed build/Skillgarden.app
        + ditto -c -k --keepParent build/Skillgarden.app 'build/release/Skillgarden-<version>.zip'
        Dry run: no command ran.
        Artifact: build/release/Skillgarden-<version>.zip

        """)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build.log").path))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build").path))
}

@Test func releaseDryRunSignsEveryPinnedLibraryBeforeItsExecutables() throws {
    let result = try run([repo.appending(path: "scripts/release_app.sh").path, "--dry-run"], in: repo, environment: credentials)
    #expect(result.status == 0, "\(result.errorText)")
    let lines = result.output.split(separator: "\n").map(String.init)
    let signed = lines.filter { $0.hasPrefix("+ codesign --force") }.map { $0.split(separator: " ").last.map(String.init) ?? "" }
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appending(path: "assets/llama.cpp/runtime.json"))) as? [String: Any])
    let libraries = try #require(json["sha256"] as? [String: String]).keys.filter { $0.hasSuffix(".dylib") }
    #expect(libraries.count == 10)
    #expect(Set(signed.prefix(libraries.count)) == Set(libraries.map { "build/Skillgarden.app/Contents/Helpers/llama/\($0)" }))
    #expect(Array(signed.dropFirst(libraries.count)) == ["build/Skillgarden.app/Contents/Helpers/llama/llama-server",
                                                          "build/Skillgarden.app/Contents/Helpers/SkillgardenAIHost",
                                                          "build/Skillgarden.app/Contents/Helpers/skillgarden", "build/Skillgarden.app"])
    // notarytool gets the Keychain profile only: no Apple ID, password or token on the command line.
    for word in ["--apple-id", "--password", "--key", "--key-id", "--issuer"] {
        #expect(!result.output.split(separator: " ").contains(Substring(word)), "\(word)")
    }
}

@Test func releaseStopsBeforeTheBuildWhenAValueIsMissing() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try releaseRepository(in: root)
    let none = try run([script.path], in: root)
    #expect(none.status == 2)
    #expect(none.output.isEmpty)
    #expect(none.errorText == "error: SKILLGARDEN_SIGN_IDENTITY is not set. Set it (see docs/release.md, \"One-time setup\"):\n" + identitySetup
        + "error: SKILLGARDEN_NOTARY_PROFILE is not set. Set it (see docs/release.md, \"One-time setup\"):\n" + profileSetup)

    // --dry-run needs the two names too. An empty value counts as missing.
    let noProfile = try run([script.path, "--dry-run"], in: root, environment: ["SKILLGARDEN_SIGN_IDENTITY": identity, "SKILLGARDEN_NOTARY_PROFILE": ""])
    #expect(noProfile.status == 2)
    #expect(noProfile.output.isEmpty)
    #expect(noProfile.errorText == "error: SKILLGARDEN_NOTARY_PROFILE is not set. Set it (see docs/release.md, \"One-time setup\"):\n" + profileSetup)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build.log").path))
}

@Test func releaseStopsBeforeTheBuildWithoutTheSigningIdentity() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try releaseRepository(in: root)
    // The test Keychain has no certificate with this name.
    let result = try run([script.path], in: root, environment: credentials)
    #expect(result.status == 2)
    #expect(result.output.isEmpty)
    #expect(result.errorText == "error: no valid signing identity \"\(identity)\" in the Keychain. See docs/release.md, \"Prerequisites\".\n")
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "build.log").path))
}

@Test func releasePrintsUsageForHelpAndUnknownArguments() throws {
    let script = repo.appending(path: "scripts/release_app.sh").path
    let usage = "usage: scripts/release_app.sh [--dry-run]\n"
    let help = try run([script, "--help"], in: FileManager.default.temporaryDirectory)
    #expect(help.status == 0)
    #expect(help.output == usage)
    for arguments in [["--sign"], ["--dry-run", "extra"]] {
        let wrong = try run([script] + arguments, in: FileManager.default.temporaryDirectory, environment: credentials)
        #expect(wrong.status == 2, "\(arguments)")
        #expect(wrong.output.isEmpty)
        #expect(wrong.errorText == usage)
    }
}

@Test func releaseDocumentHasEverySectionAndTheSetupLines() throws {
    let doc = try String(contentsOf: repo.appending(path: "docs/release.md"), encoding: .utf8)
    for text in ["## Prerequisites", "## One-time setup", "## Run", "## Verify", "## Troubleshoot",
                 "xcrun notarytool store-credentials", "scripts/release_app.sh --dry-run", "xcrun notarytool log",
                 identitySetup.trimmingCharacters(in: .whitespacesAndNewlines), profileSetup.trimmingCharacters(in: .whitespacesAndNewlines)] {
        #expect(doc.contains(text), "\(text)")
    }
}
