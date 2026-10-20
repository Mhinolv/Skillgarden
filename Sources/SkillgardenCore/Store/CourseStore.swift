import Foundation
import SQLite3

/// A synchronous local store. The lock protects the connection and each complete operation.
public final class CourseStore: @unchecked Sendable {
    public static let currentSchemaVersion = 13
    static let databaseName = "library.sqlite"
    public let databaseURL: URL
    private let database: SQLiteDatabase
    private let lock = NSLock()

    public convenience init(root: URL = Skillgarden.defaultDataDirectory) throws {
        try self.init(root: root, migrations: Self.migrations)
    }

    // Tests append a migration to prove that a prior database still loads.
    init(root: URL, migrations: [[String]]) throws {
        databaseURL = root.appending(path: Self.databaseName)
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

    /// Deletes a course like `deleteCourse` and returns its title and publication folders. Nil for an unknown course.
    /// Learner progress and Q&A history have no foreign key to `courses`, so they stay (#118, #127).
    func removeCourse(id: String) throws -> (title: String, directory: String?, internalDirectory: String?)? {
        try lock.withLock {
            try database.transaction {
                guard let title = try database.query("SELECT title FROM courses WHERE id = ?", [id], row: { SQLiteDatabase.text($0, 0) }).first
                else { return nil }
                let folders = try database.query("SELECT directory, internal_directory FROM course_publications WHERE course_id = ?", [id]) {
                    (SQLiteDatabase.text($0, 0), sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : SQLiteDatabase.text($0, 1))
                }.first
                try database.execute("DELETE FROM courses WHERE id = ?", [id])
                return (title, folders?.0, folders?.1)
            }
        }
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

    func savePublication(_ course: Course, manifest: Data, directory: String, internalDirectory: String? = nil,
                         transcriptCues: [TranscriptCue] = []) throws {
        try lock.withLock {
            try database.transaction {
                try saveCourseRows(course)
                try database.execute("""
                    INSERT INTO course_publications (course_id, manifest, directory, internal_directory) VALUES (?, ?, ?, ?)
                    ON CONFLICT(course_id) DO UPDATE SET manifest=excluded.manifest, directory=excluded.directory,
                        internal_directory=excluded.internal_directory
                    """, [course.id, String(decoding: manifest, as: UTF8.self), directory, internalDirectory])
                try saveTranscriptRows(transcriptCues, courseID: course.id)
            }
        }
    }

    /// Replaces the transcript index of an installed course and marks the course as indexed.
    func saveTranscriptIndex(_ cues: [TranscriptCue], courseID: String) throws {
        try lock.withLock {
            try database.transaction { try saveTranscriptRows(cues, courseID: courseID) }
        }
    }

    private func saveTranscriptRows(_ cues: [TranscriptCue], courseID: String) throws {
        try database.execute("DELETE FROM transcript_cues WHERE course_id = ?", [courseID])
        for cue in cues {
            try database.execute("""
                INSERT INTO transcript_cues (course_id, lecture_id, cue_index, start_seconds, end_seconds, text)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [courseID, cue.lectureID, String(cue.index), String(cue.start), String(cue.end), cue.text])
        }
        try database.execute("UPDATE course_publications SET transcripts_indexed = 1 WHERE course_id = ?", [courseID])
    }

    /// False for a course that was published before schema version 9 and not published again.
    func hasTranscriptIndex(courseID: String) throws -> Bool {
        try lock.withLock {
            try database.query("SELECT transcripts_indexed FROM course_publications WHERE course_id = ?", [courseID]) {
                sqlite3_column_int64($0, 0) != 0
            }.first ?? false
        }
    }

    /// All indexed cues by course id, in lecture id and cue order, read in one query.
    /// Stores saved before schema version 9 have none.
    public func allTranscriptCues() throws -> [String: [TranscriptCue]] {
        try lock.withLock {
            var result: [String: [TranscriptCue]] = [:]
            try database.query("""
                SELECT course_id, lecture_id, cue_index, start_seconds, end_seconds, text FROM transcript_cues
                ORDER BY course_id, lecture_id, cue_index
                """) {
                result[SQLiteDatabase.text($0, 0), default: []].append(TranscriptCue(
                    lectureID: SQLiteDatabase.text($0, 1), index: Int(sqlite3_column_int64($0, 2)),
                    start: sqlite3_column_double($0, 3), end: sqlite3_column_double($0, 4), text: SQLiteDatabase.text($0, 5)))
            }
            return result
        }
    }

    /// Learner data has no foreign key to outline rows, so a republish keeps it.
    /// It writes the complete flag and the resume position. It keeps the saved `autoCompleteOff`.
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
            try database.query("""
                SELECT completed, resume_seconds, auto_complete_off FROM lecture_progress WHERE course_id = ? AND lecture_id = ?
                """, [courseID, lectureID]) {
                LectureProgress(completed: sqlite3_column_int64($0, 0) != 0, resumeSeconds: sqlite3_column_double($0, 1),
                                autoCompleteOff: sqlite3_column_int64($0, 2) != 0)
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

    /// The learner clicks the complete control: sets the complete flag and keeps the saved resume position.
    /// Incomplete turns off the automatic complete of the lecture. Complete turns it on again (#79).
    public func setCompletedByHand(_ completed: Bool, courseID: String, lectureID: String) throws {
        try lock.withLock {
            try database.execute("""
                INSERT INTO lecture_progress (course_id, lecture_id, completed, auto_complete_off) VALUES (?, ?, ?, ?)
                ON CONFLICT(course_id, lecture_id) DO UPDATE SET completed=excluded.completed, auto_complete_off=excluded.auto_complete_off
                """, [courseID, lectureID, completed ? "1" : "0", completed ? "0" : "1"])
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
            try database.query("SELECT course_id, lecture_id, completed, resume_seconds, auto_complete_off FROM lecture_progress") {
                result[SQLiteDatabase.text($0, 0), default: [:]][SQLiteDatabase.text($0, 1)] =
                    LectureProgress(completed: sqlite3_column_int64($0, 2) != 0, resumeSeconds: sqlite3_column_double($0, 3),
                                    autoCompleteOff: sqlite3_column_int64($0, 4) != 0)
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

    /// Keeps the latest result of each quiz. Learner data, so a republish keeps it.
    public func saveQuizResult(_ result: QuizResult, courseID: String, lectureID: String) throws {
        let skills = String(decoding: try JSONEncoder().encode(result.weakSkills), as: UTF8.self)
        try lock.withLock {
            try database.execute("""
                INSERT INTO quiz_results (course_id, lecture_id, correct, total, weak_skills) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(course_id, lecture_id) DO UPDATE SET correct=excluded.correct, total=excluded.total,
                    weak_skills=excluded.weak_skills
                """, [courseID, lectureID, String(result.correct), String(result.total), skills])
        }
    }

    /// The latest quiz results by course id, then lecture id. Stores saved before schema version 6 have none.
    public func allQuizResults() throws -> [String: [String: QuizResult]] {
        try lock.withLock {
            var results: [String: [String: QuizResult]] = [:]
            try database.query("SELECT course_id, lecture_id, correct, total, weak_skills FROM quiz_results") {
                guard let skills = try? JSONDecoder().decode([String].self, from: Data(SQLiteDatabase.text($0, 4).utf8)) else {
                    throw CourseStoreError.invalidData
                }
                results[SQLiteDatabase.text($0, 0), default: [:]][SQLiteDatabase.text($0, 1)] = QuizResult(
                    correct: Int(sqlite3_column_int64($0, 2)), total: Int(sqlite3_column_int64($0, 3)), weakSkills: skills)
            }
            return results
        }
    }

    /// Keeps the latest score of each interactive lecture. Learner data, so a republish keeps it.
    public func saveInteractiveResult(_ result: InteractiveResult, courseID: String, lectureID: String) throws {
        let skills = String(decoding: try JSONEncoder().encode(result.weakSkills), as: UTF8.self)
        try lock.withLock {
            try database.execute("""
                INSERT INTO interactive_results (course_id, lecture_id, score, weak_skills) VALUES (?, ?, ?, ?)
                ON CONFLICT(course_id, lecture_id) DO UPDATE SET score=excluded.score, weak_skills=excluded.weak_skills
                """, [courseID, lectureID, String(result.score), skills])
        }
    }

    /// The latest interactive scores by course id, then lecture id. Stores saved before schema version 7 have none.
    public func allInteractiveResults() throws -> [String: [String: InteractiveResult]] {
        try lock.withLock {
            var results: [String: [String: InteractiveResult]] = [:]
            try database.query("SELECT course_id, lecture_id, score, weak_skills FROM interactive_results") {
                guard let skills = try? JSONDecoder().decode([String].self, from: Data(SQLiteDatabase.text($0, 3).utf8)) else {
                    throw CourseStoreError.invalidData
                }
                results[SQLiteDatabase.text($0, 0), default: [:]][SQLiteDatabase.text($0, 1)] = InteractiveResult(
                    score: Int(sqlite3_column_int64($0, 2)), weakSkills: skills)
            }
            return results
        }
    }

    /// Records that the review sheet of a section opened. Learner data, so a republish keeps it.
    public func saveSectionReviewed(courseID: String, sectionID: String) throws {
        try lock.withLock {
            try database.execute("INSERT OR IGNORE INTO section_reviews (course_id, section_id) VALUES (?, ?)", [courseID, sectionID])
        }
    }

    /// The reviewed section ids by course id. Stores saved before schema version 8 have none.
    public func allReviewedSections() throws -> [String: Set<String>] {
        try lock.withLock {
            var result: [String: Set<String>] = [:]
            try database.query("SELECT course_id, section_id FROM section_reviews") {
                result[SQLiteDatabase.text($0, 0), default: []].insert(SQLiteDatabase.text($0, 1))
            }
            return result
        }
    }

    // MARK: Q&A history (#127)

    /// Saves the question with an empty pending answer before the request starts. The thread of the lecture
    /// starts with its first turn. A course that is not in the library throws, so no new thread starts for it.
    /// `origin` is the provider and the model that answer it (#150).
    public func startQATurn(question: String, sourceRevision: String, origin: AnswerOrigin, courseID: String, lectureID: String,
                            askedAt: Date = Date()) throws -> QATurn {
        try lock.withLock {
            try database.transaction {
                guard try !database.query("SELECT 1 FROM courses WHERE id = ?", [courseID], row: { _ in () }).isEmpty else {
                    throw CourseStoreError.databaseFailure
                }
                try database.execute("INSERT OR IGNORE INTO qa_threads (course_id, lecture_id) VALUES (?, ?)", [courseID, lectureID])
                let ids = try database.query("""
                    INSERT INTO qa_messages (course_id, lecture_id, question, status, source_revision, asked_at, provider_id, model_id)
                    VALUES (?, ?, ?, 'pending', ?, ?, ?, ?) RETURNING id
                    """, [courseID, lectureID, question, sourceRevision, String(askedAt.timeIntervalSince1970), origin.providerID,
                          origin.modelID]) {
                    sqlite3_column_int64($0, 0)
                }
                guard let id = ids.first else { throw CourseStoreError.databaseFailure }
                return QATurn(id: id, question: question, answer: "", status: .pending, sourceRevision: sourceRevision,
                              askedAt: Date(timeIntervalSince1970: askedAt.timeIntervalSince1970), origin: origin)
            }
        }
    }

    /// Saves the end of a pending turn: complete, cancelled or failed. One write for each answer, never one for each token.
    /// False when the turn is not pending any more, for example after Clear History or a restart.
    @discardableResult
    public func finishQATurn(id: Int64, status: QATurnStatus, answer: String) throws -> Bool {
        let (name, reason) = Self.qaStatusColumns(status)
        guard status != .pending else { throw CourseStoreError.invalidData }
        return try lock.withLock {
            try !database.query("""
                UPDATE qa_messages SET status = ?, failure_reason = ?, answer = ? WHERE id = ? AND status = 'pending' RETURNING id
                """, [name, reason, answer, String(id)]) { _ in () }.isEmpty
        }
    }

    /// The thread of a lecture, oldest turn first. Empty for a lecture with no saved turns.
    public func qaTurns(courseID: String, lectureID: String) throws -> [QATurn] {
        try lock.withLock {
            try database.query("""
                SELECT id, question, answer, status, failure_reason, source_revision, asked_at, provider_id, model_id FROM qa_messages
                WHERE course_id = ? AND lecture_id = ? ORDER BY id
                """, [courseID, lectureID]) { row in
                QATurn(id: sqlite3_column_int64(row, 0), question: SQLiteDatabase.text(row, 1), answer: SQLiteDatabase.text(row, 2),
                       status: try Self.qaStatus(SQLiteDatabase.text(row, 3), reason: SQLiteDatabase.text(row, 4)),
                       sourceRevision: SQLiteDatabase.text(row, 5), askedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 6)),
                       origin: AnswerOrigin(providerID: SQLiteDatabase.text(row, 7),
                                            modelID: sqlite3_column_type(row, 8) == SQLITE_NULL ? nil : SQLiteDatabase.text(row, 8)))
            }
        }
    }

    /// Clear History: removes the thread of one lecture and all of its turns in one transaction.
    public func clearQAHistory(courseID: String, lectureID: String) throws {
        try lock.withLock {
            try database.transaction {
                try database.execute("DELETE FROM qa_messages WHERE course_id = ? AND lecture_id = ?", [courseID, lectureID])
                try database.execute("DELETE FROM qa_threads WHERE course_id = ? AND lecture_id = ?", [courseID, lectureID])
            }
        }
    }

    /// Removes one turn of a lecture (#170). The thread stays while other turns remain. A later `finishQATurn` of the turn
    /// changes nothing, so a request that ends after the delete does not bring the turn back.
    public func removeQATurn(id: Int64, courseID: String, lectureID: String) throws {
        try lock.withLock {
            try database.transaction {
                try database.execute("DELETE FROM qa_messages WHERE id = ? AND course_id = ? AND lecture_id = ?",
                                     [String(id), courseID, lectureID])
                try database.execute("""
                    DELETE FROM qa_threads WHERE course_id = ? AND lecture_id = ?
                    AND NOT EXISTS (SELECT 1 FROM qa_messages WHERE course_id = ? AND lecture_id = ?)
                    """, [courseID, lectureID, courseID, lectureID])
            }
        }
    }

    /// Marks each pending turn as interrupted. The app calls it once at launch, before it starts a request.
    public func interruptPendingQATurns() throws {
        try lock.withLock { try database.execute("UPDATE qa_messages SET status = 'interrupted' WHERE status = 'pending'") }
    }

    private static func qaStatusColumns(_ status: QATurnStatus) -> (name: String, reason: String?) {
        switch status {
        case .pending: ("pending", nil)
        case .complete: ("complete", nil)
        case .cancelled: ("cancelled", nil)
        case .failed(let reason): ("failed", reason)
        case .interrupted: ("interrupted", nil)
        case .incomplete: ("incomplete", nil)
        case .declined: ("declined", nil)
        }
    }

    private static func qaStatus(_ name: String, reason: String) throws -> QATurnStatus {
        switch name {
        case "pending": .pending
        case "complete": .complete
        case "cancelled": .cancelled
        case "failed": .failed(reason: reason)
        case "interrupted": .interrupted
        case "incomplete": .incomplete
        case "declined": .declined
        default: throw CourseStoreError.invalidData
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
    ], [
        // The latest result of each quiz. No foreign key to `lectures`, so a republish keeps it.
        // `weak_skills` is a JSON array of objective tags.
        """
        CREATE TABLE quiz_results (
            course_id TEXT NOT NULL, lecture_id TEXT NOT NULL, correct INTEGER NOT NULL, total INTEGER NOT NULL,
            weak_skills TEXT NOT NULL DEFAULT '[]', PRIMARY KEY(course_id, lecture_id)
        )
        """,
    ], [
        // SQLite cannot change a CHECK, so the lectures table is built again with the `interactive` type.
        """
        CREATE TABLE lectures_v7 (
            course_id TEXT NOT NULL, section_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('video', 'article', 'quiz', 'assignment', 'interactive')),
            objective TEXT NOT NULL DEFAULT '', sort_order INTEGER NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('draft', 'published')), recommended_next TEXT,
            PRIMARY KEY(course_id, id),
            FOREIGN KEY(course_id, section_id) REFERENCES sections(course_id, id) ON DELETE CASCADE
        )
        """,
        """
        INSERT INTO lectures_v7 (course_id, section_id, id, title, type, objective, sort_order, state, recommended_next)
        SELECT course_id, section_id, id, title, type, objective, sort_order, state, recommended_next FROM lectures
        """,
        "DROP TABLE lectures",
        "ALTER TABLE lectures_v7 RENAME TO lectures",
        "CREATE INDEX lectures_outline ON lectures(course_id, section_id, sort_order, id)",
        // The latest score of each interactive lecture. No foreign key to `lectures`, so a republish keeps it.
        // `weak_skills` is a JSON array that holds the lecture objective when the score is weak.
        """
        CREATE TABLE interactive_results (
            course_id TEXT NOT NULL, lecture_id TEXT NOT NULL,
            score INTEGER NOT NULL CHECK(score BETWEEN 0 AND 100),
            weak_skills TEXT NOT NULL DEFAULT '[]', PRIMARY KEY(course_id, lecture_id)
        )
        """,
    ], [
        // Sections whose spaced review sheet opened. No foreign key to `sections`, so a republish keeps it.
        "CREATE TABLE section_reviews (course_id TEXT NOT NULL, section_id TEXT NOT NULL, PRIMARY KEY(course_id, section_id))",
    ], [
        // The transcript index (#18): the caption cues of each video lecture, written at publish time.
        // A course deletion removes its cues. A republish replaces them.
        """
        CREATE TABLE transcript_cues (
            course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE, lecture_id TEXT NOT NULL,
            cue_index INTEGER NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL,
            PRIMARY KEY(course_id, lecture_id, cue_index)
        )
        """,
        // Publications saved before this version have no index. The next publish writes it.
        "ALTER TABLE course_publications ADD COLUMN transcripts_indexed INTEGER NOT NULL DEFAULT 0",
    ], [
        // 1 after the learner marks a lecture incomplete by hand: the video does not complete it again (#79).
        // Progress saved before this version keeps the automatic complete on.
        "ALTER TABLE lecture_progress ADD COLUMN auto_complete_off INTEGER NOT NULL DEFAULT 0 CHECK(auto_complete_off IN (0, 1))",
    ], [
        // One Q&A thread for each lecture (#127). Like learner progress, it has no foreign key to `courses` or `lectures`.
        // A republish and a course removal keep the thread, so the history comes back when the course id is published again.
        """
        CREATE TABLE qa_threads (
            course_id TEXT NOT NULL, lecture_id TEXT NOT NULL,
            PRIMARY KEY(course_id, lecture_id)
        )
        """,
        // The turns of a thread in `id` order. `source_revision` is the lecture text revision when the learner asked.
        // `failure_reason` is the learner text of a failed turn. `asked_at` is seconds since 1970.
        """
        CREATE TABLE qa_messages (
            id INTEGER PRIMARY KEY, course_id TEXT NOT NULL, lecture_id TEXT NOT NULL,
            question TEXT NOT NULL, answer TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL CHECK(status IN ('pending', 'complete', 'cancelled', 'failed', 'interrupted')),
            failure_reason TEXT, source_revision TEXT NOT NULL, asked_at REAL NOT NULL,
            FOREIGN KEY(course_id, lecture_id) REFERENCES qa_threads(course_id, lecture_id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX qa_messages_thread ON qa_messages(course_id, lecture_id, id)",
    ], [
        // The provider and the model of each turn (#150). They are stable IDs, not display names.
        // Turns saved before this version load as the bundled local provider. A NULL model is not known.
        "ALTER TABLE qa_messages ADD COLUMN provider_id TEXT NOT NULL DEFAULT 'bundled-local'",
        "ALTER TABLE qa_messages ADD COLUMN model_id TEXT",
    ], [
        // Two more turn states (#154): 'incomplete' at the output limit and 'declined' for a model refusal.
        // SQLite can't change a CHECK, so the table is made again with the same rows and ids.
        """
        CREATE TABLE qa_messages_v13 (
            id INTEGER PRIMARY KEY, course_id TEXT NOT NULL, lecture_id TEXT NOT NULL,
            question TEXT NOT NULL, answer TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL
                CHECK(status IN ('pending', 'complete', 'cancelled', 'failed', 'interrupted', 'incomplete', 'declined')),
            failure_reason TEXT, source_revision TEXT NOT NULL, asked_at REAL NOT NULL,
            provider_id TEXT NOT NULL DEFAULT 'bundled-local', model_id TEXT,
            FOREIGN KEY(course_id, lecture_id) REFERENCES qa_threads(course_id, lecture_id) ON DELETE CASCADE
        )
        """,
        """
        INSERT INTO qa_messages_v13 (id, course_id, lecture_id, question, answer, status, failure_reason, source_revision,
                                     asked_at, provider_id, model_id)
        SELECT id, course_id, lecture_id, question, answer, status, failure_reason, source_revision, asked_at, provider_id, model_id
        FROM qa_messages
        """,
        "DROP TABLE qa_messages",
        "ALTER TABLE qa_messages_v13 RENAME TO qa_messages",
        "CREATE INDEX qa_messages_thread ON qa_messages(course_id, lecture_id, id)",
    ]]
}

/// The shared read-only store path for plan and inspect commands (#114).
/// It never creates a folder or a file, never migrates and never writes.
final class LibraryReader {
    /// The version of the database file. A file with no version table is version 0.
    let schemaVersion: Int
    private let database: SQLiteDatabase

    /// Nil when the library has no database file. A newer store throws `unsupportedSchema`.
    static func open(root: URL) throws -> LibraryReader? {
        let url = root.appending(path: CourseStore.databaseName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try LibraryReader(url: url)
    }

    private init(url: URL) throws {
        database = try SQLiteDatabase(url: url, readOnly: true)
        let tables = try database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_version'") { _ in true }
        let versions = tables.isEmpty ? []
            : try database.query("SELECT version FROM schema_version") { Int(sqlite3_column_int64($0, 0)) }
        guard versions.count <= 1 else { throw CourseStoreError.invalidData }
        let version = versions.first ?? 0
        guard version >= 0 else { throw CourseStoreError.invalidData }
        guard version <= CourseStore.migrations.count else {
            throw CourseStoreError.unsupportedSchema(found: version, supported: CourseStore.migrations.count)
        }
        schemaVersion = version
    }

    /// The installed publication of a course, read with the columns of `schemaVersion`.
    /// `hasImage` is false for a course saved before schema version 3.
    func publication(id: String) throws -> (manifest: Data, directory: String, internalDirectory: String?, hasImage: Bool)? {
        // Stores before version 2 have no publications. A column added in a later version reads as NULL.
        guard schemaVersion >= 2 else { return nil }
        let internalColumn = schemaVersion >= 4 ? "p.internal_directory" : "NULL"
        let imageColumn = schemaVersion >= 3 ? "c.image IS NOT NULL" : "0"
        return try database.query("""
            SELECT p.manifest, p.directory, \(internalColumn), \(imageColumn)
            FROM course_publications p JOIN courses c ON c.id = p.course_id WHERE p.course_id = ?
            """, [id]) {
            (Data(SQLiteDatabase.text($0, 0).utf8), SQLiteDatabase.text($0, 1),
             sqlite3_column_type($0, 2) == SQLITE_NULL ? nil : SQLiteDatabase.text($0, 2), sqlite3_column_int64($0, 3) != 0)
        }.first
    }

    /// The saved title, state and outline counts of a course. Nil for an unknown course.
    /// The visible counts use the learner rules of `CourseStore.loadCourse`: none for a draft course,
    /// and no lecture of a draft section.
    func outline(courseID: String) throws -> (title: String, state: PublicationState, sections: Int, visibleSections: Int,
                                              lectures: Int, visibleLectures: Int)? {
        try database.transaction(readOnly: true) {
            let courses = try database.query("SELECT title, state FROM courses WHERE id = ?", [courseID]) { row in
                guard let state = PublicationState(rawValue: SQLiteDatabase.text(row, 1)) else { throw CourseStoreError.invalidData }
                return (SQLiteDatabase.text(row, 0), state)
            }
            guard let (title, state) = courses.first else { return nil }
            let published = state == .published
            let sections = try database.query("""
                SELECT COUNT(*), COALESCE(SUM(state = 'published'), 0) FROM sections WHERE course_id = ?
                """, [courseID]) { (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))) }.first ?? (0, 0)
            let lectures = try database.query("""
                SELECT COUNT(*), COALESCE(SUM(l.state = 'published' AND s.state = 'published'), 0)
                FROM lectures l JOIN sections s ON s.course_id = l.course_id AND s.id = l.section_id WHERE l.course_id = ?
                """, [courseID]) { (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))) }.first ?? (0, 0)
            return (title, state, sections.0, published ? sections.1 : 0, lectures.0, published ? lectures.1 : 0)
        }
    }
}
