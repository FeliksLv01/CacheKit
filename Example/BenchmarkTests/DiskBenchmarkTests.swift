import Cache
import CacheKit
import XCTest
import YYCache

final class DiskBenchmarkTests: XCTestCase {
    private let operationCount = 1_000
    private let value = Data(repeating: 0x5a, count: 1_024)

    func testCacheKitDiskWrite() throws {
        let fixture = try makeCacheKit()
        defer { fixture.remove() }
        var round = 0
        measure {
            round += 1
            for index in 0 ..< operationCount {
                do {
                    try fixture.cache.setValue(value, forKey: "\(round)-\(index)")
                } catch {
                    XCTFail("CacheKit write failed: \(error)")
                }
            }
        }
    }

    func testCacheKitBatchDiskWrite() throws {
        let fixture = try makeCacheKit()
        defer { fixture.remove() }
        var round = 0
        measure {
            round += 1
            let values = Dictionary(uniqueKeysWithValues: (0 ..< operationCount).map {
                ("\(round)-\($0)", value)
            })
            do {
                try fixture.cache.setValues(values)
            } catch {
                XCTFail("CacheKit batch write failed: \(error)")
            }
        }
    }

    func testHyperosloDiskWrite() throws {
        let fixture = try makeHyperosloCache()
        defer { fixture.remove() }
        var round = 0
        measure {
            round += 1
            for index in 0 ..< operationCount {
                do {
                    try fixture.cache.setObject(value, forKey: "\(round)-\(index)")
                } catch {
                    XCTFail("Cache write failed: \(error)")
                }
            }
        }
    }

    func testYYCacheDiskWrite() throws {
        let fixture = try makeYYCache()
        defer { fixture.remove() }
        var round = 0
        measure {
            round += 1
            for index in 0 ..< operationCount {
                fixture.cache.setObject(value as NSData, forKey: "\(round)-\(index)")
            }
        }
    }

    func testCacheKitDiskRead() throws {
        let fixture = try makeCacheKit()
        defer { fixture.remove() }
        for index in 0 ..< operationCount {
            try fixture.cache.setValue(value, forKey: "key-\(index)")
        }
        measure {
            for index in 0 ..< operationCount {
                do {
                    _ = try fixture.cache.value(forKey: "key-\(index)")
                } catch {
                    XCTFail("CacheKit read failed: \(error)")
                }
            }
        }
    }

    func testCacheKitBatchDiskRead() throws {
        let fixture = try makeCacheKit()
        defer { fixture.remove() }
        let keys = (0 ..< operationCount).map { "key-\($0)" }
        try fixture.cache.setValues(Dictionary(uniqueKeysWithValues: keys.map { ($0, value) }))
        measure {
            do {
                _ = try fixture.cache.values(forKeys: keys)
            } catch {
                XCTFail("CacheKit batch read failed: \(error)")
            }
        }
    }

    func testCacheKitConcurrentInlineDiskRead() throws {
        let fixture = try makeCacheKit()
        defer { fixture.remove() }
        let cache = fixture.cache
        let operationCount = operationCount
        for index in 0 ..< operationCount {
            try cache.setValue(value, forKey: "key-\(index)")
        }
        measure {
            DispatchQueue.concurrentPerform(iterations: operationCount * 4) { index in
                _ = try? cache.value(forKey: "key-\(index % operationCount)")
            }
        }
    }

    func testYYCacheConcurrentInlineDiskRead() throws {
        let fixture = try makeYYCache()
        defer { fixture.remove() }
        let cache = ThreadSafeBenchmarkBox(fixture.cache)
        let operationCount = operationCount
        for index in 0 ..< operationCount {
            cache.value.setObject(value as NSData, forKey: "key-\(index)")
        }
        measure {
            DispatchQueue.concurrentPerform(iterations: operationCount * 4) { index in
                _ = cache.value.object(forKey: "key-\(index % operationCount)") as? Data
            }
        }
    }

    func testHyperosloConcurrentDiskRead() throws {
        let fixture = try makeHyperosloCache()
        defer { fixture.remove() }
        let cache = ThreadSafeBenchmarkBox(fixture.cache)
        let operationCount = operationCount
        for index in 0 ..< operationCount {
            try cache.value.setObject(value, forKey: "key-\(index)")
        }
        measure {
            DispatchQueue.concurrentPerform(iterations: operationCount * 4) { index in
                _ = try? cache.value.object(forKey: "key-\(index % operationCount)")
            }
        }
    }

    func testCacheKitConcurrentMixedDiskAccess() throws {
        let fixture = try makeCacheKit()
        defer { fixture.remove() }
        let cache = fixture.cache
        let operationCount = operationCount
        let value = value
        try seedCacheKit(cache)
        measure {
            DispatchQueue.concurrentPerform(iterations: operationCount * 4) { index in
                let key = "key-\(index % operationCount)"
                if index.isMultiple(of: 10) {
                    try? cache.setValue(value, forKey: key)
                } else {
                    _ = try? cache.value(forKey: key)
                }
            }
        }
    }

    func testYYCacheConcurrentMixedDiskAccess() throws {
        let fixture = try makeYYCache()
        defer { fixture.remove() }
        let cache = ThreadSafeBenchmarkBox(fixture.cache)
        let operationCount = operationCount
        let value = value
        for index in 0 ..< operationCount {
            cache.value.setObject(value as NSData, forKey: "key-\(index)")
        }
        measure {
            DispatchQueue.concurrentPerform(iterations: operationCount * 4) { index in
                let key = "key-\(index % operationCount)"
                if index.isMultiple(of: 10) {
                    cache.value.setObject(value as NSData, forKey: key)
                } else {
                    _ = cache.value.object(forKey: key) as? Data
                }
            }
        }
    }

    func testHyperosloConcurrentMixedDiskAccess() throws {
        let fixture = try makeHyperosloCache()
        defer { fixture.remove() }
        let cache = ThreadSafeBenchmarkBox(fixture.cache)
        let operationCount = operationCount
        let value = value
        for index in 0 ..< operationCount {
            try cache.value.setObject(value, forKey: "key-\(index)")
        }
        measure {
            DispatchQueue.concurrentPerform(iterations: operationCount * 4) { index in
                let key = "key-\(index % operationCount)"
                if index.isMultiple(of: 10) {
                    try? cache.value.setObject(value, forKey: key)
                } else {
                    _ = try? cache.value.object(forKey: key)
                }
            }
        }
    }

    func testCacheKitConcurrentExternalDiskRead() throws {
        let fixture = try makeCacheKit(inlineValueThreshold: 1_024)
        defer { fixture.remove() }
        let cache = fixture.cache
        let externalValue = Data(repeating: 0x5a, count: 64 * 1_024)
        for index in 0 ..< 200 {
            try cache.setValue(externalValue, forKey: "key-\(index)")
        }
        measure {
            DispatchQueue.concurrentPerform(iterations: 2_000) { index in
                _ = try? cache.value(forKey: "key-\(index % 200)")
            }
        }
    }

    func testHyperosloDiskRead() throws {
        let fixture = try makeHyperosloCache()
        defer { fixture.remove() }
        for index in 0 ..< operationCount {
            try fixture.cache.setObject(value, forKey: "key-\(index)")
        }
        measure {
            for index in 0 ..< operationCount {
                do {
                    _ = try fixture.cache.object(forKey: "key-\(index)")
                } catch {
                    XCTFail("Cache read failed: \(error)")
                }
            }
        }
    }

    func testYYCacheDiskRead() throws {
        let fixture = try makeYYCache()
        defer { fixture.remove() }
        for index in 0 ..< operationCount {
            fixture.cache.setObject(value as NSData, forKey: "key-\(index)")
        }
        measure {
            for index in 0 ..< operationCount {
                _ = fixture.cache.object(forKey: "key-\(index)") as? Data
            }
        }
    }

    private func makeCacheKit(
        inlineValueThreshold: Int = 20 * 1_024
    ) throws -> (cache: CacheKit.Cache<Data>, remove: () -> Void) {
        let rootURL = temporaryRoot()
        let configuration = CacheKit.CacheConfiguration(
            name: "cachekit",
            directoryURL: rootURL,
            storageMode: .disk,
            diskSizeLimit: 0,
            inlineValueThreshold: inlineValueThreshold
        )
        let cache = try CacheKit.Cache(configuration: configuration, codec: .data)
        return (cache, delayedRemoval(of: rootURL))
    }

    private func seedCacheKit(_ cache: CacheKit.Cache<Data>) throws {
        for index in 0 ..< operationCount {
            try cache.setValue(value, forKey: "key-\(index)")
        }
    }

    private func makeHyperosloCache() throws -> (cache: DiskStorage<String, Data>, remove: () -> Void) {
        let rootURL = temporaryRoot()
        let configuration = DiskConfig(name: "cache", maxSize: 0, directory: rootURL)
        let cache = try DiskStorage<String, Data>(config: configuration, transformer: TransformerFactory.forData())
        return (cache, delayedRemoval(of: rootURL))
    }

    private func makeYYCache() throws -> (cache: YYDiskCache, remove: () -> Void) {
        let rootURL = temporaryRoot()
        guard let cache = YYDiskCache(path: rootURL.path, inlineThreshold: 20 * 1_024) else {
            throw CocoaError(.fileWriteUnknown)
        }
        cache.customArchiveBlock = { object in
            guard let data = object as? NSData else {
                XCTFail("YYCache received a non-Data value")
                return Data()
            }
            return data as Data
        }
        cache.customUnarchiveBlock = { data in
            data
        }
        return (cache, delayedRemoval(of: rootURL))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func delayedRemoval(of rootURL: URL) -> () -> Void {
        {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) {
                try? FileManager.default.removeItem(at: rootURL)
            }
        }
    }
}

// NOTE: Used only for benchmark cache types whose APIs are exercised concurrently by design.
private final class ThreadSafeBenchmarkBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
