import Foundation

public struct CacheConfiguration: Sendable {
    public enum StorageMode: Sendable {
        case memory
        case disk
        case hybrid
    }

    public let name: String
    public let directoryURL: URL
    public let storageMode: StorageMode
    public let memoryCountLimit: Int
    public let memoryCostLimit: Int
    public let diskSizeLimit: Int64
    public let diskCountLimit: Int
    public let inlineValueThreshold: Int
    public let defaultExpiration: CacheExpiration

    public init(
        name: String,
        directoryURL: URL,
        storageMode: StorageMode = .hybrid,
        memoryCountLimit: Int = 100,
        memoryCostLimit: Int = 20 * 1024 * 1024,
        diskSizeLimit: Int64 = 200 * 1024 * 1024,
        diskCountLimit: Int = 0,
        inlineValueThreshold: Int = 20 * 1024,
        defaultExpiration: CacheExpiration = .never
    ) {
        precondition(!name.isEmpty)
        precondition(memoryCountLimit >= 0)
        precondition(memoryCostLimit >= 0)
        precondition(diskSizeLimit >= 0)
        precondition(diskCountLimit >= 0)
        precondition(inlineValueThreshold >= 0)
        self.name = name
        self.directoryURL = directoryURL
        self.storageMode = storageMode
        self.memoryCountLimit = memoryCountLimit
        self.memoryCostLimit = memoryCostLimit
        self.diskSizeLimit = diskSizeLimit
        self.diskCountLimit = diskCountLimit
        self.inlineValueThreshold = inlineValueThreshold
        self.defaultExpiration = defaultExpiration
    }
}

public enum CacheExpiration: Sendable, Equatable {
    case never
    case seconds(TimeInterval)
    case date(Date)

    func expirationDate(relativeTo now: Date) -> Date? {
        switch self {
        case .never:
            return nil
        case .seconds(let interval):
            return now.addingTimeInterval(interval)
        case .date(let date):
            return date
        }
    }
}
