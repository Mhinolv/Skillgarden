import Foundation
import Testing
@testable import SkillgardenCore

/// Gives each test a temporary base folder. `default` stands in for Application Support and does not exist.
private func withBase(_ body: (URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenDoctorTests-\(UUID())")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appending(path: "locked").path)
        try? FileManager.default.removeItem(at: base)
    }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try body(base)
}

private func doctor(_ base: URL, variable: String? = nil, saved: String? = nil, sandbox: Bool = false) -> Doctor {
    var environment = variable.map { ["SKILLGARDEN_DATA_DIR": $0] } ?? [:]
    if sandbox { environment["APP_SANDBOX_CONTAINER_ID"] = "dev.example.agent" }
    return Doctor(environment: environment, savedSetting: saved, home: base.appending(path: "home"),
                  defaultDirectory: base.appending(path: "default"), cliPath: "/usr/local/bin/skillgarden")
}

private func run(_ doctor: Doctor, _ arguments: [String] = ["doctor"]) -> CommandResult {
    SkillgardenCommand.run(arguments: arguments, root: URL(fileURLWithPath: "/unused"), doctor: doctor)
}

@Test func doctorPrefersTheEnvironmentAndShowsTheAppMismatch() throws {
    try withBase { base in
        let env = base.appending(path: "env library")
        let saved = base.appending(path: "saved")
        try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
        #expect(run(doctor(base, variable: env.path, saved: saved.path, sandbox: true)) == CommandResult(exitCode: 0, stdout: """
            skillgarden \(Skillgarden.version)
            CLI:            /usr/local/bin/skillgarden
            Library:        \(env.path)
            Source:         SKILLGARDEN_DATA_DIR (environment)
            Folder:         exists
            Write access:   likely (estimate)
            App library:    \(saved.path)
            App source:     DataDirectory (saved setting)
            Match:          no
            Sandbox:        yes (APP_SANDBOX_CONTAINER_ID is set)
            Note: The app does not read shell variables. Run: defaults write dev.skillgarden.app DataDirectory "\(env.path)"

            """, stderr: ""))
        // Without the variable, the saved setting wins for both, and the paths match.
        let report = doctor(base, saved: saved.path)
        #expect(report.library.source == .savedSetting)
        #expect(report.library.url?.path == saved.path)
        #expect(report.match == true)
        #expect(report.text.contains("Match:          yes\nSandbox:        no\n"))
        #expect(!report.text.contains("Note:"))
        // An empty variable is skipped. A leading ~ expands to the home folder.
        #expect(doctor(base, variable: " ", saved: saved.path).library.source == .savedSetting)
        #expect(doctor(base, variable: "~/lib").library.url?.path == base.path + "/home/lib")
        // The same path in both settings matches.
        #expect(doctor(base, variable: saved.path + "/", saved: saved.path).match == true)
    }
}

@Test func doctorReportsAMissingDefaultFolderAndWritesNothing() throws {
    try withBase { base in
        let report = doctor(base)
        #expect(report.library.source == .applicationSupport)
        #expect(report.folder == .missing)
        #expect(report.writeAccess == .likely)
        #expect(report.match == true)
        #expect(run(report) == CommandResult(exitCode: 0, stdout: """
            skillgarden \(Skillgarden.version)
            CLI:            /usr/local/bin/skillgarden
            Library:        \(base.path)/default
            Source:         Application Support (default)
            Folder:         missing (publish creates it)
            Write access:   likely (estimate)
            App library:    \(base.path)/default
            App source:     Application Support (default)
            Match:          yes
            Sandbox:        no

            """, stderr: ""))
        // A missing folder below a missing parent uses the nearest parent that exists.
        #expect(doctor(base, variable: base.path + "/a/b/c").writeAccess == .likely)
        let written = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(written.isEmpty)
    }
}

@Test func doctorEstimatesNoWriteAccessForAReadOnlyFolder() throws {
    try withBase { base in
        let locked = base.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        #expect(doctor(base, variable: locked.path).writeAccess == .no)
        #expect(doctor(base, variable: locked.path + "/library").writeAccess == .no)
        #expect(run(doctor(base, variable: locked.path)).stdout.contains("Write access:   no\n"))
    }
}

@Test func doctorFailsForARelativeSetting() throws {
    try withBase { base in
        #expect(run(doctor(base, variable: "library")) == CommandResult(exitCode: 2, stdout: """
            skillgarden \(Skillgarden.version)
            CLI:            /usr/local/bin/skillgarden
            Library:        invalid
            Source:         SKILLGARDEN_DATA_DIR (environment)
            App library:    \(base.path)/default
            App source:     Application Support (default)
            Sandbox:        no

            """, stderr: "error: SKILLGARDEN_DATA_DIR must be an absolute path\n"))
        let saved = run(doctor(base, saved: "library"))
        #expect(saved.exitCode == 2)
        #expect(saved.stdout.contains("Library:        invalid\nSource:         DataDirectory (saved setting)\n"))
        #expect(saved.stdout.contains("App library:    invalid\n"))
        #expect(saved.stderr == "error: DataDirectory must be an absolute path\n")
        // The app ignores the variable, so a relative saved setting is an error also when the variable is good.
        let shadowed = run(doctor(base, variable: base.path, saved: "library"))
        #expect(shadowed.exitCode == 2)
        #expect(shadowed.stdout.contains("Library:        \(base.path)\n"))
        #expect(!shadowed.stdout.contains("Match:"))
        #expect(shadowed.stderr == "error: DataDirectory must be an absolute path\n")
    }
}

@Test func doctorExitsThreeWhenTheLibraryIsAFile() throws {
    try withBase { base in
        let file = base.appending(path: "library")
        try Data("x".utf8).write(to: file)
        let result = run(doctor(base, variable: file.path))
        #expect(result.exitCode == 3)
        #expect(result.stdout.contains("Folder:         not a folder\nWrite access:   no\n"))
        #expect(result.stderr == "error: library path is not a folder: \(file.path)\n")
        // A file in place of a parent folder blocks the publish too.
        #expect(doctor(base, variable: file.path + "/sub").writeAccess == .no)
    }
}

@Test func doctorJSONHoldsTheReportFields() throws {
    try withBase { base in
        let env = base.appending(path: "env")
        let result = run(doctor(base, variable: env.path, sandbox: true), ["doctor", "--json"])
        #expect(result.exitCode == 0)
        #expect(result.stderr == "")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["command"] as? String == "doctor")
        let fields = try #require(object["result"] as? [String: Any])
        #expect(Set(fields.keys) == ["version", "cli_path", "library_path", "source", "folder", "write_access",
                                     "app_library_path", "app_source", "match", "sandbox"])
        #expect(fields["version"] as? String == Skillgarden.version)
        #expect(fields["library_path"] as? String == env.path)
        #expect(fields["source"] as? String == "environment")
        #expect(fields["folder"] as? String == "missing")
        #expect(fields["write_access"] as? String == "likely")
        #expect(fields["app_library_path"] as? String == base.path + "/default")
        #expect(fields["app_source"] as? String == "default")
        #expect(fields["match"] as? Bool == false)
        #expect(fields["sandbox"] as? Bool == true)

        let bad = run(doctor(base, variable: "library"), ["doctor", "--json"])
        #expect(bad.exitCode == 2)
        let badObject = try #require(try JSONSerialization.jsonObject(with: Data(bad.stdout.utf8)) as? [String: Any])
        let badFields = try #require(badObject["result"] as? [String: Any])
        #expect(badFields["library_path"] is NSNull)
        #expect(badFields["match"] is NSNull)
        let diagnostics = try #require(badObject["diagnostics"] as? [[String: Any]])
        #expect(diagnostics.map { $0["code"] as? String } == ["data_dir.relative"])

        let file = base.appending(path: "file")
        try Data().write(to: file)
        let notFolder = run(doctor(base, variable: file.path), ["doctor", "--json"])
        let notFolderObject = try #require(try JSONSerialization.jsonObject(with: Data(notFolder.stdout.utf8)) as? [String: Any])
        #expect((notFolderObject["diagnostics"] as? [[String: Any]])?.first?["code"] as? String == "data_dir.not_folder")
        #expect((notFolderObject["result"] as? [String: Any])?["folder"] as? String == "not_a_folder")
    }
}

@Test func doctorUsage() throws {
    try withBase { base in
        let usage = run(doctor(base), ["--help"]).stdout
        #expect(usage.hasSuffix("       skillgarden internal list <course-id> [--json]\n       skillgarden inspect <course-id> [--json]\n       skillgarden init <folder> --id <id> --title <title> [--json]\n       skillgarden doctor [--json]\n       skillgarden schema [--output <file>]\n"))
        #expect(run(doctor(base), ["doctor", "--help"]) == CommandResult(exitCode: 0, stdout: usage, stderr: ""))
        for arguments in [["doctor", "extra"], ["doctor", "--bogus"]] {
            #expect(run(doctor(base), arguments) == CommandResult(exitCode: 2, stdout: "", stderr: "error: expected doctor\n" + usage))
        }
    }
}

@Test func doctorCurrentReadsTheRunningProcess() {
    let report = Doctor.current()
    #expect(report.version == Skillgarden.version)
    #expect(report.cliPath?.hasPrefix("/") == true)
}
