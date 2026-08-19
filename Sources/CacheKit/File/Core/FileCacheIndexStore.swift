import Foundation

final class FileCacheIndexStore {
    private let databaseQueue: SQLiteDatabaseQueue

    init(directoryURL: URL) throws {
        var configuration = SQLiteConfiguration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        databaseQueue = try SQLiteDatabaseQueue(
            path: directoryURL.appendingPathComponent("cache.sqlite").path,
            configuration: configuration
        )

        var migrator = SQLiteMigrator()
        migrator.registerMigration("createFileCacheIndex") { database in
            try database.execute(sql: """
                CREATE TABLE cache_entry (
                    identifier TEXT PRIMARY KEY NOT NULL,
                    file_name TEXT NOT NULL UNIQUE,
                    file_size INTEGER NOT NULL,
                    last_access_at REAL NOT NULL
                );

                CREATE TABLE cache_alias (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    identifier TEXT NOT NULL REFERENCES cache_entry(identifier) ON DELETE CASCADE
                );

                CREATE INDEX cache_entry_lru ON cache_entry(last_access_at);
                CREATE INDEX cache_alias_identifier ON cache_alias(identifier);
                """)
        }
        try migrator.migrate(databaseQueue)
    }

    func allEntries() throws -> [FileCacheEntry] {
        try databaseQueue.read { database in
            try SQLiteRow.fetchAll(database, sql: """
                SELECT identifier, file_name, file_size, last_access_at
                FROM cache_entry
                """).map(Self.entry(from:))
        }
    }

    func entry(forAny keys: Set<String>) throws -> FileCacheEntry? {
        guard !keys.isEmpty else { return nil }
        return try databaseQueue.read { database in
            try fetchEntry(database: database, keys: keys)
        }
    }

    func upsert(entry: FileCacheEntry, keys: Set<String>) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO cache_entry(identifier, file_name, file_size, last_access_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(identifier) DO UPDATE SET
                        file_name = excluded.file_name,
                        file_size = excluded.file_size,
                        last_access_at = excluded.last_access_at
                    """,
                arguments: [entry.identifier, entry.fileName, entry.size, entry.lastAccessTime]
            )
            try upsertAliases(keys, identifier: entry.identifier, database: database)
        }
    }

    func touch(identifier: String, keys: Set<String>, at timestamp: TimeInterval) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: "UPDATE cache_entry SET last_access_at = ? WHERE identifier = ?",
                arguments: [timestamp, identifier]
            )
            try upsertAliases(keys, identifier: identifier, database: database)
        }
    }

    func bind(keys: Set<String>, toAnyExistingKey existingKeys: Set<String>, at timestamp: TimeInterval) throws -> FileCacheEntry? {
        guard !keys.isEmpty, !existingKeys.isEmpty else { return nil }
        return try databaseQueue.write { database in
            guard var entry = try fetchEntry(database: database, keys: existingKeys) else {
                return nil
            }
            try database.execute(
                sql: "UPDATE cache_entry SET last_access_at = ? WHERE identifier = ?",
                arguments: [timestamp, entry.identifier]
            )
            try upsertAliases(keys, identifier: entry.identifier, database: database)
            entry.lastAccessTime = timestamp
            return entry
        }
    }

    func remove(identifier: String) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: "DELETE FROM cache_entry WHERE identifier = ?",
                arguments: [identifier]
            )
        }
    }

    private func fetchEntry(database: SQLiteDatabase, keys: Set<String>) throws -> FileCacheEntry? {
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        guard let row = try SQLiteRow.fetchOne(
            database,
            sql: """
                SELECT entry.identifier, entry.file_name, entry.file_size, entry.last_access_at
                FROM cache_alias AS alias
                JOIN cache_entry AS entry ON entry.identifier = alias.identifier
                WHERE alias.cache_key IN (\(placeholders))
                LIMIT 1
                """,
            arguments: SQLiteStatementArguments(Array(keys))
        ) else {
            return nil
        }
        return Self.entry(from: row)
    }

    private func upsertAliases(_ keys: Set<String>, identifier: String, database: SQLiteDatabase) throws {
        for key in keys {
            try database.execute(
                sql: """
                    INSERT INTO cache_alias(cache_key, identifier)
                    VALUES (?, ?)
                    ON CONFLICT(cache_key) DO UPDATE SET identifier = excluded.identifier
                    """,
                arguments: [key, identifier]
            )
        }
    }

    private static func entry(from row: SQLiteRow) -> FileCacheEntry {
        FileCacheEntry(
            identifier: row["identifier"],
            fileName: row["file_name"],
            size: row["file_size"],
            lastAccessTime: row["last_access_at"]
        )
    }
}
