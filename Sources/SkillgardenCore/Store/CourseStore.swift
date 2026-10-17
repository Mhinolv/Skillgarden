import Foundation
import SQLite3

/// A synchronous local store. The lock protects the connection and each complete operation.
public final class CourseStore: @unchecked Sendable {
    public static let currentSchemaVersion = 5
    public let databaseURL: URL
    private let database: SQLiteDatabase
    private let lock = NSLock()

    public convenience init(root: URL = Skillgarden.defaultDataDirectory) throws {
        try self.init(root: root, migrations: Self.migrations)
    }

    // Tests append a migration to prove that a prior database still loads.
    init(root: URL, migrations: [[String]]) throws {
        databaseURL = root.appending(path: "library.sqlite")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw CourseStoreError.cannotOpen
        }
        database = try SQLiteDatabase(url: databaseURL)
        try database.transaction {
            try database.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
            let versions = try database.query("SELECT version FROM schema_version") { Int(sqlite3_column_int64($0, 0)) }
            guard versions.count <= 1 else { throw CourseStoreError.invalidData }
            let version = versions.first ?? 0
            guard version >= 0 else { throw CourseStoreError.invalidData }
            guard version <= migrations.count else {
                throw CourseStoreError.unsupportedSchema(found: version, supported: migrations.count)
            }
            if versions.isEmpty { try database.execute("INSERT INTO schema_version VALUES (0)") }
            for index in version..<migrations.count {
                for sql in migrations[index] { try database.execute(sql) }
                try database.execute("UPDATE schema_version SET version = ?", [String(index + 1)])
            }
        }
    }

    public var schemaVersion: Int {
        get throws {
            try lock.withLock {
                try database.query("SELECT version FROM schema_version") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            }
        }
    }

    /// Saves the whole outline atomically and removes sections and lectures absent from the course.
    public func saveCourse(_ course: Course) throws {
        try lock.withLock {
            try database.transaction {
                try saveCourseRows(course)
            }
        }
    }

    private func saveCourseRows(_ course: Course) throws {
        try database.execute("""
            INSERT INTO courses (id, title, subtitle, state, image) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, subtitle=excluded.subtitle, state=excluded.state, image=excluded.image
            """, [course.id, course.title, course.subtitle, course.state.rawValue, try Self.encode(course.image)])
        try database.execute("DELETE FROM sections WHERE course_id = ?", [course.id])
        for section in course.sections {
            try database.execute("INSERT INTO sections (course_id, id, title, objective, sort_order, state, header_image) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                 [course.id, section.id, section.title, section.objective, String(section.order), section.state.rawValue,
                                  try Self.encode(section.headerImage)])
            for lecture in section.lectures {
                try database.execute("""
                    INSERT INTO lectures (course_id, section_id, id, title, type, objective, sort_order, state, recommended_next)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [course.id, section.id, lecture.id, lecture.title, lecture.type.rawValue, lecture.objective,
                          String(lecture.order), lecture.state.rawValue, lecture.recommendedNext])
            }
        }
    }

    /// Learner reads exclude draft courses and all descendants of draft sections.
    public func listCourses(includeDrafts: Bool = false) throws -> [Course] {
        try readCourses(id: nil, includeDrafts: includeDrafts)
    }

    public func loadCourse(id: String, includeDrafts: Bool = false) throws -> Course? {
        try readCourses(id: id, includeDrafts: includeDrafts).first
    }

    public func deleteCourse(id: String) throws {
        try lock.withLock { try database.execute("DELETE FROM courses WHERE id = ?", [id]) }
    }

    private func readCourses(id: String?, includeDrafts: Bool) throws -> [Course] {
        try lock.withLock {
            // Three queries fetch any library size. The transaction gives all queries one snapshot.
            try database.transaction(readOnly: true) {
                let filter = "(? IS NULL OR c.id = ?) AND (? = '1' OR c.state = 'published')"
                let values: [String?] = [id, id, includeDrafts ? "1" : "0"]
                let courses = try database.query("SELECT c.id, c.title, c.subtitle, c.state, c.image FROM courses c WHERE \(filter) ORDER BY c.title COLLATE NOCASE, c.title, c.id", values) { row in
                    Course(id: SQLiteDatabase.text(row, 0), title: SQLiteDatabase.text(row, 1),
                           subtitle: SQLiteDatabase.text(row, 2), state: try Self.state(row, 3), image: try Self.image(row, 4))
                }
                let sectionRows = try database.query("""
                    SELECT s.course_id, s.id, s.title, s.objective, s.sort_order, s.state, s.header_image
                    FROM sections s JOIN courses c ON c.id = s.course_id
                    WHERE \(filter) AND (? = '1' OR s.state = 'published') ORDER BY s.sort_order, s.id
                    """, values + [includeDrafts ? "1" : "0"]) { row in
                        (SQLiteDatabase.text(row, 0), CourseSection(id: SQLiteDatabase.text(row, 1), title: SQLiteDatabase.text(row, 2),
                            objective: SQLiteDatabase.text(row, 3), order: Int(sqlite3_column_int64(row, 4)), state: try Self.state(row, 5),
                            headerImage: try Self.image(row, 6)))
                    }
                let lectureRows = try database.query("""
                    SELECT l.course_id, l.section_id, l.id, l.title, l.type, l.objective, l.sort_order, l.state, l.recommended_next
                    FROM lectures l JOIN sections s ON s.course_id = l.course_id AND s.id = l.section_id
                    JOIN courses c ON c.id = l.course_id
                    WHERE \(filter) AND (? = '1' OR (s.state = 'published' AND l.state = 'published'))
                    ORDER BY l.sort_order, l.id
                    """, values + [includeDrafts ? "1" : "0"]) { row in
                        guard let type = LectureType(rawValue: SQLiteDatabase.text(row, 4)) else { throw CourseStoreError.invalidData }
                        return (SQLiteDatabase.text(row, 0), SQLiteDatabase.text(row, 1),
                                Lecture(id: SQLiteDatabase.text(row, 2), title: SQLiteDatabase.text(row, 3), type: type,
                                    objective: SQLiteDatabase.text(row, 5), order: Int(sqlite3_column_int64(row, 6)),
                                    state: try Self.state(row, 7), recommendedNext: sqlite3_column_type(row, 8) == SQLITE_NULL ? nil : SQLiteDatabase.text(row, 8)))
                    }
                var lectures: [String: [String: [Lecture]]] = [:]
                for (courseID, sectionID, lecture) in lectureRows { lectures[courseID, default: [:]][sectionID, default: []].append(lecture) }
                var sections: [String: [CourseSection]] = [:]
                for (courseID, var section) in sectionRows {
                    section.lectures = lectures[courseID]?[section.id] ?? []
                    sections[courseID, default: []].append(section)
                }
                return courses.map { course in
                    var course = course
                    course.sections = sections[course.id] ?? []
                    return course
                }
            }
        }
    }

    private static func state(_ row: OpaquePointer, _ column: Int32) throws -> PublicationState {
        guard let state = PublicationState(rawValue: SQLiteDatabase.text(row, column)) else { throw CourseStoreError.invalidData }
        return state
    }

    /// Rows saved before schema version 3 have no image and read as nil.
    private static func image(_ row: OpaquePointer, _ column: Int32) throws -> CourseImage? {
        guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
        guard let image = try? JSONDecoder().decode(CourseImage.self, from: Data(SQLiteDatabase.text(row, column).utf8)) else {
            throw CourseStoreError.invalidData
        }
        return image
    }

    private static func encode(_ image: CourseImage?) throws -> String? {
        guard let image else { return nil }
        guard let data = try? JSONEncoder().encode(image) else { throw CourseStoreError.invalidData }
        return String(decoding: data, as: UTF8.self)
    }

    /// `internalDirectory` is nil when the course has no internal files or was saved before schema version 4.
    func publication(id: String) throws -> (manifest: Data, directory: String, internalDirectory: String?)? {
        try lock.withLock {
            try database.query("SELECT manifest, directory, internal_directory FROM course_publications WHERE course_id = ?", [id]) {
                (Data(SQLiteDatabase.text($0, 0).utf8), SQLiteDatabase.text($0, 1),
                 sqlite3_column_type($0, 2) == SQLITE_NULL ? nil : SQLiteDatabase.text($0, 2))
            }.first
        }
    }

    /// All installed publications by course id, read in one query.
    func publications() throws -> [String: (manifest: Data, directory: String)] {
        try lock.withLock {
            let rows = try database.query("SELECT course_id, manifest, directory FROM course_publications") {
                (SQLiteDatabase.text($0, 0), Data(SQLiteDatabase.text($0, 1).utf8), SQLiteDatabase.text($0, 2))
            }
            return Dictionary(rows.map { ($0.0, (manifest: $0.1, directory: $0.2)) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func savePublication(_ course: Course, manifest: Data, directory: String, internalDirectory: String? = nil) throws {
        try lock.withLock {
            try database.transaction {
                try saveCourseRows(course)
                try database.execute("""
                    INSERT INTO course_publications (course_id, manifest, directory, internal_directory) VALUES (?, ?, ?, ?)
                    ON CONFLICT(course_id) DO UPDATE SET manifest=excluded.manifest, directory=excluded.directory,
                        internal_directory=excluded.internal_directory
                    """, [course.id, String(decoding: manifest, as: UTF8.self), directory, internalDirectory])
            }
        }
    }

    /// Learner data has no foreign key to outline rows, so a republish keeps it.
    public func saveProgress(_ progress: LectureProgress, courseID: String, lectureID: String) throws {
        try lock.withLock {
            try database.execute("""
                INSERT INTO lecture_progress (course_id, lecture_id, completed, resume_seconds) VALUES (?, ?, ?, ?)
                ON CONFLICT(course_id, lecture_id) DO UPDATE SET completed=excluded.completed, resume_seconds=excluded.resume_seconds
                """, [courseID, lectureID, progress.completed ? "1" : "0", String(progress.resumeSeconds)])
        }
    }

    public func progress(courseID: String, lectureID: String) throws -> LectureProgress? {
        try lock.withLock {
            try database.query("SELECT completed, resume_seconds FROM lecture_progress WHERE course_id = ? AND lecture_id = ?",
                               [courseID, lectureID]) {
                LectureProgress(completed: sqlite3_column_int64($0, 0) != 0, resumeSeconds: sqlite3_column_double($0, 1))
            }.first
        }
    }

    /// Sets the complete flag and keeps the saved resume position.
    public func setCompleted(_ completed: Bool, courseID: String, lectureID: String) throws {
        try lock.withLock {
            try database.execute("""
                INSERT INTO lecture_progress (course_id, lecture_id, completed) VALUES (?, ?, ?)
                ON CONFLICT(course_id, lecture_id) DO UPDATE SET completed=excluded.completed
                """, [courseID, lectureID, completed ? "1" : "0"])
        }
    }

    /// Sets the resume position and keeps the complete flag.
    public func saveResumePosition(_ seconds: Double, courseID: String, lectureID: String) throws {
        try lock.withLock {
            try database.execute("""
                INSERT INTO lecture_progress (course_id, lecture_id, resume_seconds) VALUES (?, ?, ?)
                ON CONFLICT(course_id, lecture_id) DO UPDATE SET resume_seconds=excluded.resume_seconds
                """, [courseID, lectureID, String(seconds.isFinite ? max(0, seconds) : 0)])
        }
    }

    /// All learner progress by course id, then lecture id, read in one query.
    public func allProgress() throws -> [String: [String: LectureProgress]] {
        try lock.withLock {
            var result: [String: [String: LectureProgress]] = [:]
            try database.query("SELECT course_id, lecture_id, completed, resume_seconds FROM lecture_progress") {
                result[SQLiteDatabase.text($0, 0), default: [:]][SQLiteDatabase.text($0, 1)] =
                    LectureProgress(completed: sqlite3_column_int64($0, 2) != 0, resumeSeconds: sqlite3_column_double($0, 3))
            }
            return result
        }
    }

    /// Learner data, so a republish keeps it. The lecture may leave the outline later.
    public func saveLastOpenedLecture(courseID: String, lectureID: String) throws {
        try lock.withLock {
            try database.execute("""
                INSERT INTO course_resume (course_id, lecture_id) VALUES (?, ?)
                ON CONFLICT(course_id) DO UPDATE SET lecture_id=excluded.lecture_id
                """, [courseID, lectureID])
        }
    }

    /// The last opened lecture id by course id. Stores saved before schema version 5 have none.
    public func lastOpenedLectures() throws -> [String: String] {
        try lock.withLock {
            let rows = try database.query("SELECT course_id, lecture_id FROM course_resume") {
                (SQLiteDatabase.text($0, 0), SQLiteDatabase.text($0, 1))
            }
            return Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
    }

    static let migrations: [[String]] = [[
        """
        CREATE TABLE courses (
            id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, subtitle TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL CHECK(state IN ('draft', 'published'))
        )
        """,
        """
        CREATE TABLE sections (
            course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
            id TEXT NOT NULL, title TEXT NOT NULL, objective TEXT NOT NULL DEFAULT '', sort_order INTEGER NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('draft', 'published')), PRIMARY KEY(course_id, id)
        )
        """,
        """
        CREATE TABLE lectures (
            course_id TEXT NOT NULL, section_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('video', 'article', 'quiz', 'assignment')),
            objective TEXT NOT NULL DEFAULT '', sort_order INTEGER NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('draft', 'published')), recommended_next TEXT,
            PRIMARY KEY(course_id, id),
            FOREIGN KEY(course_id, section_id) REFERENCES sections(course_id, id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX sections_outline ON sections(course_id, sort_order, id)",
        "CREATE INDEX lectures_outline ON lectures(course_id, section_id, sort_order, id)",
        "CREATE INDEX courses_title ON courses(title COLLATE NOCASE, title, id)",
    ], [
        """
        CREATE TABLE course_publications (
            course_id TEXT PRIMARY KEY NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
            manifest TEXT NOT NULL, directory TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE lecture_progress (
            course_id TEXT NOT NULL, lecture_id TEXT NOT NULL,
            completed INTEGER NOT NULL DEFAULT 0 CHECK(completed IN (0, 1)),
            resume_seconds REAL NOT NULL DEFAULT 0, PRIMARY KEY(course_id, lecture_id)
        )
        """,
    ], [
        // Image metadata is a CourseImage JSON object. NULL means that the row has no image metadata.
        "ALTER TABLE courses ADD COLUMN image TEXT",
        "ALTER TABLE sections ADD COLUMN header_image TEXT",
    ], [
        // Internal files live outside the learner snapshot. Learner reads never select this column.
        "ALTER TABLE course_publications ADD COLUMN internal_directory TEXT",
    ], [
        // Learner data has no foreign key to outline rows, so a republish keeps it.
        "CREATE TABLE course_resume (course_id TEXT PRIMARY KEY NOT NULL, lecture_id TEXT NOT NULL)",
    ]]
}
