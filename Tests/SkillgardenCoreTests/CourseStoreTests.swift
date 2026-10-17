import Foundation
import SQLite3
import Testing
@testable import SkillgardenCore

private func withStore(_ body: (CourseStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try body(CourseStore(root: root), root)
}

private func sampleCourse(id: String = "course", state: PublicationState = .published) -> Course {
    Course(id: id, title: "A course", subtitle: "A subtitle", state: state, sections: [
        CourseSection(id: "second", title: "Second", objective: "Second objective", order: 20, state: .published, lectures: [
            Lecture(id: "assignment", title: "Assignment", type: .assignment, order: Int.max, state: .published),
            Lecture(id: "quiz", title: "Quiz", type: .quiz, order: 0, state: .draft),
        ]),
        CourseSection(id: "first", title: "First", objective: "First objective", order: -1, state: .published, lectures: [
            Lecture(id: "article", title: "Article", type: .article, order: 10, state: .published),
            Lecture(id: "video", title: "Video", type: .video, objective: "An objective", order: Int.min,
                    state: .published, recommendedNext: "article"),
        ]),
        CourseSection(id: "draft", title: "Draft", order: 30, state: .draft, lectures: [
            Lecture(id: "hidden", title: "Hidden", type: .video, order: 0, state: .published),
        ]),
    ])
}

@Test func emptyStoreCreatesCurrentVersion() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        #expect(try store.schemaVersion == CourseStore.currentSchemaVersion)
        #expect(FileManager.default.fileExists(atPath: store.databaseURL.path))
        #expect(store.databaseURL.path == root.appending(path: "library.sqlite").path)
        #expect(try store.listCourses().isEmpty)
        #expect(try store.loadCourse(id: "absent") == nil)
        try store.deleteCourse(id: "absent")
    }
}

@Test func courseRoundTripPreservesFieldsAndOrder() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        let original = sampleCourse()
        try store.saveCourse(original)
        let reopened = try CourseStore(root: root)
        let loaded = try #require(try reopened.loadCourse(id: original.id, includeDrafts: true))
        var expected = original
        expected.sections.sort { $0.order < $1.order }
        for index in expected.sections.indices { expected.sections[index].lectures.sort { $0.order < $1.order } }
        #expect(loaded == expected)
        #expect(Set(loaded.sections.flatMap(\.lectures).map(\.type)) == Set(LectureType.allCases))
    }
}

@Test func learnerReadsExcludeDraftsAtEveryLevel() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        try store.saveCourse(sampleCourse())
        try store.saveCourse(sampleCourse(id: "draft-course", state: .draft))
        #expect(try store.listCourses().map(\.id) == ["course"])
        #expect(try store.loadCourse(id: "draft-course") == nil)
        let course = try #require(try store.loadCourse(id: "course"))
        #expect(course.sections.map(\.id) == ["first", "second"])
        #expect(course.sections.flatMap(\.lectures).map(\.id) == ["video", "article", "assignment"])
        #expect(try store.listCourses(includeDrafts: true).count == 2)
        #expect(try store.loadCourse(id: "draft-course", includeDrafts: true)?.sections.count == 3)
    }
}

@Test func courseListSortsByTitleAndStableIdentity() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        for (id, title) in [("z", "Zoo"), ("b", "apple"), ("a", "apple"), ("x", "Banana")] {
            try store.saveCourse(Course(id: id, title: title, state: .published))
        }
        #expect(try store.listCourses().map(\.id) == ["a", "b", "x", "z"])
    }
}

@Test func equalOutlineOrdersUseStableIdentity() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        let lectures = ["b", "a"].map { Lecture(id: $0, title: $0, type: .video, order: 0, state: .published) }
        try store.saveCourse(Course(id: "c", title: "T", state: .published, sections: [
            CourseSection(id: "b", title: "B", order: 0, state: .published, lectures: lectures),
            CourseSection(id: "a", title: "A", order: 0, state: .published),
        ]))
        let course = try #require(try store.loadCourse(id: "c"))
        #expect(course.sections.map(\.id) == ["a", "b"])
        #expect(course.sections[1].lectures.map(\.id) == ["a", "b"])
    }
}

@Test func saveReplacesOutlineWithoutDuplicatesAndDeleteCascades() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        var course = sampleCourse()
        try store.saveCourse(course)
        try store.saveCourse(course)
        #expect(try store.listCourses(includeDrafts: true).count == 1)
        course.title = "Changed"
        course.sections.removeAll()
        try store.saveCourse(course)
        #expect(try store.loadCourse(id: course.id, includeDrafts: true) == course)
        try store.saveCourse(sampleCourse())
        try store.deleteCourse(id: course.id)
        #expect(try store.listCourses(includeDrafts: true).isEmpty)
        let db = try SQLiteDatabase(url: root.appending(path: "library.sqlite"))
        for table in ["sections", "lectures"] {
            #expect(try db.query("SELECT COUNT(*) FROM \(table)") { sqlite3_column_int64($0, 0) } == [0])
        }
    }
}

@Test func failedSaveRestoresPreviousCourse() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        try store.saveCourse(sampleCourse())
        let previous = try store.loadCourse(id: "course", includeDrafts: true)
        var invalid = sampleCourse()
        invalid.title = "Must roll back"
        invalid.sections.append(invalid.sections[0])
        #expect(throws: CourseStoreError.databaseFailure) { try store.saveCourse(invalid) }
        #expect(try store.loadCourse(id: "course", includeDrafts: true) == previous)
        invalid.id = "new-course"
        #expect(throws: CourseStoreError.databaseFailure) { try store.saveCourse(invalid) }
        #expect(try store.loadCourse(id: "new-course", includeDrafts: true) == nil)
    }
}

@Test func duplicateLectureAcrossSectionsFailsAtomically() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        var invalid = sampleCourse()
        invalid.sections[1].lectures.append(invalid.sections[0].lectures[0])
        #expect(throws: CourseStoreError.databaseFailure) { try store.saveCourse(invalid) }
        #expect(try store.listCourses(includeDrafts: true).isEmpty)
    }
}

@Test func idsAreScopedToCourseAndTextUsesBoundParameters() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        var first = sampleCourse(id: "'; DROP TABLE courses; --")
        first.title = "日本語 🌱 O'Brien\0tail"
        first.sections[0].lectures[0].recommendedNext = ""
        try store.saveCourse(first)
        try store.saveCourse(sampleCourse(id: "other"))
        #expect(try store.listCourses(includeDrafts: true).count == 2)
        let loaded = try #require(try store.loadCourse(id: first.id, includeDrafts: true))
        #expect(loaded.title == first.title)
        #expect(loaded.sections.first { $0.id == "second" }?.lectures.first { $0.id == "assignment" }?.recommendedNext == "")
        try store.deleteCourse(id: "other")
        #expect(try store.loadCourse(id: first.id) != nil)
    }
}

@Test func migrationPreservesPriorDataAndDefaults() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        try store.saveCourse(sampleCourse())
        let before = try store.loadCourse(id: "course", includeDrafts: true)
        let migration = ["ALTER TABLE courses ADD COLUMN future_value TEXT NOT NULL DEFAULT 'default'"]
        let upgraded = try CourseStore(root: root, migrations: CourseStore.migrations + [migration])
        #expect(try upgraded.schemaVersion == 3)
        #expect(try upgraded.loadCourse(id: "course", includeDrafts: true) == before)
        let reopened = try CourseStore(root: root, migrations: CourseStore.migrations + [migration])
        #expect(try reopened.schemaVersion == 3)
        #expect(try reopened.loadCourse(id: "course", includeDrafts: true) == before)
        let db = try SQLiteDatabase(url: store.databaseURL)
        #expect(try db.query("SELECT future_value FROM courses") { SQLiteDatabase.text($0, 0) } == ["default"])
        #expect(throws: CourseStoreError.unsupportedSchema(found: 3, supported: 2)) { try CourseStore(root: root) }
    }
}

@Test func failedMigrationRollsBackSchemaAndData() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        try store.saveCourse(sampleCourse())
        let before = try store.loadCourse(id: "course", includeDrafts: true)
        let migration = ["ALTER TABLE courses ADD COLUMN temporary_value TEXT", "INVALID SQL"]
        #expect(throws: CourseStoreError.databaseFailure) {
            try CourseStore(root: root, migrations: CourseStore.migrations + [migration])
        }
        let reopened = try CourseStore(root: root)
        #expect(try reopened.schemaVersion == 2)
        #expect(try reopened.loadCourse(id: "course", includeDrafts: true) == before)
        let db = try SQLiteDatabase(url: store.databaseURL)
        let columns = try db.query("PRAGMA table_info(courses)") { SQLiteDatabase.text($0, 1) }
        #expect(!columns.contains("temporary_value"))
    }
}

@Test func invalidRootsAndCorruptDatabasesThrowStoreErrors() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("file".utf8).write(to: root)
    #expect(throws: CourseStoreError.cannotOpen) { try CourseStore(root: root) }
    try FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not a database".utf8).write(to: root.appending(path: "library.sqlite"))
    #expect(throws: CourseStoreError.databaseFailure) { try CourseStore(root: root) }
}

@Test func concurrentAccessPreservesWholeCourses() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CourseStore(root: root)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<30 {
            group.addTask {
                let id = String(index)
                try store.saveCourse(sampleCourse(id: id))
                #expect(try store.loadCourse(id: id)?.sections.count == 2)
            }
        }
        try await group.waitForAll()
    }
    #expect(try store.listCourses().count == 30)
}

@Test func invalidSchemaVersionsFailWithoutDataLoss() throws {
    try withStore { (store: CourseStore, root: URL) throws in
        try store.saveCourse(sampleCourse())
        let before = try store.loadCourse(id: "course", includeDrafts: true)
        let db = try SQLiteDatabase(url: store.databaseURL)
        try db.execute("UPDATE schema_version SET version = -1")
        #expect(throws: CourseStoreError.invalidData) { try CourseStore(root: root) }
        try db.execute("UPDATE schema_version SET version = 1")
        try db.execute("INSERT INTO schema_version VALUES (1)")
        #expect(throws: CourseStoreError.invalidData) { try CourseStore(root: root) }
        try db.execute("DELETE FROM schema_version")
        try db.execute("INSERT INTO schema_version VALUES (?)", [String(CourseStore.currentSchemaVersion)])
        #expect(try CourseStore(root: root).loadCourse(id: "course", includeDrafts: true) == before)
    }
}

@Test func emptyDraftCourseRequiresExplicitAccess() throws {
    try withStore { (store: CourseStore, _: URL) throws in
        let empty = Course(id: "", title: "")
        try store.saveCourse(empty)
        #expect(try store.listCourses().isEmpty)
        #expect(try store.loadCourse(id: "", includeDrafts: true) == empty)
        try store.deleteCourse(id: "")
        #expect(try store.listCourses(includeDrafts: true).isEmpty)
    }
}
