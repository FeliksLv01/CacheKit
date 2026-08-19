import Cache
import CacheKit
import XCTest
import YYCache

final class MemoryBenchmarkTests: XCTestCase {
    private let operationCount = 100_000
    private let value = Data(repeating: 0x5a, count: 256)

    func testCacheKitMemoryWrite() throws {
        let cache = CacheKit.MemoryStorage<Data>(countLimit: operationCount, costLimit: 0)
        measure {
            for index in 0 ..< operationCount {
                cache.setValue(value, forKey: "key-\(index)")
            }
            cache.removeAll()
        }
    }

    func testHyperosloMemoryWrite() throws {
        let cache = MemoryStorage<String, Data>(config: MemoryConfig(countLimit: UInt(operationCount)))
        measure {
            for index in 0 ..< operationCount {
                cache.setObject(value, forKey: "key-\(index)")
            }
            cache.removeAll()
        }
    }

    func testYYCacheMemoryWrite() throws {
        let cache = YYMemoryCache()
        cache.countLimit = UInt(operationCount)
        measure {
            for index in 0 ..< operationCount {
                cache.setObject(value, forKey: "key-\(index)")
            }
            cache.removeAllObjects()
        }
    }

    func testCacheKitMemoryRead() throws {
        let cache = CacheKit.MemoryStorage<Data>(countLimit: operationCount, costLimit: 0)
        populate { cache.setValue(value, forKey: $0) }
        measure {
            for index in 0 ..< operationCount {
                _ = cache.value(forKey: "key-\(index)")
            }
        }
    }

    func testHyperosloMemoryRead() throws {
        let cache = MemoryStorage<String, Data>(config: MemoryConfig(countLimit: UInt(operationCount)))
        populate { cache.setObject(value, forKey: $0) }
        measure {
            for index in 0 ..< operationCount {
                _ = try? cache.object(forKey: "key-\(index)")
            }
        }
    }

    func testYYCacheMemoryRead() throws {
        let cache = YYMemoryCache()
        cache.countLimit = UInt(operationCount)
        populate { cache.setObject(value, forKey: $0) }
        measure {
            for index in 0 ..< operationCount {
                _ = cache.object(forKey: "key-\(index)") as? Data
            }
        }
    }

    private func populate(_ insert: (String) -> Void) {
        for index in 0 ..< operationCount {
            insert("key-\(index)")
        }
    }
}
