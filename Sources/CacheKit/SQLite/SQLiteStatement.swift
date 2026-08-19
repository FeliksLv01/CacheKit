import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStatement {
    private unowned let database: SQLiteDatabase
    private let pointer: OpaquePointer
    let sql: String

    init(database: SQLiteDatabase, sql: String) throws {
        self.database = database
        self.sql = sql
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database.pointer, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw database.error(code: result, sql: sql)
        }
        pointer = statement
    }

    deinit {
        sqlite3_finalize(pointer)
    }

    func execute(arguments: SQLiteStatementArguments = []) throws {
        try withBoundArguments(arguments) {
            let result = sqlite3_step(pointer)
            guard result == SQLITE_DONE else {
                throw database.error(code: result, sql: sql)
            }
        }
    }

    func fetchOne(arguments: SQLiteStatementArguments = []) throws -> SQLiteRow? {
        try withBoundArguments(arguments) {
            let result = sqlite3_step(pointer)
            switch result {
            case SQLITE_ROW:
                return SQLiteRow(statement: pointer)
            case SQLITE_DONE:
                return nil
            default:
                throw database.error(code: result, sql: sql)
            }
        }
    }

    func fetchAll(arguments: SQLiteStatementArguments = []) throws -> [SQLiteRow] {
        try withBoundArguments(arguments) {
            var rows: [SQLiteRow] = []
            while true {
                let result = sqlite3_step(pointer)
                switch result {
                case SQLITE_ROW:
                    rows.append(SQLiteRow(statement: pointer))
                case SQLITE_DONE:
                    return rows
                default:
                    throw database.error(code: result, sql: sql)
                }
            }
        }
    }

    private func withBoundArguments<Result>(
        _ arguments: SQLiteStatementArguments,
        body: () throws -> Result
    ) throws -> Result {
        sqlite3_reset(pointer)
        sqlite3_clear_bindings(pointer)
        defer {
            sqlite3_reset(pointer)
            sqlite3_clear_bindings(pointer)
        }
        try bind(arguments)
        return try body()
    }

    private func bind(_ arguments: SQLiteStatementArguments) throws {
        let expectedCount = Int(sqlite3_bind_parameter_count(pointer))
        guard arguments.values.count == expectedCount else {
            throw SQLiteError(
                code: SQLITE_MISUSE,
                message: "Expected \(expectedCount) arguments, received \(arguments.values.count)",
                sql: sql
            )
        }
        for (offset, value) in arguments.values.enumerated() {
            let index = Int32(offset + 1)
            let result = bind(value, at: index)
            guard result == SQLITE_OK else {
                throw database.error(code: result, sql: sql)
            }
        }
    }

    private func bind(_ value: Any?, at index: Int32) -> Int32 {
        guard let value = unwrap(value) else {
            return sqlite3_bind_null(pointer, index)
        }
        switch value {
        case let value as String:
            return sqlite3_bind_text(pointer, index, value, -1, sqliteTransient)
        case let value as Data:
            if value.isEmpty {
                return sqlite3_bind_zeroblob(pointer, index, 0)
            }
            return value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(pointer, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
        case let value as Bool:
            return sqlite3_bind_int64(pointer, index, value ? 1 : 0)
        case let value as Int:
            return sqlite3_bind_int64(pointer, index, Int64(value))
        case let value as Int8:
            return sqlite3_bind_int64(pointer, index, Int64(value))
        case let value as Int16:
            return sqlite3_bind_int64(pointer, index, Int64(value))
        case let value as Int32:
            return sqlite3_bind_int64(pointer, index, Int64(value))
        case let value as Int64:
            return sqlite3_bind_int64(pointer, index, value)
        case let value as UInt:
            guard let converted = Int64(exactly: value) else { return SQLITE_RANGE }
            return sqlite3_bind_int64(pointer, index, converted)
        case let value as UInt8:
            return sqlite3_bind_int64(pointer, index, Int64(value))
        case let value as UInt16:
            return sqlite3_bind_int64(pointer, index, Int64(value))
        case let value as UInt32:
            return sqlite3_bind_int64(pointer, index, Int64(value))
        case let value as UInt64:
            guard let converted = Int64(exactly: value) else { return SQLITE_RANGE }
            return sqlite3_bind_int64(pointer, index, converted)
        case let value as Double:
            return sqlite3_bind_double(pointer, index, value)
        case let value as Float:
            return sqlite3_bind_double(pointer, index, Double(value))
        default:
            return SQLITE_MISMATCH
        }
    }

    private func unwrap(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }
}

extension SQLiteRow {
    static func fetchOne(
        _ database: SQLiteDatabase,
        sql: String,
        arguments: SQLiteStatementArguments = []
    ) throws -> SQLiteRow? {
        try database.cachedStatement(sql: sql).fetchOne(arguments: arguments)
    }

    static func fetchOne(
        _ statement: SQLiteStatement,
        arguments: SQLiteStatementArguments = []
    ) throws -> SQLiteRow? {
        try statement.fetchOne(arguments: arguments)
    }

    static func fetchAll(
        _ database: SQLiteDatabase,
        sql: String,
        arguments: SQLiteStatementArguments = []
    ) throws -> [SQLiteRow] {
        try database.cachedStatement(sql: sql).fetchAll(arguments: arguments)
    }

    static func fetchAll(
        _ statement: SQLiteStatement,
        arguments: SQLiteStatementArguments = []
    ) throws -> [SQLiteRow] {
        try statement.fetchAll(arguments: arguments)
    }
}
