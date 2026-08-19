import Foundation

protocol SQLiteWriter {
    func write<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result
}

final class SQLiteDatabasePool: SQLiteWriter, @unchecked Sendable {
    private struct Reader {
        let queue: DispatchQueue
        let database: SQLiteDatabase
    }

    private let writerQueue: DispatchQueue
    private let writerDatabase: SQLiteDatabase
    private let readers: [Reader]
    private let readerLock = UnfairLock()
    private var nextReaderIndex = 0

    init(path: String, configuration: SQLiteConfiguration = SQLiteConfiguration()) throws {
        writerQueue = DispatchQueue(label: "com.cachekit.sqlite.writer")
        writerDatabase = try SQLiteDatabase(path: path, configuration: configuration)
        var readers: [Reader] = []
        readers.reserveCapacity(max(1, configuration.maximumReaderCount))
        for index in 0 ..< max(1, configuration.maximumReaderCount) {
            readers.append(Reader(
                queue: DispatchQueue(label: "com.cachekit.sqlite.reader.\(index)"),
                database: try SQLiteDatabase(path: path, configuration: configuration)
            ))
        }
        self.readers = readers
    }

    func read<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result {
        let reader = readerLock.withLock {
            let reader = readers[nextReaderIndex]
            nextReaderIndex = (nextReaderIndex + 1) % readers.count
            return reader
        }
        return try reader.queue.sync {
            try reader.database.readTransaction(body)
        }
    }

    func write<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result {
        try writerQueue.sync {
            try writerDatabase.transaction(body)
        }
    }

    func writeWithoutTransaction<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result {
        try writerQueue.sync {
            try body(writerDatabase)
        }
    }
}

final class SQLiteDatabaseQueue: SQLiteWriter {
    private let queue = DispatchQueue(label: "com.cachekit.sqlite.queue")
    private let database: SQLiteDatabase

    init(path: String, configuration: SQLiteConfiguration = SQLiteConfiguration()) throws {
        database = try SQLiteDatabase(path: path, configuration: configuration)
    }

    func read<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result {
        try queue.sync {
            try body(database)
        }
    }

    func write<Result>(_ body: (SQLiteDatabase) throws -> Result) throws -> Result {
        try queue.sync {
            try database.transaction(body)
        }
    }
}
