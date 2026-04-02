import Foundation
import SQLite3
import os

enum SQLiteValue: Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null

    var textValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    var intValue: Int64? {
        if case .integer(let v) = self { return v }
        return nil
    }

    var realValue: Double? {
        if case .real(let v) = self { return v }
        return nil
    }
}

typealias SQLiteRow = [String: SQLiteValue]

final class DatabaseManager {
    private var db: OpaquePointer?
    private let logger = Logger.database

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.openFailed(msg)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        logger.info("Database opened at \(path)")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func execute(_ sql: String, params: [SQLiteValue] = []) throws {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw DatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        try bind(stmt: stmt!, params: params)

        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
            throw DatabaseError.executeFailed(errorMessage)
        }
    }

    func query(_ sql: String, params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw DatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        try bind(stmt: stmt!, params: params)

        var rows: [SQLiteRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: SQLiteRow = [:]
            let columnCount = sqlite3_column_count(stmt)
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let value = readColumn(stmt: stmt!, index: i)
                row[name] = value
            }
            rows.append(row)
        }
        return rows
    }

    func userVersion() throws -> Int {
        let rows = try query("PRAGMA user_version")
        guard let row = rows.first, let version = row["user_version"]?.intValue else {
            return 0
        }
        return Int(version)
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: - Private helpers

    private var errorMessage: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func bind(stmt: OpaquePointer, params: [SQLiteValue]) throws {
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            let result: Int32
            switch param {
            case .text(let v):
                result = sqlite3_bind_text(stmt, i, (v as NSString).utf8String, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .integer(let v):
                result = sqlite3_bind_int64(stmt, i, v)
            case .real(let v):
                result = sqlite3_bind_double(stmt, i, v)
            case .blob(let v):
                result = v.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, i, ptr.baseAddress, Int32(v.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .null:
                result = sqlite3_bind_null(stmt, i)
            }
            guard result == SQLITE_OK else {
                throw DatabaseError.bindFailed(errorMessage)
            }
        }
    }

    private func readColumn(stmt: OpaquePointer, index: Int32) -> SQLiteValue {
        let columnType = sqlite3_column_type(stmt, index)
        switch columnType {
        case SQLITE_TEXT:
            let text = String(cString: sqlite3_column_text(stmt, index))
            return .text(text)
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            if let bytes = sqlite3_column_blob(stmt, index) {
                return .blob(Data(bytes: bytes, count: byteCount))
            }
            return .blob(Data())
        case SQLITE_NULL:
            return .null
        default:
            return .null
        }
    }
}

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case bindFailed(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "Database open failed: \(m)"
        case .prepareFailed(let m): return "SQL prepare failed: \(m)"
        case .executeFailed(let m): return "SQL execute failed: \(m)"
        case .bindFailed(let m): return "SQL bind failed: \(m)"
        case .migrationFailed(let m): return "Migration failed: \(m)"
        }
    }
}
