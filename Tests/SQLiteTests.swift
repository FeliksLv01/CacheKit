import XCTest
@testable import CacheKit

final class SQLiteTests: XCTestCase {
    func testTransactionRollsBackAfterError() throws {
        let fixture = try SQLiteFixture()
        try fixture.queue.write { database in
            try database.execute(sql: "CREATE TABLE item(value TEXT NOT NULL)")
        }

        XCTAssertThrowsError(try fixture.queue.write { database in
            try database.execute(sql: "INSERT INTO item(value) VALUES (?)", arguments: ["value"])
            throw TestError.expected
        })

        let count: Int = try fixture.queue.read { database in
            let row = try XCTUnwrap(SQLiteRow.fetchOne(database, sql: "SELECT COUNT(*) AS count FROM item"))
            return row["count"]
        }
        XCTAssertEqual(count, 0)
    }

    func testEmptyBlobRoundTripsAsBlob() throws {
        let fixture = try SQLiteFixture()
        try fixture.queue.write { database in
            try database.execute(sql: "CREATE TABLE item(value BLOB NOT NULL)")
            try database.execute(sql: "INSERT INTO item(value) VALUES (?)", arguments: [Data()])
        }

        let value: Data = try fixture.queue.read { database in
            let row = try XCTUnwrap(SQLiteRow.fetchOne(database, sql: "SELECT value FROM item"))
            return row["value"]
        }
        XCTAssertEqual(value, Data())
    }

    func testMigratorReadsExistingGRDBMigrationTable() throws {
        let fixture = try SQLiteFixture()
        try fixture.queue.write { database in
            try database.execute(sql: """
                CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations(identifier) VALUES ('existing');
                """)
        }

        var migrator = SQLiteMigrator()
        migrator.registerMigration("existing") { _ in
            XCTFail("An existing GRDB migration must not run again")
        }
        migrator.registerMigration("new") { database in
            try database.execute(sql: "CREATE TABLE migrated(value INTEGER NOT NULL)")
        }
        try migrator.migrate(fixture.queue)

        let identifiers: [String] = try fixture.queue.read { database in
            try SQLiteRow.fetchAll(
                database,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
            ).map { $0["identifier"] }
        }
        XCTAssertEqual(identifiers, ["existing", "new"])
    }

    func testPoolReadKeepsOneSnapshotAcrossStatements() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var configuration = SQLiteConfiguration()
        configuration.journalMode = .wal
        let pool = try SQLiteDatabasePool(
            path: directoryURL.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        try pool.write { database in
            try database.execute(sql: "CREATE TABLE item(value INTEGER NOT NULL)")
            try database.execute(sql: "INSERT INTO item(value) VALUES (1)")
        }

        let writerFinished = DispatchSemaphore(value: 0)
        let values: [Int] = try pool.read { database in
            let first: Int = try XCTUnwrap(
                SQLiteRow.fetchOne(database, sql: "SELECT value FROM item")?["value"]
            )
            DispatchQueue.global().async {
                try? pool.write { database in
                    try database.execute(sql: "UPDATE item SET value = 2")
                }
                writerFinished.signal()
            }
            XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
            let second: Int = try XCTUnwrap(
                SQLiteRow.fetchOne(database, sql: "SELECT value FROM item")?["value"]
            )
            return [first, second]
        }

        XCTAssertEqual(values, [1, 1])
        let current: Int = try pool.read { database in
            try XCTUnwrap(SQLiteRow.fetchOne(database, sql: "SELECT value FROM item")?["value"])
        }
        XCTAssertEqual(current, 2)
    }
}

private final class SQLiteFixture {
    let directoryURL: URL
    let queue: SQLiteDatabaseQueue

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        queue = try SQLiteDatabaseQueue(path: directoryURL.appendingPathComponent("test.sqlite").path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private enum TestError: Error {
    case expected
}
