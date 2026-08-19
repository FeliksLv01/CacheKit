import Foundation

public protocol FileCacheKeyFiltering: Sendable {
    func cacheKey(for url: URL) -> String?
}

public struct FileCacheKeyFilter: FileCacheKeyFiltering {
    public static let absoluteString = FileCacheKeyFilter { $0.absoluteString }

    private let block: @Sendable (URL) -> String?

    public init(block: @escaping @Sendable (URL) -> String?) {
        self.block = block
    }

    public func cacheKey(for url: URL) -> String? {
        block(url)
    }
}
