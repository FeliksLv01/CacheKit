import Foundation

public struct FileCacheConfiguration: Sendable {
    public let directoryURL: URL
    public let maximumSize: Int64
    public let maximumFileCount: Int

    public init(directoryURL: URL, maximumSize: Int64, maximumFileCount: Int) {
        precondition(maximumSize > 0)
        precondition(maximumFileCount > 0)
        self.directoryURL = directoryURL
        self.maximumSize = maximumSize
        self.maximumFileCount = maximumFileCount
    }
}
