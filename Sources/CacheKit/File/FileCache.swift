import Foundation

public final class FileCache: @unchecked Sendable {
    public let async: FileCacheAsync

    private let fileStore: FileCacheFileStore
    private let indexStore: FileCacheIndexStore
    private let evictionPolicy: FileCacheLRUEvictionPolicy
    private let now: @Sendable () -> Date
    private let queue: DispatchQueue
    private var leases: [UUID: String] = [:]

    public init(
        configuration: FileCacheConfiguration,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let fileStore = FileCacheFileStore(directoryURL: configuration.directoryURL, fileManager: fileManager)
        try fileStore.prepare()
        let indexStore = try FileCacheIndexStore(directoryURL: configuration.directoryURL)
        let loadedEntries = try indexStore.allEntries()
        let validEntries = loadedEntries.filter { entry in
            fileStore.isUsableFile(fileStore.fileURL(fileName: entry.fileName), expectedSize: 0)
        }
        for invalidEntry in loadedEntries where !validEntries.contains(where: { $0.identifier == invalidEntry.identifier }) {
            try indexStore.remove(identifier: invalidEntry.identifier)
        }
        fileStore.removeOrphanedFiles(retaining: Set(validEntries.map(\.fileName)))

        self.fileStore = fileStore
        self.indexStore = indexStore
        evictionPolicy = FileCacheLRUEvictionPolicy(
            maximumSize: configuration.maximumSize,
            maximumFileCount: configuration.maximumFileCount
        )
        self.now = now
        queue = DispatchQueue(
            label: "com.cachekit.file.\(FileCacheFileStore.identifier(for: configuration.directoryURL.path))",
            qos: .userInitiated
        )
        async = FileCacheAsync()
        async.bind(cache: self)
    }

    public func fileURL(for keys: [String], expectedSize: Int64 = 0) throws -> URL? {
        try queue.sync {
            try fileURLUnlocked(for: keys, expectedSize: expectedSize)
        }
    }

    public func destinationURL(primaryKey: String, fileExtension: String) throws -> URL {
        try queue.sync {
            try destinationURLUnlocked(primaryKey: primaryKey, fileExtension: fileExtension)
        }
    }

    @discardableResult
    public func commitFile(at url: URL, keys: [String], expectedSize: Int64 = 0) throws -> URL {
        try queue.sync {
            try commitFileUnlocked(at: url, keys: keys, expectedSize: expectedSize)
        }
    }

    @discardableResult
    public func importFile(
        from sourceURL: URL,
        keys: [String],
        fileExtension: String,
        moveSource: Bool = false
    ) throws -> URL {
        try queue.sync {
            try importFileUnlocked(from: sourceURL, keys: keys, fileExtension: fileExtension, moveSource: moveSource)
        }
    }

    @discardableResult
    public func bind(keys: [String], toAnyExistingKey existingKeys: [String]) throws -> URL? {
        try queue.sync {
            try bindUnlocked(keys: keys, toAnyExistingKey: existingKeys)
        }
    }

    public func acquireLease(for keys: [String]) throws -> UUID? {
        try queue.sync {
            try acquireLeaseUnlocked(for: keys)
        }
    }

    public func releaseLease(_ leaseID: UUID) throws {
        try queue.sync {
            guard leases.removeValue(forKey: leaseID) != nil else { return }
            try evict(protectedIdentifiers: [])
        }
    }

    private func fileURLUnlocked(for keys: [String], expectedSize: Int64) throws -> URL? {
        let normalizedKeys = Set(keys.filter { !$0.isEmpty })
        guard let entry = try indexStore.entry(forAny: normalizedKeys) else {
            return nil
        }
        let url = fileStore.fileURL(fileName: entry.fileName)
        guard fileStore.isUsableFile(url, expectedSize: expectedSize) else {
            try removeEntry(entry, removeFile: true)
            return nil
        }
        try indexStore.touch(identifier: entry.identifier, keys: normalizedKeys, at: now().timeIntervalSince1970)
        return url
    }

    private func destinationURLUnlocked(primaryKey: String, fileExtension: String) throws -> URL {
        try fileStore.prepare()
        guard !primaryKey.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if let entry = try indexStore.entry(forAny: [primaryKey]) {
            return fileStore.fileURL(fileName: entry.fileName)
        }
        return fileStore.destinationURL(
            identifier: FileCacheFileStore.identifier(for: primaryKey),
            fileExtension: fileExtension
        ).appendingPathExtension("cachekitdownload")
    }

    private func commitFileUnlocked(at url: URL, keys: [String], expectedSize: Int64) throws -> URL {
        guard fileStore.isRegularFile(url, expectedSize: expectedSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fileStore.prepare()
        let normalizedKeys = Set(keys.filter { !$0.isEmpty })
        guard let primaryKey = keys.first(where: { !$0.isEmpty }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let existingEntry = try indexStore.entry(forAny: normalizedKeys)
        let identifier = existingEntry?.identifier ?? FileCacheFileStore.identifier(for: primaryKey)
        let sourceExtension = url.pathExtension == "cachekitdownload" ? url.deletingPathExtension().pathExtension : url.pathExtension
        let targetURL = fileStore.destinationURL(identifier: identifier, fileExtension: sourceExtension)
        try fileStore.placeFile(from: url, at: targetURL, moveSource: true)

        let size = try fileStore.fileSize(at: targetURL)
        let entry = FileCacheEntry(
            identifier: identifier,
            fileName: targetURL.lastPathComponent,
            size: size,
            lastAccessTime: now().timeIntervalSince1970
        )
        try indexStore.upsert(entry: entry, keys: normalizedKeys)
        try evict(protectedIdentifiers: [identifier])
        return targetURL
    }

    private func importFileUnlocked(
        from sourceURL: URL,
        keys: [String],
        fileExtension: String,
        moveSource: Bool
    ) throws -> URL {
        guard fileStore.isUsableFile(sourceURL, expectedSize: 0) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try fileStore.prepare()
        let contentKey = try fileStore.contentIdentifier(at: sourceURL)
        var normalizedKeys = Set(keys.filter { !$0.isEmpty })
        normalizedKeys.insert(contentKey)
        if let cachedURL = try fileURLUnlocked(for: Array(normalizedKeys), expectedSize: 0) {
            if moveSource, sourceURL.standardizedFileURL != cachedURL.standardizedFileURL {
                fileStore.removeFile(at: sourceURL)
            }
            return cachedURL
        }

        let identifier = FileCacheFileStore.identifier(for: contentKey)
        let targetURL = fileStore.destinationURL(identifier: identifier, fileExtension: fileExtension)
        try fileStore.placeFile(from: sourceURL, at: targetURL, moveSource: moveSource)
        let entry = FileCacheEntry(
            identifier: identifier,
            fileName: targetURL.lastPathComponent,
            size: try fileStore.fileSize(at: targetURL),
            lastAccessTime: now().timeIntervalSince1970
        )
        try indexStore.upsert(entry: entry, keys: normalizedKeys)
        try evict(protectedIdentifiers: [identifier])
        return targetURL
    }

    private func bindUnlocked(keys: [String], toAnyExistingKey existingKeys: [String]) throws -> URL? {
        guard let entry = try indexStore.bind(
            keys: Set(keys.filter { !$0.isEmpty }),
            toAnyExistingKey: Set(existingKeys.filter { !$0.isEmpty }),
            at: now().timeIntervalSince1970
        ) else {
            return nil
        }
        let url = fileStore.fileURL(fileName: entry.fileName)
        guard fileStore.isUsableFile(url, expectedSize: 0) else {
            try removeEntry(entry, removeFile: true)
            return nil
        }
        return url
    }

    private func acquireLeaseUnlocked(for keys: [String]) throws -> UUID? {
        guard let entry = try indexStore.entry(forAny: Set(keys.filter { !$0.isEmpty })),
              fileStore.isUsableFile(fileStore.fileURL(fileName: entry.fileName), expectedSize: 0) else {
            return nil
        }
        let leaseID = UUID()
        leases[leaseID] = entry.identifier
        return leaseID
    }

    private func evict(protectedIdentifiers: Set<String>) throws {
        let protected = protectedIdentifiers.union(leases.values)
        let entries = try indexStore.allEntries()
        let victims = evictionPolicy.victims(entries: entries, protectedIdentifiers: protected)
        for victim in victims {
            try removeEntry(victim, removeFile: true)
        }
    }

    private func removeEntry(_ entry: FileCacheEntry, removeFile: Bool) throws {
        try indexStore.remove(identifier: entry.identifier)
        if removeFile {
            fileStore.removeFile(fileName: entry.fileName)
        }
    }

    fileprivate func discardFile(at url: URL) {
        queue.sync {
            fileStore.removeFile(at: url)
        }
    }
}

public final class FileCacheAsync: @unchecked Sendable {
    private weak var cache: FileCache?
    private let queue = DispatchQueue(label: "com.cachekit.file.async", qos: .userInitiated, attributes: .concurrent)
    private let loadCoordinator = LoadCoordinator<URL>()

    fileprivate init() {}

    fileprivate func bind(cache: FileCache) {
        self.cache = cache
    }

    public func fileURL(for keys: [String], expectedSize: Int64 = 0) async throws -> URL? {
        try await perform { try $0.fileURL(for: keys, expectedSize: expectedSize) }
    }

    public func destinationURL(primaryKey: String, fileExtension: String) async throws -> URL {
        try await perform { try $0.destinationURL(primaryKey: primaryKey, fileExtension: fileExtension) }
    }

    @discardableResult
    public func commitFile(at url: URL, keys: [String], expectedSize: Int64 = 0) async throws -> URL {
        try await perform { try $0.commitFile(at: url, keys: keys, expectedSize: expectedSize) }
    }

    @discardableResult
    public func importFile(
        from sourceURL: URL,
        keys: [String],
        fileExtension: String,
        moveSource: Bool = false
    ) async throws -> URL {
        try await perform {
            try $0.importFile(from: sourceURL, keys: keys, fileExtension: fileExtension, moveSource: moveSource)
        }
    }

    @discardableResult
    public func bind(keys: [String], toAnyExistingKey existingKeys: [String]) async throws -> URL? {
        try await perform { try $0.bind(keys: keys, toAnyExistingKey: existingKeys) }
    }

    public func acquireLease(for keys: [String]) async throws -> UUID? {
        try await perform { try $0.acquireLease(for: keys) }
    }

    public func releaseLease(_ leaseID: UUID) async throws {
        try await perform { try $0.releaseLease(leaseID) }
    }

    public func fileURL(
        for keys: [String],
        fileExtension: String,
        expectedSize: Int64 = 0,
        orLoad loader: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> URL {
        if let cachedURL = try await fileURL(for: keys, expectedSize: expectedSize) {
            return cachedURL
        }
        guard let primaryKey = keys.first(where: { !$0.isEmpty }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return try await loadCoordinator.value(forKey: primaryKey) { [weak cache] in
            guard let cache else { throw CacheError.deallocated }
            if let cachedURL = try cache.fileURL(for: keys, expectedSize: expectedSize) {
                return cachedURL
            }
            let destinationURL = try cache.destinationURL(primaryKey: primaryKey, fileExtension: fileExtension)
            do {
                try await loader(destinationURL)
                return try cache.commitFile(at: destinationURL, keys: keys, expectedSize: expectedSize)
            } catch {
                cache.discardFile(at: destinationURL)
                throw error
            }
        }
    }

    private func perform<Result: Sendable>(
        _ operation: @escaping @Sendable (FileCache) throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak cache] in
                guard let cache else {
                    continuation.resume(throwing: CacheError.deallocated)
                    return
                }
                do {
                    continuation.resume(returning: try operation(cache))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
