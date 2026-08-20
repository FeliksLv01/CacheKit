import Foundation

final class DiskStorage: @unchecked Sendable {
    struct ValueToStore: Sendable {
        let key: String
        let data: Data
        let expirationDate: Date?
    }

    struct StoredValue: Sendable {
        let data: Data
        let expirationDate: Date?
    }

    private struct Item: Sendable {
        let generation: String
        let fileName: String?
        let inlineData: Data?
        let expirationTimestamp: TimeInterval?
    }

    private struct Touch: Sendable {
        let generation: String
        let timestamp: TimeInterval
    }

    private struct Victim: Sendable {
        let key: String
        let fileName: String?
    }

    private struct PreparedValue: Sendable {
        let key: String
        let data: Data
        let expirationDate: Date?
        let generation: String
        let fileName: String?
        let inlineData: Data?
    }

    private let databasePool: SQLiteDatabasePool
    private let directoryURL: URL
    private let dataDirectoryURL: URL
    private let inlineValueThreshold: Int
    private let sizeLimit: Int64
    private let countLimit: Int
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let maintenanceQueue: DispatchQueue
    private let expirationTimer: DispatchSourceTimer
    private let coordinator: DiskCoordinator
    private let maintenanceStateLock = UnfairLock()
    private var pendingTouches: [String: Touch] = [:]
    private var isTouchFlushScheduled = false
    private var isTrimScheduled = false
    private var pendingTrimTimestamp: TimeInterval?
    private var scheduledExpirationTimestamp: TimeInterval?

    init(
        configuration: CacheConfiguration,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        directoryURL = configuration.directoryURL.appendingPathComponent(configuration.name, isDirectory: true)
        dataDirectoryURL = directoryURL.appendingPathComponent("data", isDirectory: true)
        inlineValueThreshold = configuration.inlineValueThreshold
        sizeLimit = configuration.diskSizeLimit
        countLimit = configuration.diskCountLimit
        self.fileManager = fileManager
        self.now = now
        try fileManager.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)

        var databaseConfiguration = SQLiteConfiguration()
        databaseConfiguration.journalMode = .wal
        databaseConfiguration.busyMode = .timeout(1)
        databaseConfiguration.maximumReaderCount = 5
        databaseConfiguration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        databasePool = try SQLiteDatabasePool(
            path: directoryURL.appendingPathComponent("cache.sqlite").path,
            configuration: databaseConfiguration
        )
        coordinator = DiskCoordinatorRegistry.shared.coordinator(for: directoryURL)
        let maintenanceQueue = DispatchQueue(
            label: "com.cachekit.maintenance.\(configuration.name)",
            qos: .userInitiated
        )
        self.maintenanceQueue = maintenanceQueue
        expirationTimer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        var didFinishInitialization = false
        defer {
            if !didFinishInitialization {
                DiskCoordinatorRegistry.shared.releaseCoordinator(for: directoryURL)
            }
        }
        try migrate()
        try coordinator.mutationLock.withLock {
            guard !coordinator.isExternalFileIndexLoaded else { return }
            coordinator.externalFileNames = try loadExternalFileNames()
            coordinator.isExternalFileIndexLoaded = true
        }
        expirationTimer.setEventHandler { [weak self] in
            self?.handleExpirationTimer()
        }
        expirationTimer.schedule(deadline: .distantFuture)
        expirationTimer.resume()
        scheduleStartupCleanup()
        didFinishInitialization = true
    }

    deinit {
        expirationTimer.setEventHandler {}
        expirationTimer.cancel()
        DiskCoordinatorRegistry.shared.releaseCoordinator(for: directoryURL)
    }

    func value(forKey key: String, now: Date) throws -> StoredValue? {
        let timestamp = now.timeIntervalSince1970
        while true {
            guard let item = try item(forKey: key) else { return nil }
            if let expirationTimestamp = item.expirationTimestamp, expirationTimestamp <= timestamp {
                try removeValueIfCurrent(forKey: key, generation: item.generation, fileName: item.fileName)
                return nil
            }

            let data: Data
            if let fileName = item.fileName {
                do {
                    data = try Data(
                        contentsOf: dataDirectoryURL.appendingPathComponent(fileName),
                        options: .mappedIfSafe
                    )
                } catch {
                    guard let currentItem = try self.item(forKey: key) else { return nil }
                    if currentItem.generation != item.generation {
                        continue
                    }
                    try removeValueIfCurrent(forKey: key, generation: item.generation, fileName: fileName)
                    return nil
                }
            } else {
                guard let inlineData = item.inlineData else {
                    try removeValueIfCurrent(forKey: key, generation: item.generation, fileName: nil)
                    return nil
                }
                data = inlineData
            }
            touchLater(key: key, generation: item.generation, timestamp: timestamp)
            return StoredValue(
                data: data,
                expirationDate: item.expirationTimestamp.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func values(forKeys keys: [String], now: Date) throws -> [String: StoredValue] {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return [:] }
        let timestamp = now.timeIntervalSince1970
        let items = try items(forKeys: uniqueKeys)
        var storedValues: [String: StoredValue] = [:]
        storedValues.reserveCapacity(items.count)

        for (key, item) in items {
            if let expirationTimestamp = item.expirationTimestamp, expirationTimestamp <= timestamp {
                try removeValueIfCurrent(forKey: key, generation: item.generation, fileName: item.fileName)
                continue
            }

            let data: Data
            if let fileName = item.fileName {
                do {
                    data = try Data(
                        contentsOf: dataDirectoryURL.appendingPathComponent(fileName),
                        options: .mappedIfSafe
                    )
                } catch {
                    if let currentValue = try value(forKey: key, now: now) {
                        storedValues[key] = currentValue
                    }
                    continue
                }
            } else {
                guard let inlineData = item.inlineData else {
                    try removeValueIfCurrent(forKey: key, generation: item.generation, fileName: nil)
                    continue
                }
                data = inlineData
            }
            touchLater(key: key, generation: item.generation, timestamp: timestamp)
            storedValues[key] = StoredValue(
                data: data,
                expirationDate: item.expirationTimestamp.map(Date.init(timeIntervalSince1970:))
            )
        }
        return storedValues
    }

    func setValue(_ data: Data, forKey key: String, expirationDate: Date?, now: Date) throws {
        let timestamp = now.timeIntervalSince1970
        var newFileName: String?
        do {
            try coordinator.mutationLock.withLock {
                let generation = coordinator.nextGenerationAssumingLockHeld()
                let inlineData: Data?
                if data.count > inlineValueThreshold {
                    newFileName = generation
                    inlineData = nil
                } else {
                    inlineData = data
                }
                if let newFileName {
                    try data.write(
                        to: dataDirectoryURL.appendingPathComponent(newFileName),
                        options: .atomic
                    )
                }
                let oldFileName = coordinator.externalFileNames[key]
                try databasePool.writeWithoutTransaction { database in
                    let statement = try database.cachedStatement(sql: """
                        INSERT OR REPLACE INTO cache_item(
                            cache_key, generation, file_name, inline_data,
                            value_size, created_at, last_access_at, expires_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """)
                    try statement.execute(arguments: [
                        key,
                        generation,
                        newFileName,
                        inlineData,
                        data.count,
                        timestamp,
                        timestamp,
                        expirationDate?.timeIntervalSince1970,
                    ])
                }

                coordinator.externalFileNames[key] = newFileName
                if let oldFileName, oldFileName != newFileName {
                    discardExternalFile(fileName: oldFileName)
                }
                scheduleTrim(timestamp: timestamp)
                if let expirationTimestamp = expirationDate?.timeIntervalSince1970 {
                    scheduleExpiration(at: expirationTimestamp, relativeTo: timestamp)
                }
            }
        } catch {
            if let newFileName {
                try? fileManager.removeItem(at: dataDirectoryURL.appendingPathComponent(newFileName))
            }
            throw error
        }
    }

    func setValues(_ values: [ValueToStore], now: Date) throws {
        guard !values.isEmpty else { return }
        let timestamp = now.timeIntervalSince1970
        var preparedValues: [PreparedValue] = []
        do {
            try coordinator.mutationLock.withLock {
                preparedValues = values.map { value in
                    let generation = coordinator.nextGenerationAssumingLockHeld()
                    let isExternal = value.data.count > inlineValueThreshold
                    return PreparedValue(
                        key: value.key,
                        data: value.data,
                        expirationDate: value.expirationDate,
                        generation: generation,
                        fileName: isExternal ? generation : nil,
                        inlineData: isExternal ? nil : value.data
                    )
                }
                for value in preparedValues {
                    if let fileName = value.fileName {
                        try value.data.write(
                            to: dataDirectoryURL.appendingPathComponent(fileName),
                            options: .atomic
                        )
                    }
                }

                let oldFileNames = preparedValues.reduce(into: [String: String]()) { fileNames, value in
                    fileNames[value.key] = coordinator.externalFileNames[value.key]
                }
                try databasePool.write { database in
                    let statement = try database.cachedStatement(sql: """
                        INSERT OR REPLACE INTO cache_item(
                            cache_key, generation, file_name, inline_data,
                            value_size, created_at, last_access_at, expires_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """)
                    for value in preparedValues {
                        try statement.execute(arguments: [
                            value.key,
                            value.generation,
                            value.fileName,
                            value.inlineData,
                            value.data.count,
                            timestamp,
                            timestamp,
                            value.expirationDate?.timeIntervalSince1970,
                        ])
                    }
                }

                for value in preparedValues {
                    coordinator.externalFileNames[value.key] = value.fileName
                    if let oldFileName = oldFileNames[value.key],
                       oldFileName != value.fileName {
                        discardExternalFile(fileName: oldFileName)
                    }
                }
                scheduleTrim(timestamp: timestamp)
                if let earliestExpiration = preparedValues.compactMap({
                    $0.expirationDate?.timeIntervalSince1970
                }).min() {
                    scheduleExpiration(at: earliestExpiration, relativeTo: timestamp)
                }
            }
        } catch {
            for value in preparedValues {
                if let fileName = value.fileName {
                    try? fileManager.removeItem(at: dataDirectoryURL.appendingPathComponent(fileName))
                }
            }
            throw error
        }
    }

    func removeValue(forKey key: String) throws {
        try coordinator.mutationLock.withLock {
            let fileName = coordinator.externalFileNames[key]
            try databasePool.writeWithoutTransaction { database in
                let statement = try database.cachedStatement(sql: "DELETE FROM cache_item WHERE cache_key = ?")
                try statement.execute(arguments: [key])
            }
            coordinator.externalFileNames.removeValue(forKey: key)
            if let fileName {
                discardExternalFile(fileName: fileName)
            }
        }
    }

    func removeValues(forKeys keys: [String]) throws {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return }
        try coordinator.mutationLock.withLock {
            let oldFileNames = uniqueKeys.reduce(into: [String: String]()) { fileNames, key in
                fileNames[key] = coordinator.externalFileNames[key]
            }
            try databasePool.write { database in
                let statement = try database.cachedStatement(sql: "DELETE FROM cache_item WHERE cache_key = ?")
                for key in uniqueKeys {
                    try statement.execute(arguments: [key])
                }
            }
            for key in uniqueKeys {
                coordinator.externalFileNames.removeValue(forKey: key)
                if let fileName = oldFileNames[key] {
                    discardExternalFile(fileName: fileName)
                }
            }
        }
    }

    func removeAll() throws {
        try coordinator.mutationLock.withLock {
            try databasePool.writeWithoutTransaction { database in
                try database.execute(sql: "DELETE FROM cache_item")
            }
            coordinator.externalFileNames.removeAll(keepingCapacity: true)
            maintenanceStateLock.withLock {
                pendingTouches.removeAll(keepingCapacity: true)
                isTouchFlushScheduled = false
            }
            let trashURL = directoryURL.appendingPathComponent("trash-\(UUID().uuidString)", isDirectory: true)
            if fileManager.fileExists(atPath: dataDirectoryURL.path) {
                try fileManager.moveItem(at: dataDirectoryURL, to: trashURL)
            }
            try fileManager.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
            maintenanceQueue.async { [weak self] in
                try? self?.fileManager.removeItem(at: trashURL)
            }
        }
    }

    private func migrate() throws {
        var migrator = SQLiteMigrator()
        migrator.registerMigration("createUnifiedCache") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS cache_item (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    file_name TEXT,
                    inline_data BLOB,
                    value_size INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    last_access_at REAL NOT NULL,
                    expires_at REAL
                );
                CREATE INDEX IF NOT EXISTS cache_item_lru ON cache_item(last_access_at);
                CREATE INDEX IF NOT EXISTS cache_item_expiration ON cache_item(expires_at);
                """)
        }
        migrator.registerMigration("addGeneration") { database in
            try database.execute(
                sql: "ALTER TABLE cache_item ADD COLUMN generation TEXT NOT NULL DEFAULT ''"
            )
        }
        try migrator.migrate(databasePool)
    }

    private func item(forKey key: String) throws -> Item? {
        try databasePool.read { database in
            let statement = try database.cachedStatement(sql: """
                SELECT generation, file_name, inline_data, expires_at
                FROM cache_item
                WHERE cache_key = ?
                """)
            guard let row = try SQLiteRow.fetchOne(statement, arguments: [key]) else { return nil }
            return Item(
                generation: row["generation"],
                fileName: row["file_name"],
                inlineData: row["inline_data"],
                expirationTimestamp: row["expires_at"]
            )
        }
    }

    private func items(forKeys keys: [String]) throws -> [String: Item] {
        try databasePool.read { database in
            var items: [String: Item] = [:]
            items.reserveCapacity(keys.count)
            for startIndex in stride(from: 0, to: keys.count, by: 500) {
                let endIndex = min(startIndex + 500, keys.count)
                let chunk = Array(keys[startIndex ..< endIndex])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let statement = try database.cachedStatement(sql: """
                    SELECT cache_key, generation, file_name, inline_data, expires_at
                    FROM cache_item
                    WHERE cache_key IN (\(placeholders))
                    """)
                let rows = try SQLiteRow.fetchAll(statement, arguments: SQLiteStatementArguments(chunk))
                for row in rows {
                    let key: String = row["cache_key"]
                    items[key] = Item(
                        generation: row["generation"],
                        fileName: row["file_name"],
                        inlineData: row["inline_data"],
                        expirationTimestamp: row["expires_at"]
                    )
                }
            }
            return items
        }
    }

    private func removeValueLocked(forKey key: String, generation: String, fileName: String?) throws {
        try databasePool.writeWithoutTransaction { database in
            let statement = try database.cachedStatement(
                sql: "DELETE FROM cache_item WHERE cache_key = ? AND generation = ?"
            )
            try statement.execute(arguments: [key, generation])
        }
        if coordinator.externalFileNames[key] == fileName {
            coordinator.externalFileNames.removeValue(forKey: key)
        }
        if let fileName {
            discardExternalFile(fileName: fileName)
        }
    }

    private func removeValueIfCurrent(forKey key: String, generation: String, fileName: String?) throws {
        try coordinator.mutationLock.withLock {
            try removeValueLocked(forKey: key, generation: generation, fileName: fileName)
        }
    }

    private func touchLater(key: String, generation: String, timestamp: TimeInterval) {
        let shouldSchedule = maintenanceStateLock.withLock {
            if let pendingTouch = pendingTouches[key],
               pendingTouch.generation == generation,
               pendingTouch.timestamp >= timestamp {
                return false
            }
            pendingTouches[key] = Touch(generation: generation, timestamp: timestamp)
            guard !isTouchFlushScheduled else { return false }
            isTouchFlushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        maintenanceQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.flushTouches()
        }
    }

    private func flushTouches() {
        let touches = maintenanceStateLock.withLock {
            let touches = pendingTouches
            pendingTouches.removeAll(keepingCapacity: true)
            isTouchFlushScheduled = false
            return touches
        }
        guard !touches.isEmpty else { return }
        try? databasePool.write { database in
            let statement = try database.cachedStatement(
                sql: "UPDATE cache_item SET last_access_at = ? WHERE cache_key = ? AND generation = ?"
            )
            for (key, touch) in touches {
                try statement.execute(arguments: [touch.timestamp, key, touch.generation])
            }
        }
    }

    private func scheduleTrim(timestamp: TimeInterval) {
        guard sizeLimit > 0 || countLimit > 0 else { return }
        let shouldSchedule = maintenanceStateLock.withLock {
            pendingTrimTimestamp = timestamp
            guard !isTrimScheduled else { return false }
            isTrimScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        maintenanceQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.coordinator.mutationLock.withLock {
                let trimTimestamp = self.maintenanceStateLock.withLock {
                    let trimTimestamp = self.pendingTrimTimestamp ?? timestamp
                    self.pendingTrimTimestamp = nil
                    return trimTimestamp
                }
                self.flushTouches()
                _ = self.trimExpiredAndOversizedItems(timestamp: trimTimestamp)
                self.maintenanceStateLock.withLock {
                    self.isTrimScheduled = false
                }
            }
        }
    }

    private func scheduleExpiration(at expirationTimestamp: TimeInterval, relativeTo timestamp: TimeInterval) {
        let shouldSchedule = maintenanceStateLock.withLock {
            if let scheduledExpirationTimestamp, scheduledExpirationTimestamp <= expirationTimestamp {
                return false
            }
            scheduledExpirationTimestamp = expirationTimestamp
            return true
        }
        guard shouldSchedule else { return }
        let delay = max(0, expirationTimestamp - timestamp)
        expirationTimer.schedule(
            deadline: .now() + delay,
            leeway: .milliseconds(100)
        )
    }

    private func handleExpirationTimer() {
        guard let expirationTimestamp = maintenanceStateLock.withLock({
            let timestamp = scheduledExpirationTimestamp
            scheduledExpirationTimestamp = nil
            return timestamp
        }) else {
            return
        }
        let timestamp = now().timeIntervalSince1970
        if expirationTimestamp > timestamp {
            scheduleExpiration(at: expirationTimestamp, relativeTo: timestamp)
            return
        }
        let didTrim = coordinator.mutationLock.withLock {
            flushTouches()
            return trimExpiredAndOversizedItems(timestamp: timestamp)
        }
        if didTrim {
            scheduleNextExpiration()
        } else {
            scheduleExpiration(at: timestamp + 1, relativeTo: timestamp)
        }
    }

    private func scheduleNextExpiration() {
        let expirationTimestamp: TimeInterval?
        do {
            expirationTimestamp = try databasePool.read { database in
                try database.fetchDouble(
                    sql: "SELECT MIN(expires_at) FROM cache_item WHERE expires_at IS NOT NULL"
                )
            }
        } catch {
            return
        }
        guard let expirationTimestamp else {
            return
        }
        let timestamp = now().timeIntervalSince1970
        scheduleExpiration(at: expirationTimestamp, relativeTo: timestamp)
    }

    @discardableResult
    private func trimExpiredAndOversizedItems(timestamp: TimeInterval) -> Bool {
        let victims: [Victim]
        do {
            victims = try databasePool.write { database in
                var victims = try SQLiteRow.fetchAll(
                    database,
                    sql: "SELECT cache_key, file_name FROM cache_item WHERE expires_at IS NOT NULL AND expires_at <= ?",
                    arguments: [timestamp]
                ).map { Victim(key: $0["cache_key"], fileName: $0["file_name"]) }

                if !victims.isEmpty {
                    try database.execute(
                        sql: "DELETE FROM cache_item WHERE expires_at IS NOT NULL AND expires_at <= ?",
                        arguments: [timestamp]
                    )
                }

                let totals = try SQLiteRow.fetchOne(
                    database,
                    sql: "SELECT COALESCE(SUM(value_size), 0) AS total_size, COUNT(*) AS total_count FROM cache_item"
                )
                let totalSize: Int64 = totals?["total_size"] ?? 0
                let totalCount: Int = totals?["total_count"] ?? 0
                let exceedsSizeLimit = sizeLimit > 0 && totalSize > sizeLimit
                let exceedsCountLimit = countLimit > 0 && totalCount > countLimit
                if exceedsSizeLimit || exceedsCountLimit {
                    var remainingSize = totalSize
                    var remainingCount = totalCount
                    let rows = try SQLiteRow.fetchAll(
                        database,
                        sql: "SELECT cache_key, file_name, value_size FROM cache_item ORDER BY last_access_at ASC"
                    )
                    let deleteStatement = try database.cachedStatement(
                        sql: "DELETE FROM cache_item WHERE cache_key = ?"
                    )
                    for row in rows {
                        let sizeIsWithinLimit = sizeLimit == 0 || remainingSize <= sizeLimit
                        let countIsWithinLimit = countLimit == 0 || remainingCount <= countLimit
                        if sizeIsWithinLimit && countIsWithinLimit {
                            break
                        }
                        let key: String = row["cache_key"]
                        victims.append(Victim(key: key, fileName: row["file_name"]))
                        let valueSize: Int64 = row["value_size"]
                        remainingSize -= valueSize
                        remainingCount -= 1
                        try deleteStatement.execute(arguments: [key])
                    }
                }
                return victims
            }
        } catch {
            return false
        }

        for victim in victims {
            if coordinator.externalFileNames[victim.key] == victim.fileName {
                coordinator.externalFileNames.removeValue(forKey: victim.key)
            }
            if let fileName = victim.fileName {
                discardExternalFile(fileName: fileName)
            }
        }
        return true
    }

    private func scheduleStartupCleanup() {
        maintenanceQueue.async { [weak self] in
            guard let self else { return }
            self.coordinator.mutationLock.withLock {
                self.reconcileExternalFiles()
                self.flushTouches()
                _ = self.trimExpiredAndOversizedItems(timestamp: self.now().timeIntervalSince1970)
                self.removeAbandonedTrashDirectories()
            }
            self.scheduleNextExpiration()
        }
    }

    private func reconcileExternalFiles() {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: dataDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }
        let existingFileNames = Set(fileURLs.map(\.lastPathComponent))
        let indexedFiles = coordinator.externalFileNames
        let missingFiles = indexedFiles.filter { !existingFileNames.contains($0.value) }
        if !missingFiles.isEmpty {
            try? databasePool.write { database in
                let statement = try database.cachedStatement(
                    sql: "DELETE FROM cache_item WHERE cache_key = ? AND file_name = ?"
                )
                for (key, fileName) in missingFiles {
                    try statement.execute(arguments: [key, fileName])
                }
            }
            for (key, fileName) in missingFiles where coordinator.externalFileNames[key] == fileName {
                coordinator.externalFileNames.removeValue(forKey: key)
            }
        }

        let retainedFileNames = Set(indexedFiles.values)
        for fileURL in fileURLs where !retainedFileNames.contains(fileURL.lastPathComponent) {
            discardExternalFile(fileName: fileURL.lastPathComponent)
        }
    }

    private func discardExternalFile(fileName: String) {
        let fileURL = dataDirectoryURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let trashDirectoryURL = directoryURL.appendingPathComponent("trash", isDirectory: true)
        let trashURL = trashDirectoryURL.appendingPathComponent(UUID().uuidString)
        do {
            try fileManager.createDirectory(at: trashDirectoryURL, withIntermediateDirectories: true)
            try fileManager.moveItem(at: fileURL, to: trashURL)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        maintenanceQueue.async { [weak self] in
            try? self?.fileManager.removeItem(at: trashURL)
        }
    }

    private func loadExternalFileNames() throws -> [String: String] {
        try databasePool.read { database in
            let rows = try SQLiteRow.fetchAll(
                database,
                sql: "SELECT cache_key, file_name FROM cache_item WHERE file_name IS NOT NULL"
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let key: String = row["cache_key"], let fileName: String = row["file_name"] else {
                    return nil
                }
                return (key, fileName)
            })
        }
    }

    private func removeAbandonedTrashDirectories() {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for fileURL in fileURLs where fileURL.lastPathComponent.hasPrefix("trash") {
            try? fileManager.removeItem(at: fileURL)
        }
    }
}
