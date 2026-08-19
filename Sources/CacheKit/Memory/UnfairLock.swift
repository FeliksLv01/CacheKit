import os.lock

final class UnfairLock: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<os_unfair_lock>

    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    @inline(__always)
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        os_unfair_lock_lock(storage)
        defer { os_unfair_lock_unlock(storage) }
        return try body()
    }
}
