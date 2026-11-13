import Foundation
import SQLite3

struct SQLiteFailure: Error, Sendable {
    let code: Int32
    let message: String
}

enum SQLiteValue {
    case text(String)
    case blob(Data)
    case integer(Int64)
    case real(Double)
    case null
}

final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        var database: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite database"
            if let database { sqlite3_close_v2(database) }
            throw SQLiteFailure(code: result, message: message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = DELETE")
        try execute("PRAGMA synchronous = FULL")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    @discardableResult
    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int32 {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure(result) }
        return sqlite3_changes(handle)
    }

    func rows<T>(_ sql: String, bindings: [SQLiteValue] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure(status) }
            result.append(try map(statement))
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle else { throw SQLiteFailure(code: SQLITE_MISUSE, message: "Database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure(result) }
        do {
            for (offset, value) in bindings.enumerated() {
                try bind(value, to: Int32(offset + 1), statement: statement)
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func bind(_ value: SQLiteValue, to index: Int32, statement: OpaquePointer) throws {
        let result: Int32
        switch value {
        case .text(let string):
            result = string.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        case .blob(let data):
            if data.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
            else {
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
        case .integer(let integer):
            result = sqlite3_bind_int64(statement, index, integer)
        case .real(let real):
            result = sqlite3_bind_double(statement, index, real)
        case .null:
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw failure(result) }
    }

    private func failure(_ code: Int32) -> SQLiteFailure {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        return SQLiteFailure(code: code, message: message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func sqliteText(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: value)
}

func sqliteBlob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count >= 0 else { return nil }
    if count == 0 { return Data() }
    guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
    return Data(bytes: bytes, count: count)
}
