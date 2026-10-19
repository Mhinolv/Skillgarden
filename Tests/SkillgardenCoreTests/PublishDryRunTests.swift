import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course, a library root that does not exist yet and their base folder.
private func withCourse(_ body: (URL, URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenDryRunTests-\(UUID())")
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

private func dryRun(_ folder: URL, _ root: URL, json: Bool = false) -> CommandResult {
    SkillgardenCommand.run(arguments: ["publish", "--dry-run", folder.path] + (json ? ["--json"] : []), root: root)
}

@Test func dryRunOfANewCoursePlansEveryRecordAndCreatesNoFile() throws {
    try withCourse { folder, root, base in
        let before = try tree(base)
        let expected = CommandResult(exitCode: 0, stdout: """
            Dry run "Local Course Basics" (sample-course, published): created 7, updated 0, unchanged 0, removed 0
              create  course   sample-course
              create  lecture  apply
              create  lecture  check
              create  lecture  read
              create  lecture  welcome
              create  section  plan
              create  section  practice
            Files: added 13, changed 0, unchanged 0, removed 0
            Snapshot: new, 13 files, \(try size(folder))
            Library: \(root.path)
            Nothing was written.

            """, stderr: "")
        #expect(dryRun(folder, root) == expected)
        // The flag can come after the course folder.
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path, "--dry-run"], root: root) == expected)
        #expect(try tree(base) == before)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // An empty library folder has no database. Dry run plans the same and creates no file.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = try tree(base)
        #expect(dryRun(folder, root) == expected)
        #expect(try tree(base) == empty)
    }
}

@Test func dryRunListsRecordAndFileChangesAndPublishAgrees() throws {
    try withCourse { folder, root, _ in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        try edit(folder, "      - id: check\n", "      - id: check-2\n")
        try edit(folder, "title: Read the plan", "title: Read the new plan")
        try Data("changed".utf8).write(to: folder.appending(path: "content/plan.md"))
        try Data("extra".utf8).write(to: folder.appending(path: "content/extra.txt"))
        try FileManager.default.removeItem(at: folder.appending(path: "content/checklist.txt"))
        let before = try tree(root)
        #expect(dryRun(folder, root) == CommandResult(exitCode: 0, stdout: """
            Dry run "Local Course Basics" (sample-course, published): created 1, updated 1, unchanged 5, removed 1
              create  lecture  check-2
              update  lecture  read
              remove  lecture  check
            Files: added 1, changed 2, unchanged 10, removed 1
            Snapshot: new, 13 files, \(try size(folder))
            Library: \(root.path)
            Nothing was written.

            """, stderr: ""))
        #expect(try tree(root) == before)
        let plan = try CoursePublisher.plan(courseFolder: folder, root: root)
        let result = try CoursePublisher.publish(courseFolder: folder, root: root)
        let planned: [Int] = [plan.created, plan.updated, plan.unchanged, plan.removed]
        #expect(planned == [result.created, result.updated, result.unchanged, result.removed])
    }
}

@Test func dryRunKeepsTheSnapshotOfAnUnchangedCourse() throws {
    try withCourse { folder, root, _ in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
        let before = try tree(root)
        #expect(dryRun(folder, root).stdout == """
            Dry run "Local Course Basics" (sample-course, published): created 0, updated 0, unchanged 7, removed 0
            Files: added 0, changed 0, unchanged 13, removed 0
            Snapshot: kept \(snapshot.lastPathComponent)
            Library: \(root.path)
            Nothing was written.

            """)
        #expect(try tree(root) == before)
        // An internal file change makes a new snapshot, the same as publish.
        try Data("notes".utf8).write(to: folder.appending(path: "internal/research.md"))
        let plan = try CoursePublisher.plan(courseFolder: folder, root: root)
        #expect(plan.files == FileCounts(added: 0, changed: 1, unchanged: 12, removed: 0))
        #expect(plan.snapshot.keptID == nil)
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root) != snapshot)
    }
}

@Test func dryRunOfADraftPrintsTheDraftLine() throws {
    try withCourse { folder, root, _ in
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        let lines = dryRun(folder, root).stdout.split(separator: "\n").suffix(3)
        #expect(lines == ["Draft: learners do not see this course.", "Library: \(root.path)", "Nothing was written."])
        #expect(dryRun(folder, root).stdout.hasPrefix("Dry run \"Local Course Basics\" (sample-course, draft): created 7,"))
    }
}

@Test func dryRunOfAnOlderStorePrintsTheMigrationAndDoesNotMigrate() throws {
    try withCourse { folder, root, _ in
        let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(3)))
        let manifest = try ManifestLoader.load(courseFolder: folder)
        try FileManager.default.createDirectory(at: root.appending(path: "courses"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: root.appending(path: "courses/old"))
        let v3 = try SQLiteDatabase(url: old.databaseURL)
        try v3.execute("INSERT INTO courses (id, title, subtitle, state) VALUES ('sample-course', 'Old', '', 'published')")
        try v3.execute("INSERT INTO course_publications (course_id, manifest, directory) VALUES ('sample-course', ?, 'courses/old')",
                       [String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)])
        let before = try tree(root)
        let result = dryRun(folder, root)
        #expect(result.exitCode == 0)
        // A version 3 snapshot holds internal/ in the learner folder and the course has no image, so publish copies again.
        #expect(result.stdout.contains("""
            Dry run "Local Course Basics" (sample-course, published): created 0, updated 0, unchanged 7, removed 0
            Files: added 0, changed 0, unchanged 13, removed 0
            Snapshot: new, 13 files, \(try size(folder))
            Migration: publish will update the library from version 3 to \(CourseStore.currentSchemaVersion).
            Library: \(root.path)
            """))
        #expect(try tree(root) == before)
        #expect(try old.schemaVersion == 3)
        // A version 1 store has no publications. It plans as not installed.
        let base = root.deletingLastPathComponent()
        let v1 = base.appending(path: "v1")
        _ = try CourseStore(root: v1, migrations: Array(CourseStore.migrations.prefix(1)))
        let v1Before = try tree(v1)
        let plan = try CoursePublisher.plan(courseFolder: folder, root: v1)
        #expect(plan.created == 7 && plan.migrationFrom == 1)
        #expect(try tree(v1) == v1Before)
    }
}

@Test func dryRunOfANewerStoreExitsThreeWithAHint() throws {
    try withCourse { folder, root, _ in
        let newer = try CourseStore(root: root, migrations: CourseStore.migrations + [["CREATE TABLE later (id TEXT)"]])
        let version = try newer.schemaVersion
        let before = try tree(root)
        let supported = CourseStore.currentSchemaVersion
        #expect(dryRun(folder, root) == CommandResult(exitCode: 3, stdout: "", stderr: """
            error: The library uses schema version \(version), but this app supports version \(supported).
            hint: Update skillgarden. Dry run does not change the library.

            """))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(dryRun(folder, root, json: true).stdout.utf8)) as? [String: Any])
        let diagnostic = try #require((json["diagnostics"] as? [[String: Any]])?.first)
        #expect(diagnostic["hint"] as? String == "Update skillgarden. Dry run does not change the library.")
        #expect(json["exit_code"] as? Int == 3)
        #expect(try tree(root) == before)
    }
}

@Test func dryRunJSONGivesIntegerBytesAndTheChanges() throws {
    try withCourse { folder, root, _ in
        let output = dryRun(folder, root, json: true)
        #expect(output.exitCode == 0 && output.stderr.isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        #expect(json["command"] as? String == "publish")
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["dry_run"] as? Bool == true)
        #expect(result["created"] as? Int == 7 && result["library_path"] as? String == root.path)
        #expect((result["changes"] as? [[String: String]])?.first == ["action": "create", "kind": "course", "id": "sample-course"])
        #expect(result["files"] as? [String: Int] == ["added": 13, "changed": 0, "unchanged": 0, "removed": 0])
        let snapshot = try #require(result["snapshot"] as? [String: Any])
        let bytes = try tree(folder).values.compactMap { $0 }.reduce(0) { $0 + $1.count }
        #expect(snapshot["state"] as? String == "new" && snapshot["id"] is NSNull)
        #expect(snapshot["files"] as? Int == 13 && snapshot["bytes"] as? Int == bytes)
        #expect(result["migration"] is NSNull)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func dryRunErrorsMatchPublishErrors() throws {
    try withCourse { folder, root, _ in
        try edit(folder, "path: media/course.svg", "path: media/absent.svg")
        let publish = SkillgardenCommand.run(arguments: ["publish", folder.path], root: root)
        #expect(publish.exitCode == 1)
        #expect(dryRun(folder, root) == publish)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        for arguments in [["publish", "--dry-run"], ["publish", "--dry-run", "--dry-run", folder.path],
                          ["publish", "--dry-run", folder.path, "extra"]] {
            #expect(SkillgardenCommand.run(arguments: arguments, root: root).exitCode == 2)
        }
    }
}
