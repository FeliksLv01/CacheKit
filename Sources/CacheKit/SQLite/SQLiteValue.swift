import Foundation
import SQLite3

enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

struct SQLiteStatementArguments: ExpressibleByArrayLiteral {
    let values: [Any?]

    init(arrayLiteral elements: Any?...) {
        values = elements
    }

    init<Values: Sequence>(_ values: Values) {
        self.values = values.map { $0 }
    }
}

protocol SQLiteValueConvertible {
    static func decodeSQLiteValue(_ value: SQLiteValue) -> Self?
}

extension Optional: SQLiteValueConvertible where Wrapped: SQLiteValueConvertible {
    static func decodeSQLiteValue(_ value: SQLiteValue) -> Optional<Wrapped>? {
        switch value {
        case .null:
            return .some(nil)
        default:
            guard let value = Wrapped.decodeSQLiteValue(value) else { return nil }
            return .some(value)
        }
    }
}

extension String: SQLiteValueConvertible {
    static func decodeSQLiteValue(_ value: SQLiteValue) -> String? {
        guard case .text(let value) = value else { return nil }
        return value
    }
}

extension Data: SQLiteValueConvertible {
    static func decodeSQLiteValue(_ value: SQLiteValue) -> Data? {
        guard case .blob(let value) = value else { return nil }
        return value
    }
}

extension Int: SQLiteValueConvertible {
    static func decodeSQLiteValue(_ value: SQLiteValue) -> Int? {
        guard case .integer(let value) = value else { return nil }
        return Int(exactly: value)
    }
}

extension Int64: SQLiteValueConvertible {
    static func decodeSQLiteValue(_ value: SQLiteValue) -> Int64? {
        guard case .integer(let value) = value else { return nil }
        return value
    }
}

extension Double: SQLiteValueConvertible {
    static func decodeSQLiteValue(_ value: SQLiteValue) -> Double? {
        switch value {
        case .integer(let value):
            return Double(value)
        case .real(let value):
            return value
        default:
            return nil
        }
    }
}

struct SQLiteRow: Sendable {
    private let valuesByName: [String: SQLiteValue]
    private let values: [SQLiteValue]

    init(statement: OpaquePointer) {
        let columnCount = sqlite3_column_count(statement)
        var valuesByName: [String: SQLiteValue] = [:]
        var values: [SQLiteValue] = []
        values.reserveCapacity(Int(columnCount))

        for index in 0 ..< columnCount {
            let value = Self.value(statement: statement, index: index)
            values.append(value)
            if let name = sqlite3_column_name(statement, index) {
                let columnName = String(cString: name)
                valuesByName[columnName] = value
                valuesByName[columnName.lowercased()] = value
            }
        }
        self.valuesByName = valuesByName
        self.values = values
    }

    subscript<Value: SQLiteValueConvertible>(_ column: String) -> Value {
        guard let value = valuesByName[column] ?? valuesByName[column.lowercased()],
              let decoded = Value.decodeSQLiteValue(value) else {
            preconditionFailure("Unable to decode SQLite column: \(column)")
        }
        return decoded
    }

    func value<Value: SQLiteValueConvertible>(at index: Int, as type: Value.Type = Value.self) -> Value? {
        guard values.indices.contains(index) else { return nil }
        return Value.decodeSQLiteValue(values[index])
    }

    private static func value(statement: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0 else { return .blob(Data()) }
            guard let bytes = sqlite3_column_blob(statement, index) else { return .null }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}

