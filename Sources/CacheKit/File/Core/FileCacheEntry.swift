import Foundation

struct FileCacheEntry: Sendable {
    let identifier: String
    var fileName: String
    var size: Int64
    var lastAccessTime: TimeInterval
}
