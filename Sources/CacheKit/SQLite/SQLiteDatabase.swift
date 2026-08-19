import Foundation
import SQLite3

struct SQLiteConfiguration {
    enum JournalMode: String {
        case delete = "DELETE"
        case wal = "WAL"
    }

    enum BusyMode {
        case immediateError
        case timeout(TimeInterval)
    }

    var journalMode: JournalMode = .delete
    var busyMode: BusyMode = .immediateError
    var maximumReaderCount = 5
    fileprivate var preparations: [(SQLiteDatabase) throws -> Void] = []

    mutating func prepareDatabase(_ preparation: @escaping (SQLiteDatabase) throws -> Void) {
        preparations.append(preparation)
    }
}

final class SQLiteDatabase {
    let pointer: OpaquePointer
    private var statementCache: [String: SQLiteStatement] = [:]

    init(path: String, configuration: SQLiteConfiguration) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let connection {
                sqlite3_close(connection)
            }
            throw SQLiteError(code: result, message: message, sql: nil)
        }
        pointer = connection

        do {
            switch configuration.busyMode {
            case .immediateError:
                sqlite3_busy_timeout(connection, 0)
            case .timeout(let duration):
                sqlite3_busy_timeout(connection, Int32(max(0, duration * 1_000)))
            }
            try execute(sql: "PRAGMA journal_mode = \(configuration.journalMode.rawValue)")
            for preparation in configuration.preparations {
                try preparation(self)
            }
        } catch {
            throw error
        }
    }

    deinit {
        statementCache.removeAll()
        sqlite3_close(pointer)
    }

    func execute(sql: String, arguments: SQLiteStatementArguments = []) throws {
        if arguments.values.isEmpty {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(pointer, sql, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(pointer))
                sqlite3_free(errorMessage)
                throw SQLiteError(code: result, message: message, sql: sql)
            }
            return
        }
        try cachedStatement(sql: sql).execute(arguments: arguments)
    }

    func cachedStatement(sql: String) throws -> SQLiteStatement {
        if let statement = statementCache[sql] {
            return statement
        }
        let statement = try SQLiteStatement(database: self, sql: sql)
        statementCache[sql] = statement
        return statement
    }

    func fetchDouble(sql: String, arguments: SQLiteStatementArguments = []) throws -> Double? {
        guard let row = try SQLiteRow.fetchOne(self, sql: sql, arguments: arguments) else { return nil }
        return row.value(at: 0)
    }

    func transaction<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result {
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try body(self)
            try execute(sql: "COMMIT")
            return result
        } catch {
            try? execute(sql: "ROLLBACK")
            throw error
        }
    }

    func readTransaction<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result {
        try execute(sql: "BEGIN DEFERRED TRANSACTION")
        do {
            let result = try body(self)
            try execute(sql: "COMMIT")
            return result
        } catch {
            try? execute(sql: "ROLLBACK")
            throw error
        }
    }

    func error(code: Int32, sql: String? = nil) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(pointer)), sql: sql)
    }
}
