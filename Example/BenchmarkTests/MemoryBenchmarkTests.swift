import Cache
import CacheKit
import XCTest
import YYCache

final class MemoryBenchmarkTests: XCTestCase {
    private let keys = (0 ..< 100_000).map { "key-\($0)" }
    private let value = Data(repeating: 0x5a, count: 256)

    func testCacheKitMemoryWrite() throws {
        let cache = CacheKit.MemoryStorage<Data>(countLimit: keys.count, costLimit: 0)
        measure {
            for key in keys {
                cache.setValue(value, forKey: key)
            }
            cache.removeAll()
        }
    }

    func testHyperosloMemoryWrite() throws {
        let cache = MemoryStorage<String, Data>(config: MemoryConfig(countLimit: UInt(keys.count)))
        measure {
            for key in keys {
                cache.setObject(value, forKey: key)
            }
            cache.removeAll()
        }
    }

    func testYYCacheMemoryWrite() throws {
        let cache = YYMemoryCache()
        cache.countLimit = UInt(keys.count)
        measure {
            for key in keys {
                cache.setObject(value, forKey: key)
            }
            cache.removeAllObjects()
        }
    }

    func testCacheKitMemoryRead() throws {
        let cache = CacheKit.MemoryStorage<Data>(countLimit: keys.count, costLimit: 0)
        populate { cache.setValue(value, forKey: $0) }
        measure {
            for key in keys {
                _ = cache.value(forKey: key)
            }
        }
    }

    func testHyperosloMemoryRead() throws {
        let cache = MemoryStorage<String, Data>(config: MemoryConfig(countLimit: UInt(keys.count)))
        populate { cache.setObject(value, forKey: $0) }
        measure {
            for key in keys {
                _ = try? cache.object(forKey: key)
            }
        }
    }

    func testYYCacheMemoryRead() throws {
        let cache = YYMemoryCache()
        cache.countLimit = UInt(keys.count)
        populate { cache.setObject(value, forKey: $0) }
        measure {
            for key in keys {
                _ = cache.object(forKey: key) as? Data
            }
        }
    }

    private func populate(_ insert: (String) -> Void) {
        for key in keys {
            insert(key)
        }
    }
}
