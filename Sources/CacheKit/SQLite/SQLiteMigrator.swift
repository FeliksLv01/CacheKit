import Foundation

struct SQLiteMigrator {
    private struct Migration {
        let identifier: String
        let migrate: (SQLiteDatabase) throws -> Void
    }

    private var migrations: [Migration] = []

    mutating func registerMigration(
        _ identifier: String,
        migrate: @escaping (SQLiteDatabase) throws -> Void
    ) {
        precondition(!migrations.contains { $0.identifier == identifier }, "Duplicate migration: \(identifier)")
        migrations.append(Migration(identifier: identifier, migrate: migrate))
    }

    func migrate(_ writer: SQLiteWriter) throws {
        for migration in migrations {
            try writer.write { database in
                try database.execute(sql: """
                    CREATE TABLE IF NOT EXISTS grdb_migrations (
                        identifier TEXT NOT NULL PRIMARY KEY
                    )
                    """)
                let isApplied = try SQLiteRow.fetchOne(
                    database,
                    sql: "SELECT 1 FROM grdb_migrations WHERE identifier = ?",
                    arguments: [migration.identifier]
                ) != nil
                guard !isApplied else { return }
                try migration.migrate(database)
                try database.execute(
                    sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
                    arguments: [migration.identifier]
                )
            }
        }
    }
}
