import Foundation
import SQLite3
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course and an empty library root.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenInternalTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try body(folder, base.appending(path: "library"))
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
}

private let internalBlock = """
    internal:
      files:
        - path: internal/research.md
          title: Research brief
          description: Team notes for the course plan
        - path: internal/transcript.vtt
          title: Transcript pack

    """

private func internalDirectory(_ root: URL) throws -> String? {
    try SQLiteDatabase(url: root.appending(path: "library.sqlite"))
        .query("SELECT internal_directory FROM course_publications") {
            sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : SQLiteDatabase.text($0, 0)
        }.first ?? nil
}

private func files(in directory: URL) throws -> [String] {
    let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    return enumerator.compactMap { item -> String? in
        guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return String(url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))
    }.sorted()
}

@Test func publishStoresInternalFilesOutsideTheLearnerSnapshot() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
        #expect(try files(in: snapshot) == [
            "content/brief.md", "content/checklist.txt", "content/plan.md", "content/sections.csv",
            "content/welcome.mp4", "content/welcome.vtt", "content/worksheet.pdf", "media/course.svg", "media/poster.svg", "media/section.svg", "skillgarden.yaml",
        ])
        let relative = try #require(try internalDirectory(root))
        #expect(relative.hasPrefix("internal/"))
        let area = root.appending(path: relative)
        #expect(try files(in: area) == ["research.md", "transcript.vtt"])
        #expect(FileManager.default.contentsEqual(atPath: area.appending(path: "research.md").path,
                                                  andPath: folder.appending(path: "internal/research.md").path))
        // An unchanged course keeps both areas.
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root) == snapshot)
        #expect(try internalDirectory(root) == relative)
        // A changed internal file gives a new internal area and a new learner snapshot.
        try Data("changed".utf8).write(to: folder.appending(path: "internal/research.md"))
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let changed = try #require(try internalDirectory(root))
        #expect(changed != relative)
        #expect(try Data(contentsOf: root.appending(path: changed).appending(path: "research.md")) == Data("changed".utf8))
        // A course without internal files has no internal area.
        try edit(folder, internalBlock, "")
        try FileManager.default.removeItem(at: folder.appending(path: "internal"))
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try internalDirectory(root) == nil)
        #expect(try CoursePublisher.internalFiles(courseID: "sample-course", root: root) == [])
    }
}

@Test func publishTreatsAnInternalFolderInAnyCaseAsInternal() throws {
    for name in ["Internal", "INTERNAL"] {
        try withCourse { folder, root in
            // Two moves give a new case on a case-insensitive volume too.
            try FileManager.default.moveItem(at: folder.appending(path: "internal"), to: folder.appending(path: "moved"))
            try FileManager.default.moveItem(at: folder.appending(path: "moved"), to: folder.appending(path: name))
            #expect(try CoursePublisher.validate(courseFolder: folder).id == "sample-course")
            try CoursePublisher.publish(courseFolder: folder, root: root)
            let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
            #expect(try files(in: snapshot) == [
                "content/brief.md", "content/checklist.txt", "content/plan.md", "content/sections.csv",
                "content/welcome.mp4", "content/welcome.vtt", "content/worksheet.pdf", "media/course.svg", "media/poster.svg", "media/section.svg", "skillgarden.yaml",
            ], "\(name)")
            let relative = try #require(try internalDirectory(root))
            #expect(try files(in: root.appending(path: relative)) == ["research.md", "transcript.vtt"])
            #expect(try CoursePublisher.internalFiles(courseID: "sample-course", root: root)?.map(\.path)
                == ["internal/research.md", "internal/transcript.vtt"])
            // An unchanged course keeps both areas.
            try CoursePublisher.publish(courseFolder: folder, root: root)
            #expect(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root) == snapshot)
            #expect(try internalDirectory(root) == relative)
        }
    }
}

@Test func learnerPathsIntoAnInternalFolderInAnyCaseFail() throws {
    for bad in ["Internal/research.md", "INTERNAL/research.md", "./internal/research.md", "./Internal/research.md"] {
        try withCourse { folder, root in
            let manifest = folder.appending(path: "skillgarden.yaml").path
            try edit(folder, "path: media/course.svg", "path: \(bad)")
            #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
                exitCode: 1, stdout: "", stderr: "error: \(manifest): course_image.path: path must not be inside internal/\n"), "\(bad)")
        }
    }
    // Runtime guards resolve no file inside the internal folder in any case.
    for bad in ["Internal/research.md", "INTERNAL/a", "./iNtErNaL/a", "content/../Internal/a"] {
        #expect(LectureArticle.normalize(bad) == nil, "\(bad)")
    }
    #expect(LectureArticle.normalize("internals/a") == "internals/a")
}

@Test func learnerQueriesReturnNoInternalMaterial() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let store = try CourseStore(root: root)
        var courses = try store.listCourses() + store.listCourses(includeDrafts: true)
        courses += [try #require(try store.loadCourse(id: "sample-course")),
                    try #require(try store.loadCourse(id: "sample-course", includeDrafts: true))]
        let text = String(decoding: try JSONEncoder().encode(courses), as: UTF8.self)
        for hidden in ["internal", "Research brief", "Transcript pack", "Team notes", "research.md", "transcript.vtt"] {
            #expect(!text.contains(hidden), "learner data contains \(hidden)")
        }
    }
}

@Test func publishReportsInternalPathErrors() throws {
    try withCourse { folder, root in
        let manifest = folder.appending(path: "skillgarden.yaml").path
        let original = try String(contentsOfFile: manifest, encoding: .utf8)
        func write(_ old: String, _ new: String) throws {
            #expect(original.contains(old))
            try original.replacingOccurrences(of: old, with: new).write(toFile: manifest, atomically: true, encoding: .utf8)
        }
        for bad in ["media/course.svg", "internal/", "internal/../media/course.svg", "/tmp/research.md", "../research.md",
                    "internal-notes/a.md", "internal\\\\..\\\\secret.md"] {
            try write("path: internal/research.md", "path: \"\(bad)\"")
            #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
                exitCode: 1, stdout: "", stderr: "error: \(manifest): internal.files[0].path: path must stay inside internal/\n"))
        }
        // Learner paths must not point into internal/.
        try write("path: media/course.svg", "path: internal/research.md")
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(manifest): course_image.path: path must not be inside internal/\n"))
        try write("path: internal/transcript.vtt", "path: internal/absent.vtt")
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(folder.path): internal.files[1].path: file does not exist\n"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func internalFieldsAreValidated() throws {
    try withCourse { folder, root in
        let manifest = folder.appending(path: "skillgarden.yaml").path
        try edit(folder, "      title: Transcript pack\n", "      description: 4\n")
        let result = SkillgardenCommand.run(arguments: ["publish", folder.path], root: root)
        #expect(result.exitCode == 1)
        #expect(result.stderr == """
            error: \(manifest): internal.files[1].description: expected string, found integer
            error: \(manifest): internal.files[1].title: required field is missing

            """)
        try edit(folder, "      description: 4\n", "      title: Transcript pack\n")
        try edit(folder, internalBlock, "internal:\n  files: []\n")
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root).exitCode == 0)
        #expect(try CoursePublisher.internalFiles(courseID: "sample-course", root: root) == [])
    }
}

@Test func commandListsInternalFiles() throws {
    try withCourse { folder, root in
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        // Draft courses list their internal files too, in manifest order.
        #expect(SkillgardenCommand.run(arguments: ["internal", "list", "sample-course"], root: root) == CommandResult(
            exitCode: 0, stdout: """
                TITLE\tPATH\tDESCRIPTION
                Research brief\tinternal/research.md\tTeam notes for the course plan
                Transcript pack\tinternal/transcript.vtt\t

                """, stderr: ""))
        // Tabs and line breaks in values stay inside one cell.
        try edit(folder, "description: Team notes for the course plan", "description: \"Team\\tnotes\\nfor the plan\"")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(SkillgardenCommand.run(arguments: ["internal", "list", "sample-course"], root: root).stdout
            .contains("Research brief\tinternal/research.md\tTeam notes for the plan\n"))
        try edit(folder, "description: \"Team\\tnotes\\nfor the plan\"", "description: Team notes for the course plan")
        try edit(folder, internalBlock, "")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(SkillgardenCommand.run(arguments: ["internal", "list", "sample-course"], root: root) == CommandResult(
            exitCode: 0, stdout: "No internal files for course \"sample-course\".\n", stderr: ""))
        #expect(SkillgardenCommand.run(arguments: ["internal", "list", "absent"], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: course \"absent\" not found\n"))
    }
}

@Test func commandInternalUsageErrors() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenUnused-\(UUID())")
    let usage = "usage: skillgarden publish <course-folder> [--json]\n       skillgarden validate <course-folder> [--json]\n       skillgarden internal list <course-id> [--json]\n"
    for arguments in [["internal"], ["internal", "list"], ["internal", "show", "a"], ["internal", "list", "a", "b"], ["internal", "list", "--bogus"]] {
        #expect(SkillgardenCommand.run(arguments: arguments, root: root) == CommandResult(
            exitCode: 2, stdout: "", stderr: "error: expected internal list <course-id>\n" + usage))
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func schemaVersionThreePublicationLoadsAndGainsInternalArea() throws {
    try withCourse { folder, root in
        let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(3)))
        #expect(try old.schemaVersion == 3)
        // A version 3 publish copied internal/ into the learner snapshot.
        var manifest = try ManifestLoader.load(courseFolder: folder)
        manifest.internalMaterial = nil
        try FileManager.default.createDirectory(at: root.appending(path: "courses"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: root.appending(path: "courses/old"))
        let v3 = try SQLiteDatabase(url: old.databaseURL)
        try v3.execute("INSERT INTO courses (id, title, subtitle, state) VALUES ('sample-course', 'Old', '', 'published')")
        try v3.execute("INSERT INTO course_publications (course_id, manifest, directory) VALUES ('sample-course', ?, 'courses/old')",
                       [String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)])
        let upgraded = try CourseStore(root: root)
        #expect(try upgraded.schemaVersion == CourseStore.currentSchemaVersion)
        #expect(try upgraded.publication(id: "sample-course")?.internalDirectory == nil)
        #expect(try CoursePublisher.internalFiles(courseID: "sample-course", root: root) == [])
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
        #expect(!FileManager.default.fileExists(atPath: snapshot.appending(path: "internal").path))
        #expect(try internalDirectory(root) != nil)
        #expect(try CoursePublisher.internalFiles(courseID: "sample-course", root: root)?.map(\.title) == ["Research brief", "Transcript pack"])
    }
}
