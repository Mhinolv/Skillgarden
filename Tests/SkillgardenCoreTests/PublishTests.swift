import Foundation
import SQLite3
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course and an empty library root.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenPublishTests-\(UUID())")
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

private func count(_ root: URL, _ table: String) throws -> Int64 {
    try SQLiteDatabase(url: root.appending(path: "library.sqlite"))
        .query("SELECT COUNT(*) FROM \(table)") { sqlite3_column_int64($0, 0) }.first ?? -1
}

private func counts(_ result: PublishResult) -> [Int] {
    [result.created, result.updated, result.unchanged, result.removed]
}

@Test func repeatPublishCreatesOneCourseWithoutDuplicates() throws {
    try withCourse { folder, root in
        let first = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(first.summary == "Published \"Local Course Basics\" (sample-course, published): created 6, updated 0, unchanged 0, removed 0")
        let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
        let second = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(counts(second) == [0, 0, 6, 0])
        #expect(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root) == snapshot)
        #expect(try CourseStore(root: root).listCourses(includeDrafts: true).count == 1)
        for (table, rows) in [("courses", 1), ("sections", 2), ("lectures", 4), ("course_publications", 1)] {
            #expect(try count(root, table) == Int64(rows))
        }
        let courses = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "courses").path)
        #expect(courses.count == 1)
    }
}

@Test func republishUpdatesFieldsAndKeepsCourseID() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        try edit(folder, "title: Local Course Basics", "title: Renamed Course")
        try edit(folder, "title: Read the plan", "title: Read the new plan")
        try edit(folder, """
                  - id: apply
                    title: Write a plan
            """, """
                  - id: draft-plan
                    title: Write a plan
            """)
        let result = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(result.title == "Renamed Course")
        #expect(counts(result) == [1, 1, 4, 1])
        let store = try CourseStore(root: root)
        let course = try #require(try store.loadCourse(id: "sample-course", includeDrafts: true))
        #expect(course.title == "Renamed Course")
        #expect(course.sections[0].lectures.map(\.title) == ["Welcome", "Read the new plan"])
        #expect(course.sections[1].lectures.map(\.id) == ["check", "draft-plan"])
        #expect(try store.listCourses(includeDrafts: true).map(\.id) == ["sample-course"])
        #expect(try count(root, "lectures") == 4)
    }
}

@Test func draftCourseIsHiddenFromLearnerLibrary() throws {
    try withCourse { folder, root in
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        let result = SkillgardenCommand.run(arguments: ["publish", folder.path], root: root)
        #expect(result == CommandResult(exitCode: 0, stdout: """
            Published "Local Course Basics" (sample-course, draft): created 6, updated 0, unchanged 0, removed 0
            Draft: learners do not see this course.

            """, stderr: ""))
        let store = try CourseStore(root: root)
        #expect(try store.listCourses().isEmpty)
        #expect(try store.loadCourse(id: "sample-course") == nil)
        #expect(try store.loadCourse(id: "sample-course", includeDrafts: true)?.state == .draft)
        // Draft sections and lectures inside a published course stay hidden too.
        try edit(folder, "state: draft\ntheme:", "state: published\ntheme:")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let course = try #require(try store.loadCourse(id: "sample-course"))
        #expect(course.sections.map(\.id) == ["plan"])
    }
}

@Test func learnerProgressSurvivesRepublish() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let store = try CourseStore(root: root)
        let progress = LectureProgress(completed: true, resumeSeconds: 42.5)
        try store.saveProgress(progress, courseID: "sample-course", lectureID: "welcome")
        try edit(folder, "title: Welcome", "title: Welcome back")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try store.progress(courseID: "sample-course", lectureID: "welcome") == progress)
        // A lecture that leaves the manifest and returns keeps its learner data.
        try edit(folder, "  - id: welcome\n", "  - id: welcome-moved\n")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try store.loadCourse(id: "sample-course")?.sections[0].lectures.map(\.id) == ["welcome-moved", "read"])
        try edit(folder, "  - id: welcome-moved\n", "  - id: welcome\n")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try store.progress(courseID: "sample-course", lectureID: "welcome") == progress)
        #expect(try store.progress(courseID: "sample-course", lectureID: "read") == nil)
    }
}

@Test func publishOverDataFromSchemaVersionOne() throws {
    try withCourse { folder, root in
        let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(1)))
        #expect(try old.schemaVersion == 1)
        let saved = Course(id: "old-course", title: "Old course", state: .published, sections: [
            CourseSection(id: "s", title: "Section", order: 0, state: .published, lectures: [
                Lecture(id: "l", title: "Lecture", type: .article, order: 0, state: .published),
            ]),
        ])
        try old.saveCourse(saved)
        let upgraded = try CourseStore(root: root)
        #expect(try upgraded.schemaVersion == CourseStore.currentSchemaVersion)
        #expect(try upgraded.loadCourse(id: "old-course") == saved)
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try upgraded.listCourses().map(\.id) == ["sample-course", "old-course"])
        #expect(try upgraded.progress(courseID: "old-course", lectureID: "l") == nil)
    }
}

@Test func snapshotKeepsAssetsAfterSourceRemoval() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
        try FileManager.default.removeItem(at: folder)
        for path in ["skillgarden.yaml", "media/course.svg", "media/section.svg", "content/plan.md"] {
            #expect(FileManager.default.fileExists(atPath: snapshot.appending(path: path).path))
        }
        #expect(try CoursePublisher.assetDirectory(courseID: "absent", root: root) == nil)
    }
}

@Test func changedAssetCreatesNewSnapshot() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let first = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
        try Data("changed".utf8).write(to: folder.appending(path: "content/plan.md"))
        let result = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(counts(result) == [0, 0, 6, 0])
        let second = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
        #expect(second != first)
        #expect(try Data(contentsOf: second.appending(path: "content/plan.md")) == Data("changed".utf8))
    }
}

@Test func commandUsageAndHelp() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenUnused-\(UUID())")
    let usage = "usage: skillgarden publish <course-folder>\n"
    for arguments in [["publish", "--help"], ["--help"]] {
        #expect(SkillgardenCommand.run(arguments: arguments, root: root) == CommandResult(exitCode: 0, stdout: usage, stderr: ""))
    }
    #expect(SkillgardenCommand.run(arguments: ["--version"], root: root).stdout == "skillgarden \(Skillgarden.version)\n")
    for arguments in [[], ["publish"], ["publish", "a", "b"], ["publish", "--json"], ["remove", "a"]] {
        let result = SkillgardenCommand.run(arguments: arguments, root: root)
        #expect(result == CommandResult(exitCode: 2, stdout: "", stderr: "error: expected publish <course-folder>\n" + usage))
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func commandValidationErrorsExitOne() throws {
    try withCourse { folder, root in
        try edit(folder, "    title: Plan the course\n", "")
        let manifest = folder.appending(path: "skillgarden.yaml").path
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(manifest): sections[0].title: required field is missing\n"))
        try edit(folder, "  - id: plan\n", "  - id: plan\n    title: Plan the course\n")
        try edit(folder, "path: media/course.svg", "path: media/absent.svg")
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(folder.path): course_image.path: file does not exist\n"))
        let missing = folder.appending(path: "absent").path
        #expect(SkillgardenCommand.run(arguments: ["publish", missing], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(missing): $: no skillgarden.yaml or skillgarden.json found\n"))
        try edit(folder, "path: media/absent.svg", "path: media/course.svg")
        let inside = SkillgardenCommand.run(arguments: ["publish", folder.path], root: folder.appending(path: "library"))
        #expect(inside == CommandResult(exitCode: 1, stdout: "", stderr: "error: \(folder.path): $: library must be outside the course folder\n"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func commandStoreErrorsExitThree() throws {
    try withCourse { folder, root in
        try Data().write(to: root)
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
            exitCode: 3, stdout: "", stderr: "error: The library could not open its database.\n"))
    }
}
