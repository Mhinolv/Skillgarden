import Foundation
import SQLite3

public enum CourseStoreError: Error, LocalizedError, Equatable {
    case cannotOpen
    case databaseFailure
    case invalidData
    case unsupportedSchema(found: Int, supported: Int)
    /// `SQLITE_BUSY`: another connection held a write lock for longer than the busy timeout (#117).
    case busy
    /// `SQLITE_LOCKED`: a conflict inside the same connection or shared cache (#117).
    case locked

    public var errorDescription: String? {
        switch self {
        case .cannotOpen: "The library could not open its database."
        case .databaseFailure: "The library could not read or save its data."
        case .invalidData: "The library contains invalid course data."
        case let .unsupportedSchema(found, supported):
            "The library uses schema version \(found), but this app supports version \(supported)."
        case .busy: "The library is busy. Another process held a write lock for more than 5 seconds."
        case .locked: "The library database is locked by another operation."
        }
    }
}

/// CourseStore serializes all access to this connection with its lock.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// `readOnly` opens a database file that exists and never creates or changes a file.
    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw CourseStoreError.cannotOpen
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [String?] = []) throws {
        try query(sql, values) { _ in () }
    }

    @discardableResult
    func query<T>(_ sql: String, _ values: [String?] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw Self.error(prepared) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let result: Int32
            if let value {
                result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), transient) }
            } else {
                result = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard result == SQLITE_OK else { throw CourseStoreError.databaseFailure }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try row(statement))
            case SQLITE_DONE: return rows
            case let result: throw Self.error(result)
            }
        }
    }

    func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        try execute(readOnly ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Keeps busy and locked results apart from other failures. The low byte of an extended code is its primary code.
    static func error(_ result: Int32) -> CourseStoreError {
        switch result & 0xFF {
        case SQLITE_BUSY: .busy
        case SQLITE_LOCKED: .locked
        default: .databaseFailure
        }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(row, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }
}
