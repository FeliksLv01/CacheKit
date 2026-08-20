import XCTest
@testable import CacheKit

final class CacheTests: XCTestCase {
    func testMemoryCacheUsesStrictLRU() throws {
        let fixture = try Fixture(mode: .memory, memoryCountLimit: 2)
        try fixture.cache.setValue(Data("one".utf8), forKey: "one")
        try fixture.cache.setValue(Data("two".utf8), forKey: "two")
        _ = try fixture.cache.value(forKey: "one")
        try fixture.cache.setValue(Data("three".utf8), forKey: "three")

        XCTAssertNotNil(try fixture.cache.value(forKey: "one"))
        XCTAssertNil(try fixture.cache.value(forKey: "two"))
        XCTAssertNotNil(try fixture.cache.value(forKey: "three"))
    }

    func testMemoryStorageUsesCostLimitAndReplacementCost() {
        let cache = MemoryStorage<Data>(countLimit: 0, costLimit: 3)
        cache.setValue(Data("one".utf8), forKey: "one", cost: 2)
        cache.setValue(Data("updated".utf8), forKey: "one", cost: 1)
        cache.setValue(Data("two".utf8), forKey: "two", cost: 2)

        XCTAssertEqual(cache.count, 2)
        cache.setValue(Data("three".utf8), forKey: "three", cost: 1)

        XCTAssertNil(cache.value(forKey: "one"))
        XCTAssertEqual(cache.value(forKey: "two"), Data("two".utf8))
        XCTAssertEqual(cache.value(forKey: "three"), Data("three".utf8))
    }

    func testHybridCacheHydratesMemoryFromDisk() throws {
        let fixture = try Fixture(mode: .hybrid)
        try fixture.cache.setValue(Data("value".utf8), forKey: "key")

        let restored = try fixture.makeCache()
        XCTAssertEqual(try restored.value(forKey: "key"), Data("value".utf8))
    }

    func testAsyncAPIReadsAndWrites() async throws {
        let fixture = try Fixture(mode: .hybrid)
        try await fixture.cache.async.setValue(Data("value".utf8), forKey: "key")
        let value = try await fixture.cache.async.value(forKey: "key")
        XCTAssertEqual(value, Data("value".utf8))
    }

    func testBatchWritePersistsAllValues() throws {
        let fixture = try Fixture(mode: .disk)
        let values = Dictionary(uniqueKeysWithValues: (0 ..< 100).map {
            ("key-\($0)", Data("value-\($0)".utf8))
        })

        try fixture.cache.setValues(values)

        let restored = try fixture.makeCache()
        for (key, value) in values {
            XCTAssertEqual(try restored.value(forKey: key), value)
        }
    }

    func testAsyncBatchWritePersistsAllValues() async throws {
        let fixture = try Fixture(mode: .hybrid)
        let values = Dictionary(uniqueKeysWithValues: (0 ..< 100).map {
            ("key-\($0)", Data("value-\($0)".utf8))
        })

        try await fixture.cache.async.setValues(values)

        let cachedValues = try await fixture.cache.async.values(forKeys: Array(values.keys))
        XCTAssertEqual(cachedValues, values)
        try await fixture.cache.async.removeValues(forKeys: Array(values.keys))
        let removedValues = try await fixture.cache.async.values(forKeys: Array(values.keys))
        XCTAssertTrue(removedValues.isEmpty)
    }

    func testBatchReadReturnsOnlyExistingUnexpiredValues() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1))
        let fixture = try Fixture(mode: .disk, now: { clock.now() })
        try fixture.cache.setValues([
            "one": Data("one".utf8),
            "two": Data("two".utf8),
        ])
        try fixture.cache.setValue(Data("expired".utf8), forKey: "expired", expiration: .seconds(1))
        clock.advance(by: 2)

        let values = try fixture.cache.values(forKeys: ["one", "two", "expired", "missing", "one"])

        XCTAssertEqual(values, [
            "one": Data("one".utf8),
            "two": Data("two".utf8),
        ])
        XCTAssertNil(try fixture.cache.value(forKey: "expired"))
    }

    func testBatchRemoveDeletesInlineAndExternalValues() throws {
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, inlineValueThreshold: 8)
        try fixture.cache.setValues([
            "inline": Data("inline".utf8),
            "external": Data(repeating: 1, count: 1_024),
            "retained": Data(repeating: 2, count: 1_024),
        ])

        try fixture.cache.removeValues(forKeys: ["inline", "external", "missing", "inline"])

        XCTAssertTrue(try fixture.cache.values(forKeys: ["inline", "external"]).isEmpty)
        XCTAssertEqual(try fixture.cache.value(forKey: "retained"), Data(repeating: 2, count: 1_024))
        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).count, 1)
    }

    func testBatchEncodingFailureDoesNotWritePartialValues() throws {
        let codec = CacheCodec<Data>(
            encode: { value in
                if value == Data("invalid".utf8) {
                    throw TestCodecError.invalidValue
                }
                return value
            },
            decode: { $0 }
        )
        let fixture = try Fixture(mode: .disk, codec: codec)

        XCTAssertThrowsError(try fixture.cache.setValues([
            "valid": Data("valid".utf8),
            "invalid": Data("invalid".utf8),
        ]))
        XCTAssertNil(try fixture.cache.value(forKey: "valid"))
        XCTAssertNil(try fixture.cache.value(forKey: "invalid"))
    }

    func testBatchWriteReplacesExternalFilesWithoutLeavingOrphans() throws {
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, inlineValueThreshold: 8)
        try fixture.cache.setValues([
            "one": Data(repeating: 1, count: 1_024),
            "two": Data(repeating: 2, count: 1_024),
        ])

        try fixture.cache.setValues([
            "one": Data("inline".utf8),
            "two": Data(repeating: 3, count: 1_024),
        ])

        XCTAssertEqual(try fixture.cache.value(forKey: "one"), Data("inline".utf8))
        XCTAssertEqual(try fixture.cache.value(forKey: "two"), Data(repeating: 3, count: 1_024))
        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).count, 1)
    }

    func testExpirationRemovesValue() throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1))
        let fixture = try Fixture(mode: .hybrid, now: { clock.now() })
        try fixture.cache.setValue(Data("value".utf8), forKey: "key", expiration: .seconds(1))
        clock.date = Date(timeIntervalSince1970: 3)
        XCTAssertNil(try fixture.cache.value(forKey: "key"))
    }

    func testLargeValueUsesExternalFile() throws {
        let fixture = try Fixture(mode: .disk, inlineValueThreshold: 8)
        let value = Data(repeating: 1, count: 32)
        try fixture.cache.setValue(value, forKey: "large")
        XCTAssertEqual(try fixture.cache.value(forKey: "large"), value)

        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).count, 1)
    }

    func testAsyncLoaderCoalescesSameKey() async throws {
        let fixture = try Fixture(mode: .hybrid)
        let counter = InvocationCounter()
        let loader: @Sendable () async throws -> Data = {
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return Data("loaded".utf8)
        }
        let asyncCache = fixture.cache.async

        async let first = asyncCache.value(forKey: "same", orLoad: loader)
        async let second = asyncCache.value(forKey: "same", orLoad: loader)
        let values = try await (first, second)
        let invocationCount = await counter.value

        XCTAssertEqual(values.0, Data("loaded".utf8))
        XCTAssertEqual(values.1, Data("loaded".utf8))
        XCTAssertEqual(invocationCount, 1)
    }

    func testMemoryStorageSupportsConcurrentAccess() {
        let cache = MemoryStorage<Data>(countLimit: 512, costLimit: 0)

        DispatchQueue.concurrentPerform(iterations: 5_000) { index in
            let key = "key-\(index)"
            cache.setValue(Data(key.utf8), forKey: key)
            _ = cache.value(forKey: key)
        }

        XCTAssertLessThanOrEqual(cache.count, 512)
    }

    func testAsyncDiskStorageSupportsConcurrentAccess() async throws {
        let fixture = try Fixture(mode: .disk)
        let asyncCache = fixture.cache.async
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 200 {
                group.addTask {
                    try await asyncCache.setValue(Data("value-\(index)".utf8), forKey: "key-\(index)")
                }
            }
            try await group.waitForAll()
        }

        for index in 0 ..< 200 {
            XCTAssertEqual(try fixture.cache.value(forKey: "key-\(index)"), Data("value-\(index)".utf8))
        }
    }

    func testReplacingExternalValueWithInlineValueRemovesFile() throws {
        let fixture = try Fixture(mode: .disk, inlineValueThreshold: 8)
        try fixture.cache.setValue(Data(repeating: 1, count: 32), forKey: "key")
        try fixture.cache.setValue(Data("small".utf8), forKey: "key")

        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).isEmpty)
        XCTAssertEqual(try fixture.cache.value(forKey: "key"), Data("small".utf8))
    }

    func testConcurrentExternalReadsNeverObservePartialReplacement() throws {
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, inlineValueThreshold: 8)
        let initialValue = Data(repeating: 1, count: 1_024)
        try fixture.cache.setValue(initialValue, forKey: "key")
        let failureCount = LockedCounter()
        let cache = fixture.cache

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            if index.isMultiple(of: 2) {
                let byte = UInt8(index % 251 + 1)
                do {
                    try cache.setValue(Data(repeating: byte, count: 1_024), forKey: "key")
                } catch {
                    failureCount.increment()
                }
            } else {
                do {
                    guard let value = try cache.value(forKey: "key"),
                          value.count == 1_024,
                          value.allSatisfy({ $0 == value[0] })
                    else {
                        failureCount.increment()
                        return
                    }
                } catch {
                    failureCount.increment()
                }
            }
        }

        let finalValue = Data(repeating: 0xa5, count: 1_024)
        try fixture.cache.setValue(finalValue, forKey: "key")
        XCTAssertEqual(failureCount.value, 0)
        XCTAssertEqual(try fixture.cache.value(forKey: "key"), finalValue)
        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).count, 1)
    }

    func testExpirationTimerRemovesUnaccessedExternalValue() async throws {
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, inlineValueThreshold: 8)
        try fixture.cache.setValue(
            Data(repeating: 1, count: 1_024),
            forKey: "expiring",
            expiration: .seconds(0.05)
        )
        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")

        for _ in 0 ..< 20 where !(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).isEmpty) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).isEmpty)
        XCTAssertNil(try fixture.cache.value(forKey: "expiring"))
    }

    func testStartupCleanupRemovesOrphanedExternalFile() async throws {
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, inlineValueThreshold: 8)
        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        let orphanURL = dataDirectory.appendingPathComponent("orphan")
        try Data("orphan".utf8).write(to: orphanURL)
        let restored = try fixture.makeCache()

        for _ in 0 ..< 20 where FileManager.default.fileExists(atPath: orphanURL.path) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        withExtendedLifetime(restored) {}
    }

    func testMultipleInstancesShareExternalFileLifecycle() throws {
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, inlineValueThreshold: 8)
        let secondCache = try fixture.makeCache()
        let firstValue = Data(repeating: 1, count: 1_024)
        let secondValue = Data(repeating: 2, count: 1_024)

        try fixture.cache.setValue(firstValue, forKey: "key")
        XCTAssertEqual(try secondCache.value(forKey: "key"), firstValue)
        try secondCache.setValue(secondValue, forKey: "key")
        XCTAssertEqual(try fixture.cache.value(forKey: "key"), secondValue)

        try fixture.cache.removeValue(forKey: "key")

        XCTAssertNil(try secondCache.value(forKey: "key"))
        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)
        let remainingBytes = fileNames.compactMap { fileName in
            try? Data(contentsOf: dataDirectory.appendingPathComponent(fileName)).first
        }
        XCTAssertTrue(fileNames.isEmpty, "Remaining files: \(fileNames), bytes: \(remainingBytes)")
    }

    func testMultipleInstancesReplaceExternalValueConcurrently() throws {
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, inlineValueThreshold: 8)
        let secondCache = try fixture.makeCache()
        let caches = [fixture.cache, secondCache]
        let failureCount = LockedCounter()
        try fixture.cache.setValue(Data(repeating: 1, count: 1_024), forKey: "key")

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let cache = caches[index % caches.count]
            if index.isMultiple(of: 2) {
                do {
                    let byte = UInt8(index % 251 + 1)
                    try cache.setValue(Data(repeating: byte, count: 1_024), forKey: "key")
                } catch {
                    failureCount.increment()
                }
            } else {
                do {
                    guard let value = try cache.value(forKey: "key"),
                          value.count == 1_024,
                          value.allSatisfy({ $0 == value[0] })
                    else {
                        failureCount.increment()
                        return
                    }
                } catch {
                    failureCount.increment()
                }
            }
        }

        let finalValue = Data(repeating: 0xa5, count: 1_024)
        try secondCache.setValue(finalValue, forKey: "key")
        XCTAssertEqual(failureCount.value, 0)
        XCTAssertEqual(try fixture.cache.value(forKey: "key"), finalValue)
        XCTAssertEqual(try secondCache.value(forKey: "key"), finalValue)
        let dataDirectory = fixture.cacheDirectory.appendingPathComponent("cache/data")
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)
        XCTAssertEqual(fileNames.count, 1, "Remaining files: \(fileNames)")
    }

    func testDiskTrimFlushesPendingLRUTouches() async throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1))
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 8, now: { clock.now() })
        try fixture.cache.setValue(Data(repeating: 1, count: 4), forKey: "one")
        clock.advance(by: 1)
        try fixture.cache.setValue(Data(repeating: 2, count: 4), forKey: "two")
        clock.advance(by: 1)
        _ = try fixture.cache.value(forKey: "one")
        clock.advance(by: 1)
        try fixture.cache.setValue(Data(repeating: 3, count: 4), forKey: "three")

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(try fixture.cache.value(forKey: "one"))
        XCTAssertNil(try fixture.cache.value(forKey: "two"))
        XCTAssertNotNil(try fixture.cache.value(forKey: "three"))
    }

    func testDiskCountLimitUsesLRU() async throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1))
        let fixture = try Fixture(mode: .disk, diskSizeLimit: 0, diskCountLimit: 2, now: { clock.now() })
        try fixture.cache.setValue(Data("one".utf8), forKey: "one")
        clock.advance(by: 1)
        try fixture.cache.setValue(Data("two".utf8), forKey: "two")
        clock.advance(by: 1)
        _ = try fixture.cache.value(forKey: "one")
        clock.advance(by: 1)
        try fixture.cache.setValue(Data("three".utf8), forKey: "three")

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(try fixture.cache.value(forKey: "one"))
        XCTAssertNil(try fixture.cache.value(forKey: "two"))
        XCTAssertNotNil(try fixture.cache.value(forKey: "three"))
    }
}

private final class Fixture {
    let rootURL: URL
    let cacheDirectory: URL
    let configuration: CacheConfiguration
    let cache: Cache<Data>
    let now: @Sendable () -> Date

    init(
        mode: CacheConfiguration.StorageMode,
        memoryCountLimit: Int = 10,
        diskSizeLimit: Int64 = 200 * 1024 * 1024,
        diskCountLimit: Int = 0,
        inlineValueThreshold: Int = 20 * 1024,
        codec: CacheCodec<Data> = .data,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheDirectory = rootURL.appendingPathComponent("storage")
        configuration = CacheConfiguration(
            name: "cache",
            directoryURL: cacheDirectory,
            storageMode: mode,
            memoryCountLimit: memoryCountLimit,
            diskSizeLimit: diskSizeLimit,
            diskCountLimit: diskCountLimit,
            inlineValueThreshold: inlineValueThreshold
        )
        self.now = now
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        cache = try Cache(configuration: configuration, codec: codec, now: now)
    }

    deinit {
        let rootURL = rootURL
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func makeCache() throws -> Cache<Data> {
        try Cache(configuration: configuration, codec: .data, now: now)
    }
}

private enum TestCodecError: Error {
    case invalidValue
}

final class TestClock: @unchecked Sendable {
    private let lock = UnfairLock()
    private var storedDate: Date

    init(date: Date) {
        storedDate = date
    }

    var date: Date {
        get { lock.withLock { storedDate } }
        set { lock.withLock { storedDate = newValue } }
    }

    func now() -> Date {
        date
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            storedDate = storedDate.addingTimeInterval(interval)
        }
    }
}

actor InvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = UnfairLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock {
            storedValue += 1
        }
    }
}
