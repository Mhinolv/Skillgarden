import Foundation
import SQLite3
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course, a library root that does not exist yet and their base folder.
private func withCourse(_ body: (URL, URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenRemoveTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try body(folder, base.appending(path: "library"), base)
}

/// A second copy of the sample course with another id and title.
private func otherCourse(_ base: URL) throws -> URL {
    let folder = base.appending(path: "other")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
        .replacingOccurrences(of: "id: sample-course\ntitle: Local Course Basics", with: "id: other-course\ntitle: Other Course")
    try text.write(to: file, atomically: true, encoding: .utf8)
    return folder
}

private func run(_ arguments: [String], _ root: URL) -> CommandResult {
    SkillgardenCommand.run(arguments: arguments, root: root)
}

/// The publication folders of a course in `courses/`, `derivatives/`, `internal/` order, as publish wrote them.
private func folders(_ root: URL, _ id: String) throws -> [String] {
    let publication = try #require(try CourseStore(root: root).publication(id: id))
    let name = (publication.directory as NSString).lastPathComponent
    return [publication.directory, "derivatives/\(name)", publication.internalDirectory].compactMap { $0 }
        .map { root.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
}

private func course(_ root: URL, _ id: String) throws -> Course? {
    try CourseStore(root: root).loadCourse(id: id, includeDrafts: true)
}

private let usage = SkillgardenCommand.usage + SkillgardenCommand.usageMore

@Test func removeDeletesTheCourseAndKeepsTheOtherCourse() throws {
    try withCourse { folder, root, base in
        #expect(run(["publish", folder.path], root).exitCode == 0)
        #expect(run(["publish", try otherCourse(base).path], root).exitCode == 0)
        let kept = try folders(root, "sample-course")
        #expect(kept.count == 3)
        let other = try CourseStore(root: root).loadCourse(id: "other-course", includeDrafts: true)
        let otherFolders = try folders(root, "other-course")

        let result = run(["remove", "sample-course", "--yes"], root)
        #expect(result == CommandResult(exitCode: 0, stdout: """
            Removed "Local Course Basics" (sample-course) from the library.
            Learner progress stays. If you publish this course id again, the progress comes back.

            """ + kept.map { "Files stay on disk: \($0)\n" }.joined() + "Library: \(root.path)\n", stderr: ""))

        let store = try CourseStore(root: root)
        #expect(try store.loadCourse(id: "sample-course", includeDrafts: true) == nil)
        #expect(try store.publication(id: "sample-course") == nil)
        #expect(try store.allTranscriptCues()["sample-course"] == nil)
        // The snapshot folders stay on disk.
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        // The other course is unchanged.
        #expect(try store.loadCourse(id: "other-course", includeDrafts: true) == other)
        #expect(try folders(root, "other-course") == otherFolders)
        #expect(try CoursePublisher.inspect(courseID: "other-course", root: root) != nil)
        // A second run finds no course.
        #expect(run(["remove", "sample-course", "--yes"], root).exitCode == 1)
    }
}

@Test func removeAcceptsYesBeforeTheID() throws {
    try withCourse { folder, root, _ throws in
        #expect(run(["publish", folder.path], root).exitCode == 0)
        let result = run(["remove", "--yes", "sample-course"], root)
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("Removed \"Local Course Basics\" (sample-course) from the library.\n"))
        #expect(try course(root, "sample-course") == nil)
    }
}

@Test func removeWithoutYesExitsTwoAndDoesNotOpenTheLibrary() throws {
    try withCourse { folder, root, base throws in
        // With no library, the run does not create the folder.
        let empty = base.appending(path: "empty")
        #expect(run(["remove", "sample-course"], empty) == CommandResult(exitCode: 2, stdout: "", stderr: """
            error: remove deletes course "sample-course" from the library. Run it again with --yes to confirm.
            Library: \(empty.path)

            """))
        #expect(!FileManager.default.fileExists(atPath: empty.path))

        #expect(run(["publish", folder.path], root).exitCode == 0)
        // Another connection holds a write lock. A run that opened the library would wait 5 seconds and exit 3.
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(root.appending(path: "library.sqlite").path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let start = Date()
        #expect(run(["remove", "sample-course"], root).exitCode == 2)
        #expect(Date().timeIntervalSince(start) < 2)
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        #expect(try course(root, "sample-course") != nil)
    }
}

@Test func removeOfAnUnknownCourseExitsOne() throws {
    try withCourse { folder, root, base throws in
        #expect(run(["publish", folder.path], root).exitCode == 0)
        #expect(run(["remove", "absent", "--yes"], root) == CommandResult(exitCode: 1, stdout: "", stderr: """
            error: course "absent" not found
            Library: \(root.path)

            """))
        #expect(try course(root, "sample-course") != nil)
        // A library with no database stays absent.
        let empty = base.appending(path: "empty")
        #expect(run(["remove", "sample-course", "--yes"], empty).exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
    }
}

@Test func removeRejectsWrongArguments() throws {
    try withCourse { _, root, _ in
        let error = "error: expected remove <course-id> --yes\n" + usage
        for arguments in [["remove"], ["remove", "--yes"], ["remove", "a", "b", "--yes"], ["remove", "a", "--yes", "--yes"],
                          ["remove", "a", "--force"], ["remove", "-a", "--yes"], ["remove", "", "--yes"]] {
            #expect(run(arguments, root) == CommandResult(exitCode: 2, stdout: "", stderr: error))
        }
        #expect(usage.contains("       skillgarden inspect <course-id> [--json]\n       skillgarden remove <course-id> --yes [--json]\n"))
        #expect(run(["remove", "--help"], root) == CommandResult(exitCode: 0, stdout: SkillgardenCommand.help, stderr: ""))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func removeKeepsLearnerProgressForAPublishAgain() throws {
    try withCourse { folder, root, _ in
        #expect(run(["publish", folder.path], root).exitCode == 0)
        let store = try CourseStore(root: root)
        let lecture = try #require(try store.loadCourse(id: "sample-course")?.sections.first?.lectures.first)
        try store.saveProgress(LectureProgress(completed: true, resumeSeconds: 12), courseID: "sample-course", lectureID: lecture.id)
        try store.saveLastOpenedLecture(courseID: "sample-course", lectureID: lecture.id)

        #expect(run(["remove", "sample-course", "--yes"], root).exitCode == 0)
        let after = try CourseStore(root: root)
        #expect(try after.progress(courseID: "sample-course", lectureID: lecture.id)?.completed == true)
        #expect(try after.lastOpenedLectures()["sample-course"] == lecture.id)

        // Publish again brings the course back with its progress.
        #expect(run(["publish", folder.path], root).exitCode == 0)
        #expect(try after.loadCourse(id: "sample-course") != nil)
        #expect(try after.progress(courseID: "sample-course", lectureID: lecture.id)
                == LectureProgress(completed: true, resumeSeconds: 12))
    }
}

@Test func removeOfACourseWithNoPublicationListsNoFolders() throws {
    try withCourse { _, root, _ in
        try CourseStore(root: root).saveCourse(Course(id: "plain", title: "Plain", sections: []))
        #expect(run(["remove", "plain", "--yes"], root).stdout == """
            Removed "Plain" (plain) from the library.
            Learner progress stays. If you publish this course id again, the progress comes back.
            Library: \(root.path)

            """)
    }
}

@Test func removeJSONHasTheResultAndTheDiagnostics() throws {
    try withCourse { folder, root, _ in
        #expect(run(["publish", folder.path], root).exitCode == 0)
        let kept = try folders(root, "sample-course")
        func json(_ arguments: [String]) throws -> [String: Any] {
            let result = run(arguments + ["--json"], root)
            #expect(result.stderr.isEmpty)
            return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        }
        let unconfirmed = try json(["remove", "sample-course"])
        #expect(unconfirmed["command"] as? String == "remove")
        #expect(unconfirmed["exit_code"] as? Int == 2)
        let diagnostic = try #require((unconfirmed["diagnostics"] as? [[String: Any]])?.first)
        #expect(diagnostic["code"] as? String == "usage")

        let removed = try json(["remove", "sample-course", "--yes"])
        #expect(removed["ok"] as? Bool == true)
        let result = try #require(removed["result"] as? [String: Any])
        #expect(result["title"] as? String == "Local Course Basics")
        #expect(result["id"] as? String == "sample-course")
        #expect(result["progress_kept"] as? Bool == true)
        #expect(result["folders_kept"] as? [String] == kept)
        #expect(result["library_path"] as? String == root.path)

        let missing = try json(["remove", "sample-course", "--yes"])
        #expect(missing["exit_code"] as? Int == 1)
        #expect((missing["diagnostics"] as? [[String: Any]])?.first?["code"] as? String == "course.not_found")
    }
}
