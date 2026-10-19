import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course, a library root that does not exist yet and their base folder.
private func withCourse(_ body: (URL, URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenInspectTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try body(folder, base.appending(path: "library"), base)
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
}

/// Every file and folder below `folder`, with the contents of each file, so a test can show that nothing changed.
private func tree(_ folder: URL) throws -> [String: Data?] {
    var result: [String: Data?] = [:]
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        let isFile = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        result.updateValue(isFile ? try Data(contentsOf: url) : nil, forKey: url.path)
    }
    return result
}

/// The size text of the course files, internal files included.
private func size(_ folder: URL) throws -> String {
    let bytes = try tree(folder).values.compactMap { $0 }.reduce(0) { $0 + $1.count }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private func publish(_ folder: URL, _ root: URL) -> CommandResult {
    SkillgardenCommand.run(arguments: ["publish", folder.path], root: root)
}

private func snapshot(_ root: URL) throws -> URL {
    try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
}

private func runJSON(_ arguments: [String], root: URL) throws -> [String: Any] {
    let result = SkillgardenCommand.run(arguments: arguments + ["--json"], root: root)
    #expect(result.stderr.isEmpty)
    return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
}

private let usage = SkillgardenCommand.usage + SkillgardenCommand.usageMore

@Test func publishReceiptShowsTheFilesAndTheNewSnapshot() throws {
    try withCourse { folder, root, _ in
        let result = publish(folder, root)
        let id = try snapshot(root).lastPathComponent, bytes = try size(folder)
        #expect(result == CommandResult(exitCode: 0, stdout: """
            Published "Local Course Basics" (sample-course, published): created 7, updated 0, unchanged 0, removed 0
            Files: added 13, changed 0, unchanged 0, removed 0
            Snapshot: new \(id), 13 files, \(bytes)
            Library: \(root.path)

            """, stderr: ""))
    }
}

@Test func articleOnlyEditChangesTheReceiptFileSummary() throws {
    try withCourse { folder, root, _ in
        #expect(publish(folder, root).exitCode == 0)
        let first = try snapshot(root).lastPathComponent
        try Data("# A new plan\n".utf8).write(to: folder.appending(path: "content/plan.md"))
        let result = publish(folder, root)
        let second = try snapshot(root).lastPathComponent
        #expect(second != first)
        let bytes = try size(folder)
        // The manifest records do not change, but the receipt shows the changed file and the new snapshot.
        #expect(result == CommandResult(exitCode: 0, stdout: """
            Published "Local Course Basics" (sample-course, published): created 0, updated 0, unchanged 7, removed 0
            Files: added 0, changed 1, unchanged 12, removed 0
            Snapshot: new \(second), 13 files, \(bytes)
            Library: \(root.path)

            """, stderr: ""))
        // With no change, publish keeps the snapshot.
        #expect(publish(folder, root).stdout == """
            Published "Local Course Basics" (sample-course, published): created 0, updated 0, unchanged 7, removed 0
            Files: added 0, changed 0, unchanged 13, removed 0
            Snapshot: kept \(second)
            Library: \(root.path)

            """)
        #expect(try snapshot(root).lastPathComponent == second)
    }
}

@Test func publishJSONHasTheFilesAndTheSnapshotID() throws {
    try withCourse { folder, root, _ in
        let published = try runJSON(["publish", folder.path], root: root)
        let result = try #require(published["result"] as? [String: Any])
        let files = try #require(result["files"] as? [String: Int])
        #expect(files == ["added": 13, "changed": 0, "unchanged": 0, "removed": 0])
        let snapshotObject = try #require(result["snapshot"] as? [String: Any])
        #expect(snapshotObject["state"] as? String == "new")
        let id = try snapshot(root).lastPathComponent
        #expect(snapshotObject["id"] as? String == id)
        #expect(snapshotObject["files"] as? Int == 13)
        let kept = try #require(try runJSON(["publish", folder.path], root: root)["result"] as? [String: Any])
        let keptSnapshot = try #require(kept["snapshot"] as? [String: Any])
        #expect(keptSnapshot["state"] as? String == "kept")
        #expect(keptSnapshot["id"] as? String == id)
    }
}

@Test func inspectShowsAnInstalledCourseAndWritesNothing() throws {
    try withCourse { folder, root, _ in
        #expect(publish(folder, root).exitCode == 0)
        let installed = try snapshot(root)
        let before = try tree(root)
        // The sample course has a draft section with 2 lectures.
        #expect(SkillgardenCommand.run(arguments: ["inspect", "sample-course"], root: root) == CommandResult(exitCode: 0, stdout: """
            Course "Local Course Basics" (sample-course, published)
            Learners: can see this course. 2 of 4 lectures in 1 of 2 sections are visible (2 draft).
            Snapshot: \(installed.lastPathComponent)
            Snapshot path: \(root.appending(path: "courses/\(installed.lastPathComponent)").path)
            Internal files: 2
            Library: \(root.path)

            """, stderr: ""))
        #expect(try tree(root) == before)
        // The visible counts agree with the learner read of the store.
        let course = try #require(try CourseStore(root: root).loadCourse(id: "sample-course"))
        let inspection = try #require(try CoursePublisher.inspect(courseID: "sample-course", root: root))
        #expect(inspection.visibleSections == course.sections.count)
        #expect(inspection.visibleLectures == course.sections.reduce(0) { $0 + $1.lectures.count })
    }
}

@Test func inspectOfAnAllVisibleCourseHasNoDraftCount() throws {
    try withCourse { folder, root, _ in
        try edit(folder, "    state: draft\n", "    state: published\n")
        #expect(publish(folder, root).exitCode == 0)
        let lines = SkillgardenCommand.run(arguments: ["inspect", "sample-course"], root: root).stdout.split(separator: "\n")
        #expect(lines[1] == "Learners: can see this course. 4 of 4 lectures in 2 of 2 sections are visible.")
    }
}

@Test func inspectOfADraftCourseSaysThatLearnersCannotSeeIt() throws {
    try withCourse { folder, root, _ in
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        #expect(publish(folder, root).exitCode == 0)
        let result = SkillgardenCommand.run(arguments: ["inspect", "sample-course"], root: root)
        #expect(result.exitCode == 0)
        #expect(result.stdout.split(separator: "\n").prefix(2) == [
            "Course \"Local Course Basics\" (sample-course, draft)",
            "Learners: cannot see this course because its state is draft. Set state: published and publish again.",
        ])
        let json = try #require(try runJSON(["inspect", "sample-course"], root: root)["result"] as? [String: Any])
        #expect(json["draft"] as? Bool == true)
        #expect(json["visible"] as? Bool == false)
        #expect(json["visible_lectures"] as? Int == 0)
        #expect(json["lectures"] as? Int == 4)
    }
}

@Test func inspectOfAMissingCourseExitsOne() throws {
    try withCourse { folder, root, base in
        let missing = CommandResult(exitCode: 1, stdout: "", stderr: """
            error: course "other" not found
            hint: Check the id, or check SKILLGARDEN_DATA_DIR.
            Library: \(root.path)

            """)
        // A library that does not exist is not created.
        let before = try tree(base)
        #expect(SkillgardenCommand.run(arguments: ["inspect", "other"], root: root) == missing)
        #expect(try tree(base) == before)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(publish(folder, root).exitCode == 0)
        #expect(SkillgardenCommand.run(arguments: ["inspect", "other"], root: root) == missing)
        let json = try runJSON(["inspect", "other"], root: root)
        #expect(json["exit_code"] as? Int == 1)
        let diagnostics = try #require(json["diagnostics"] as? [[String: Any]])
        #expect(diagnostics.first?["code"] as? String == "course.not_found")
    }
}

@Test func inspectWithAMissingIDOrAnExtraArgumentExitsTwo() throws {
    try withCourse { _, root, _ in
        let error = CommandResult(exitCode: 2, stdout: "", stderr: "error: expected inspect <course-id>\n" + usage)
        #expect(SkillgardenCommand.run(arguments: ["inspect"], root: root) == error)
        #expect(SkillgardenCommand.run(arguments: ["inspect", "a", "b"], root: root) == error)
        #expect(SkillgardenCommand.run(arguments: ["inspect", "--all"], root: root) == error)
        #expect(usage.contains("skillgarden inspect <course-id> [--json]\n"))
        #expect(SkillgardenCommand.run(arguments: ["inspect", "--help"], root: root).stdout == SkillgardenCommand.help)
    }
}
