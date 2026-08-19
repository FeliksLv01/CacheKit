import Foundation

#if SWIFT_PACKAGE
import CacheKitObjC
#endif

public final class MemoryStorage<Value: Sendable>: @unchecked Sendable {
    private let backend: CacheMemoryBackend
    private let now: (@Sendable () -> Date)?

    public init(
        countLimit: Int,
        costLimit: Int,
        now: (@Sendable () -> Date)? = nil
    ) {
        precondition(countLimit >= 0)
        precondition(costLimit >= 0)
        backend = CacheMemoryBackend(countLimit: UInt(countLimit), costLimit: UInt(costLimit))
        self.now = now
    }

    public func value(forKey key: String) -> Value? {
        backend.object(forKey: key, now: now?().timeIntervalSince1970 ?? .nan) as? Value
    }

    public func setValue(_ value: Value, forKey key: String, cost: Int = 0, expirationDate: Date? = nil) {
        precondition(cost >= 0)
        backend.setObject(
            value,
            forKey: key,
            cost: UInt(cost),
            expiresAt: expirationDate?.timeIntervalSince1970 ?? .nan
        )
    }

    public func removeValue(forKey key: String) {
        backend.removeObject(forKey: key)
    }

    public func removeAll() {
        backend.removeAllObjects()
    }

    public var count: Int {
        Int(backend.count())
    }
}
