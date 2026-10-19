import Foundation
import SQLite3
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private let busyText = "The library is busy. Another process held a write lock for more than 5 seconds."
private let lockedText = "The library database is locked by another operation."
private let hint = "Wait until the Skillgarden app or the other skillgarden command stops saving. Then run the command again."

/// Gives each test a copy of the sample course and a library that holds the published course.
private func withLibrary(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenLockTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    let root = base.appending(path: "library")
    _ = try CoursePublisher.publish(courseFolder: folder, root: root)
    try body(folder, root)
}

/// Another connection, like the app or a second CLI run, that holds a write transaction until `release`.
private final class WriteLock {
    private var handle: OpaquePointer?

    init(root: URL) throws {
        guard sqlite3_open_v2(root.appending(path: "library.sqlite").path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw CourseStoreError.cannotOpen
        }
    }

    func release() {
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        handle = nil
    }

    deinit { if handle != nil { release() } }
}

@Test func busyAndLockedErrorsHaveTheirOwnText() {
    #expect(CourseStoreError.busy.errorDescription == busyText)
    #expect(CourseStoreError.locked.errorDescription == lockedText)
    #expect(CourseStoreError.databaseFailure.errorDescription == "The library could not read or save its data.")
}

@Test func sqliteResultCodesMapToStoreErrors() {
    #expect(SQLiteDatabase.error(SQLITE_BUSY) == .busy)
    #expect(SQLiteDatabase.error(SQLITE_BUSY | (2 << 8)) == .busy) // SQLITE_BUSY_SNAPSHOT
    #expect(SQLiteDatabase.error(SQLITE_LOCKED) == .locked)
    #expect(SQLiteDatabase.error(SQLITE_LOCKED | (1 << 8)) == .locked) // SQLITE_LOCKED_SHAREDCACHE
    #expect(SQLiteDatabase.error(SQLITE_ERROR) == .databaseFailure)
    #expect(SQLiteDatabase.error(SQLITE_CORRUPT) == .databaseFailure)
}

@Test func heldWriteLockGivesBusyAndPublishWorksAfterRelease() throws {
    try withLibrary { folder, root in
        let lock = try WriteLock(root: root)
        let start = Date()
        #expect(throws: CourseStoreError.busy) { try CoursePublisher.publish(courseFolder: folder, root: root) }
        // The bounded 5-second wait stays. The CLI does not retry.
        let waited = Date().timeIntervalSince(start)
        #expect(waited >= 4.5 && waited < 15)
        lock.release()
        let result = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(result.id == "sample-course")
    }
}

@Test func busyCLITextHasHintAndLibraryLine() throws {
    try withLibrary { folder, root in
        let lock = try WriteLock(root: root)
        let result = SkillgardenCommand.run(arguments: ["publish", folder.path], root: root)
        #expect(result.exitCode == 3)
        #expect(result.stdout == "")
        #expect(result.stderr == "error: \(busyText)\nhint: \(hint)\nLibrary: \(root.path)\n")
        #expect(!result.stderr.contains("could not read or save its data"))
        lock.release()
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root).exitCode == 0)
    }
}

@Test func busyJSONHasCodeHintAndLibraryPath() throws {
    try withLibrary { folder, root in
        let lock = try WriteLock(root: root)
        let result = SkillgardenCommand.run(arguments: ["publish", folder.path, "--json"], root: root)
        lock.release()
        #expect(result.exitCode == 3)
        #expect(result.stderr == "")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        let diagnostic = try #require((object["diagnostics"] as? [[String: Any]])?.first)
        #expect(diagnostic["code"] as? String == "library.busy")
        #expect(diagnostic["message"] as? String == busyText)
        #expect(diagnostic["hint"] as? String == hint)
        #expect(diagnostic["library_path"] as? String == root.path)
    }
}

@Test func lockedTableGivesLocked() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenLockTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let database = try SQLiteDatabase(url: base.appending(path: "test.sqlite"))
    try database.execute("CREATE TABLE t (a TEXT)")
    try database.execute("INSERT INTO t VALUES ('a'), ('b')")
    // SQLite does not drop a table while a statement of the same connection reads it.
    #expect(throws: CourseStoreError.locked) {
        try database.query("SELECT a FROM t") { _ in try database.execute("DROP TABLE t") }
    }
}

@Test func lockedCLITextHasHintAndLibraryLine() {
    let root = URL(fileURLWithPath: "/tmp/library")
    let outcome = SkillgardenCommand.failureStderr(CourseStoreError.locked, root: root)
    #expect(outcome == "error: \(lockedText)\nhint: \(hint)\nLibrary: /tmp/library\n")
}

@Test func otherStoreErrorsKeepTheirText() throws {
    try withLibrary { folder, root in
        try Data("not a database".utf8).write(to: root.appending(path: "library.sqlite"))
        let result = SkillgardenCommand.run(arguments: ["publish", folder.path], root: root)
        #expect(result.exitCode == 3)
        #expect(!result.stderr.contains("busy"))
        #expect(!result.stderr.contains("hint:"))
        #expect(!result.stderr.contains("Library:"))
    }
}
