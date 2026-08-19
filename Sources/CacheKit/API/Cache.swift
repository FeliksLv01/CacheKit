import Foundation

public final class Cache<Value: Sendable>: @unchecked Sendable {
    public let async: CacheAsync<Value>

    private let configuration: CacheConfiguration
    private let codec: CacheCodec<Value>
    private let memoryStorage: MemoryStorage<Value>?
    private let diskStorage: DiskStorage?
    private let now: @Sendable () -> Date

    public init(
        configuration: CacheConfiguration,
        codec: CacheCodec<Value>,
        fileManager: FileManager = .default,
        now: (@Sendable () -> Date)? = nil
    ) throws {
        self.configuration = configuration
        self.codec = codec
        self.now = now ?? { Date() }
        switch configuration.storageMode {
        case .memory:
            memoryStorage = MemoryStorage(
                countLimit: configuration.memoryCountLimit,
                costLimit: configuration.memoryCostLimit,
                now: now
            )
            diskStorage = nil
        case .disk:
            memoryStorage = nil
            diskStorage = try DiskStorage(configuration: configuration, fileManager: fileManager, now: self.now)
        case .hybrid:
            memoryStorage = MemoryStorage(
                countLimit: configuration.memoryCountLimit,
                costLimit: configuration.memoryCostLimit,
                now: now
            )
            diskStorage = try DiskStorage(configuration: configuration, fileManager: fileManager, now: self.now)
        }
        async = CacheAsync()
        async.bind(cache: self)
    }

    public func value(forKey key: String) throws -> Value? {
        if let value = memoryStorage?.value(forKey: key) {
            return value
        }
        guard let storedValue = try diskStorage?.value(forKey: key, now: now()) else {
            return nil
        }
        let value = try codec.decode(storedValue.data)
        memoryStorage?.setValue(
            value,
            forKey: key,
            cost: storedValue.data.count,
            expirationDate: storedValue.expirationDate
        )
        return value
    }

    public func values(forKeys keys: [String]) throws -> [String: Value] {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return [:] }
        var values: [String: Value] = [:]
        values.reserveCapacity(uniqueKeys.count)
        var diskKeys: [String] = []
        diskKeys.reserveCapacity(uniqueKeys.count)
        for key in uniqueKeys {
            if let value = memoryStorage?.value(forKey: key) {
                values[key] = value
            } else {
                diskKeys.append(key)
            }
        }
        guard let diskStorage, !diskKeys.isEmpty else { return values }
        let storedValues = try diskStorage.values(forKeys: diskKeys, now: now())
        for (key, storedValue) in storedValues {
            let value = try codec.decode(storedValue.data)
            values[key] = value
            memoryStorage?.setValue(
                value,
                forKey: key,
                cost: storedValue.data.count,
                expirationDate: storedValue.expirationDate
            )
        }
        return values
    }

    public func setValue(
        _ value: Value,
        forKey key: String,
        cost: Int? = nil,
        expiration: CacheExpiration? = nil
    ) throws {
        let currentDate = now()
        let expirationDate = (expiration ?? configuration.defaultExpiration).expirationDate(relativeTo: currentDate)
        if let diskStorage {
            let data = try codec.encode(value)
            try diskStorage.setValue(data, forKey: key, expirationDate: expirationDate, now: currentDate)
            memoryStorage?.setValue(value, forKey: key, cost: cost ?? data.count, expirationDate: expirationDate)
        } else {
            memoryStorage?.setValue(value, forKey: key, cost: cost ?? 0, expirationDate: expirationDate)
        }
    }

    public func setValues(
        _ values: [String: Value],
        expiration: CacheExpiration? = nil
    ) throws {
        guard !values.isEmpty else { return }
        let currentDate = now()
        let expirationDate = (expiration ?? configuration.defaultExpiration).expirationDate(relativeTo: currentDate)
        guard let diskStorage else {
            for (key, value) in values {
                memoryStorage?.setValue(value, forKey: key, expirationDate: expirationDate)
            }
            return
        }

        let encodedValues = try values.map { key, value in
            (key: key, value: value, data: try codec.encode(value))
        }
        try diskStorage.setValues(
            encodedValues.map {
                DiskStorage.ValueToStore(
                    key: $0.key,
                    data: $0.data,
                    expirationDate: expirationDate
                )
            },
            now: currentDate
        )
        for value in encodedValues {
            memoryStorage?.setValue(
                value.value,
                forKey: value.key,
                cost: value.data.count,
                expirationDate: expirationDate
            )
        }
    }

    public func removeValue(forKey key: String) throws {
        memoryStorage?.removeValue(forKey: key)
        try diskStorage?.removeValue(forKey: key)
    }

    public func removeValues(forKeys keys: [String]) throws {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return }
        for key in uniqueKeys {
            memoryStorage?.removeValue(forKey: key)
        }
        try diskStorage?.removeValues(forKeys: uniqueKeys)
    }

    public func removeAll() throws {
        memoryStorage?.removeAll()
        try diskStorage?.removeAll()
    }

}

public final class CacheAsync<Value: Sendable>: @unchecked Sendable {
    private weak var cache: Cache<Value>?
    private let queue = DispatchQueue(label: "com.cachekit.async", qos: .userInitiated, attributes: .concurrent)
    private let loadCoordinator = LoadCoordinator<Value>()

    fileprivate init() {}

    fileprivate func bind(cache: Cache<Value>) {
        self.cache = cache
    }

    public func value(forKey key: String) async throws -> Value? {
        try await perform { cache in
            try cache.value(forKey: key)
        }
    }

    public func values(forKeys keys: [String]) async throws -> [String: Value] {
        try await perform { cache in
            try cache.values(forKeys: keys)
        }
    }

    public func setValue(
        _ value: Value,
        forKey key: String,
        cost: Int? = nil,
        expiration: CacheExpiration? = nil
    ) async throws {
        try await perform { cache in
            try cache.setValue(value, forKey: key, cost: cost, expiration: expiration)
        }
    }

    public func setValues(
        _ values: [String: Value],
        expiration: CacheExpiration? = nil
    ) async throws {
        try await perform { cache in
            try cache.setValues(values, expiration: expiration)
        }
    }

    public func removeValue(forKey key: String) async throws {
        try await perform { cache in
            try cache.removeValue(forKey: key)
        }
    }

    public func removeValues(forKeys keys: [String]) async throws {
        try await perform { cache in
            try cache.removeValues(forKeys: keys)
        }
    }

    public func removeAll() async throws {
        try await perform { cache in
            try cache.removeAll()
        }
    }

    public func value(
        forKey key: String,
        cost: Int? = nil,
        expiration: CacheExpiration? = nil,
        orLoad loader: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let cachedValue = try await value(forKey: key) {
            return cachedValue
        }
        return try await loadCoordinator.value(forKey: key) { [weak cache] in
            guard let cache else { throw CacheError.deallocated }
            if let cachedValue = try cache.value(forKey: key) {
                return cachedValue
            }
            let value = try await loader()
            try cache.setValue(value, forKey: key, cost: cost, expiration: expiration)
            return value
        }
    }

    private func perform<Result: Sendable>(
        _ operation: @escaping @Sendable (Cache<Value>) throws -> Result
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

public enum CacheError: Error {
    case deallocated
}
