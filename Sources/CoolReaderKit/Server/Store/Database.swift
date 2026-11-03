import CSQLite
import Foundation

/// A value bound to or read from SQLite.
nonisolated enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

nonisolated protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { nonisolated var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLBindable { nonisolated var sqlValue: SQLValue { .integer(self) } }
extension Double: SQLBindable { nonisolated var sqlValue: SQLValue { .real(self) } }
extension Bool: SQLBindable { nonisolated var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension String: SQLBindable { nonisolated var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { nonisolated var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { nonisolated var sqlValue: SQLValue { .real(timeIntervalSince1970) } }

/// A row, by column name.
nonisolated struct Row: Sendable {
    let values: [String: SQLValue]

    func int(_ column: String) -> Int? {
        switch values[column] {
        case .integer(let value): Int(value)
        case .real(let value): Int(value)
        default: nil
        }
    }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .integer(let value): Double(value)
        case .real(let value): value
        default: nil
        }
    }

    func string(_ column: String) -> String? {
        if case .text(let value) = values[column] { return value }
        return nil
    }

    func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }

    func date(_ column: String) -> Date? { double(column).map(Date.init(timeIntervalSince1970:)) }

    func json<T: Decodable>(_ column: String, as type: T.Type) -> T? {
        string(column).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
}

nonisolated struct DatabaseError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// SQLite in write-ahead-log mode. Calls are serialised by a lock: they are short, and SQLite works best with
/// one writer.
nonisolated final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError(message: "Can't open the database at \(path).")
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close_v2(handle) }

    @discardableResult
    func execute(_ sql: String, _ arguments: [(any SQLBindable)?] = []) throws -> Int {
        try locked {
            try run(sql, arguments) { _ in }
            return Int(sqlite3_changes(handle))
        }
    }

    func insert(_ sql: String, _ arguments: [(any SQLBindable)?] = []) throws -> Int {
        try locked {
            try run(sql, arguments) { _ in }
            return Int(sqlite3_last_insert_rowid(handle))
        }
    }

    func query(_ sql: String, _ arguments: [(any SQLBindable)?] = []) throws -> [Row] {
        try locked {
            var rows: [Row] = []
            try run(sql, arguments) { rows.append($0) }
            return rows
        }
    }

    func first(_ sql: String, _ arguments: [(any SQLBindable)?] = []) throws -> Row? {
        try query(sql, arguments).first
    }

    /// Several statements as one: all or nothing.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try run("BEGIN IMMEDIATE", []) { _ in }
            do {
                let result = try body()
                try run("COMMIT", []) { _ in }
                return result
            } catch {
                try? run("ROLLBACK", []) { _ in }
                throw error
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func run(_ sql: String, _ arguments: [(any SQLBindable)?], row: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(sql) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument?.sqlValue ?? .null {
            case .null: sqlite3_bind_null(statement, position)
            case .integer(let value): sqlite3_bind_int64(statement, position, value)
            case .real(let value): sqlite3_bind_double(statement, position, value)
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, transient)
            case .blob(let value):
                value.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(statement, position, raw.baseAddress, Int32(raw.count), transient)
                }
            }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw lastError(sql) }
            var values: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    values[name] = .blob(count > 0 ? Data(bytes: sqlite3_column_blob(statement, column), count: count) : Data())
                default: values[name] = .null
                }
            }
            row(Row(values: values))
        }
    }

    private func lastError(_ sql: String) -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)) + " (\(sql.prefix(80)))")
    }
}
