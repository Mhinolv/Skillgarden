import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private struct NoLibrary: Error {}

/// `media inspect` does not open the library, so the root setting throws if a command reads it.
private func run(_ arguments: [String]) -> CommandResult {
    SkillgardenCommand.run(arguments: arguments, root: try { throw NoLibrary() }())
}

/// Gives each test a temporary folder.
private func withFolder(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SkillgardenMediaInspect-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try body(folder.standardizedFileURL)
}

/// An MP4 file with an `ftyp` box and a version 0 `moov/mvhd` box.
private func mp4(timescale: UInt32, duration: UInt32) -> Data {
    func box(_ type: String, _ body: Data) -> Data { bytes(UInt32(8 + body.count)) + Data(type.utf8) + body }
    func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    let mvhd = Data(count: 12) + bytes(timescale) + bytes(duration) + Data(count: 80)
    return box("ftyp", Data("isom".utf8) + bytes(UInt32(512))) + box("moov", box("mvhd", mvhd))
}

private func jsonObject(_ result: CommandResult) throws -> [String: Any] {
    #expect(result.stderr == "")
    return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
}

@Test func mediaInspectShowsTheFixtureLengthAndTheManifestLine() {
    let file = fixture.appending(path: "content/welcome.mp4").standardizedFileURL
    #expect(run(["media", "inspect", file.path]) == CommandResult(exitCode: 0, stdout: """
        File: \(file.path)
        Format: MP4
        Duration: 0:04 (4 seconds)
        Manifest: duration_seconds: 4
        Validate accepts: 2 to 6

        """, stderr: ""))
    #expect(LectureVideo.length(of: file) == 4)
}

/// Validate accepts each value of the printed range and rejects the values next to it.
@Test func mediaInspectRangeMatchesValidate() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenMediaInspectValidate-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    let manifest = folder.appending(path: "skillgarden.yaml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    #expect(original.contains("duration_seconds: 4"))

    let object = try jsonObject(run(["media", "inspect", folder.appending(path: "content/welcome.mp4").path, "--json"]))
    let result = try #require(object["result"] as? [String: Any])
    let low = try #require(result["accepted_min"] as? Int), high = try #require(result["accepted_max"] as? Int)
    for value in [low - 1, low, try #require(result["duration_seconds"] as? Int), high, high + 1] {
        try original.replacingOccurrences(of: "duration_seconds: 4", with: "duration_seconds: \(value)")
            .write(to: manifest, atomically: true, encoding: .utf8)
        #expect(SkillgardenCommand.run(arguments: ["validate", folder.path]).exitCode == (value < low || value > high ? 1 : 0))
    }
}

@Test func mediaInspectFormatsShortAndLongVideos() throws {
    try withFolder { folder in
        let cases: [(UInt32, UInt32, String)] = [
            (1000, 400, "Duration: 0:00 (0 seconds)\nManifest: duration_seconds: 0\nValidate accepts: 0 to 2\n"),
            (600, 600, "Duration: 0:01 (1 second)\nManifest: duration_seconds: 1\nValidate accepts: 0 to 3\n"),
            (1000, 92_400, "Duration: 1:32 (92 seconds)\nManifest: duration_seconds: 92\nValidate accepts: 90 to 94\n"),
            (600, 600 * 3599, "Duration: 59:59 (3599 seconds)\nManifest: duration_seconds: 3599\nValidate accepts: 3597 to 3601\n"),
            (90_000, 90_000 * 3725, "Duration: 1:02:05 (3725 seconds)\nManifest: duration_seconds: 3725\nValidate accepts: 3723 to 3727\n"),
        ]
        for (timescale, duration, expected) in cases {
            let file = folder.appending(path: "\(UUID()).mp4")
            try mp4(timescale: timescale, duration: duration).write(to: file)
            #expect(run(["media", "inspect", file.path]).stdout == "File: \(file.path)\nFormat: MP4\n" + expected)
        }
    }
}

@Test func mediaInspectPrintsTheStandardizedAbsolutePath() throws {
    try withFolder { folder in
        let file = folder.appending(path: "clip.mp4")
        try mp4(timescale: 600, duration: 2400).write(to: file)
        let result = run(["media", "inspect", folder.path + "/sub/.././/clip.mp4"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("File: \(file.path)\n"))
    }
}

@Test func mediaInspectFailsForAMissingFileOrAFolder() throws {
    try withFolder { folder in
        let missing = folder.appending(path: "missing.mp4")
        #expect(run(["media", "inspect", missing.path])
            == CommandResult(exitCode: 3, stdout: "", stderr: "error: file does not exist: \(missing.path)\n"))
        #expect(run(["media", "inspect", folder.path])
            == CommandResult(exitCode: 3, stdout: "", stderr: "error: file does not exist: \(folder.path)\n"))
    }
}

@Test func mediaInspectFailsForAFileThatIsNotMP4() throws {
    try withFolder { folder in
        let pdf = fixture.appending(path: "content/worksheet.pdf").standardizedFileURL
        let empty = folder.appending(path: "empty.mp4")
        try Data().write(to: empty)
        for file in [pdf, empty] {
            #expect(run(["media", "inspect", file.path]) == CommandResult(exitCode: 1, stdout: "", stderr: """
                error: \(file.path): file is not an MP4 video
                hint: Skillgarden plays MP4 video only.

                """))
        }
    }
}

@Test func mediaInspectFailsForAnMP4WithNoReadableLength() throws {
    try withFolder { folder in
        for (name, data) in [("zero.mp4", mp4(timescale: 600, duration: 0)), ("cut.mp4", mp4(timescale: 600, duration: 2400).prefix(40)),
                             ("no-timescale.mp4", mp4(timescale: 0, duration: 10))] {
            let file = folder.appending(path: name)
            try data.write(to: file)
            #expect(run(["media", "inspect", file.path])
                == CommandResult(exitCode: 1, stdout: "", stderr: "error: \(file.path): cannot read the video length\n"))
        }
    }
}

@Test func mediaInspectRejectsBadArguments() {
    let usage = SkillgardenCommand.run(arguments: ["--help"]).stdout
    #expect(usage.contains("       skillgarden media inspect <file> [--json]\n"))
    #expect(run(["media", "--help"]) == CommandResult(exitCode: 0, stdout: usage, stderr: ""))
    #expect(run(["media", "inspect", "--help"]) == CommandResult(exitCode: 0, stdout: usage, stderr: ""))
    let file = fixture.appending(path: "content/welcome.mp4").path
    for arguments in [["media"], ["media", "inspect"], ["media", "inspect", file, file], ["media", "probe", file],
                      ["media", "inspect", "--all"], ["media", "inspect", ""], ["media", file]] {
        #expect(run(arguments) == CommandResult(exitCode: 2, stdout: "", stderr: "error: expected media inspect <file>\n" + usage))
    }
}

@Test func mediaInspectJSONReportsTheLengthAndTheErrorCodes() throws {
    try withFolder { folder in
        let video = fixture.appending(path: "content/welcome.mp4").standardizedFileURL
        let object = try jsonObject(run(["media", "inspect", "--json", video.path]))
        #expect(object["command"] as? String == "media inspect")
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        #expect(Set(result.keys) == ["path", "format", "duration_seconds", "accepted_min", "accepted_max"])
        #expect(result["path"] as? String == video.path)
        #expect(result["format"] as? String == "mp4")
        #expect(result["duration_seconds"] as? Int == 4)
        #expect(result["accepted_min"] as? Int == 2)
        #expect(result["accepted_max"] as? Int == 6)

        let noLength = folder.appending(path: "zero.mp4")
        try mp4(timescale: 600, duration: 0).write(to: noLength)
        let pdf = fixture.appending(path: "content/worksheet.pdf").standardizedFileURL
        let missing = folder.appending(path: "missing.mp4")
        let failures: [(URL, Int, String, String?)] = [(missing, 3, "file_not_found", nil), (pdf, 1, "not_mp4", "Skillgarden plays MP4 video only."),
                                                        (noLength, 1, "no_video_length", nil)]
        for (file, exitCode, code, hint) in failures {
            let failure = try jsonObject(run(["media", "inspect", file.path, "--json"]))
            #expect(failure["exit_code"] as? Int == exitCode)
            #expect(failure["result"] is NSNull)
            let diagnostics = try #require(failure["diagnostics"] as? [[String: Any]])
            #expect(diagnostics.count == 1)
            #expect(diagnostics.first?["code"] as? String == code)
            #expect(diagnostics.first?["file"] as? String == file.path)
            #expect(diagnostics.first?["hint"] as? String == hint)
        }
        let usage = try jsonObject(run(["media", "inspect", "--json"]))
        #expect(usage["command"] as? String == "media inspect")
        #expect((usage["diagnostics"] as? [[String: Any]])?.first?["code"] as? String == "usage")
    }
}
