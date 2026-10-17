import Foundation
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SnapshotTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func snapshotOutputsAreDeterministicForAnOutDirectory() {
    let out = URL(fileURLWithPath: "/tmp/snapshots")
    let outputs = SnapshotPlan.outputs(outDirectory: out)
    #expect(outputs.map(\.url.lastPathComponent) == [
        "library-empty-light.png", "library-empty-dark.png", "library-light.png", "library-dark.png",
        "section-light.png", "section-dark.png", "lecture-light.png", "lecture-dark.png",
    ])
    #expect(outputs.allSatisfy { $0.url.deletingLastPathComponent().path == out.path })
    #expect(outputs == SnapshotPlan.outputs(outDirectory: out))
    #expect(Set(outputs.map(\.url)).count == SnapshotScreen.allCases.count * SnapshotAppearance.allCases.count)
    #expect(SnapshotPlan.width == 1280 && SnapshotPlan.height == 800 && SnapshotPlan.scale == 2)
}

@MainActor @Test func snapshotSeedsEachScreenFromTheFixture() async throws {
    for screen in SnapshotScreen.allCases {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let courseID = try SnapshotPlan.seedStore(for: screen, root: root, fixture: fixture)
        let library = LibraryModel(root: root)
        await library.reload()
        #expect(library.errorMessage == nil)
        switch screen {
        case .libraryEmpty:
            #expect(courseID == nil)
            #expect(library.courses.isEmpty)
        case .library:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(nil)
            #expect(library.selectedCourse?.title == "Local Course Basics")
            #expect(library.selectedCourse?.sections.map(\.id) == ["plan"])
            #expect(library.selectedCourse?.sections.first?.lectures.map(\.id) == ["welcome", "read"])
            #expect(library.destination == nil)
        case .section:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .section(sectionID: "plan"))
            #expect(library.selectedSection?.objective == "Identify the course structure")
            #expect(library.headerImage(forSection: "plan")?.alt == "Two course sections")
        case .lecture:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "welcome")
            #expect(library.nudge?.kind == .recommended)
            #expect(library.nudge?.lecture.id == "read")
        }
    }
}

@Test func snapshotScriptExitsNonZeroWhenTheBuildFails() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appending(path: "scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repo.appending(path: "scripts/snapshot.sh"), to: scripts.appending(path: "snapshot.sh"))
    let stub = scripts.appending(path: "build.sh")
    try "#!/bin/sh\necho 'error: stub build failure'\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [scripts.appending(path: "snapshot.sh").path, root.appending(path: "out").path]
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus != 0)
    #expect(errorText.contains("error: stub build failure"))
    #expect(errorText.contains("snapshot: the app build failed"))
    #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "out").path))
}
