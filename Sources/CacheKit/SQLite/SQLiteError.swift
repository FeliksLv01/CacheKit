import Foundation

struct SQLiteError: Error, CustomStringConvertible, Sendable {
    let code: Int32
    let message: String
    let sql: String?

    var description: String {
        if let sql {
            return "SQLite error \(code): \(message), SQL: \(sql)"
        }
        return "SQLite error \(code): \(message)"
    }
}
