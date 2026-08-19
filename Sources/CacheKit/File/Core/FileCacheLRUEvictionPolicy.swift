import Foundation

struct FileCacheLRUEvictionPolicy {
    let maximumSize: Int64
    let maximumFileCount: Int

    func victims(
        entries: [FileCacheEntry],
        protectedIdentifiers: Set<String>
    ) -> [FileCacheEntry] {
        var totalSize = entries.reduce(Int64(0)) { $0 + $1.size }
        var remainingCount = entries.count
        var result: [FileCacheEntry] = []
        let candidates = entries
            .filter { !protectedIdentifiers.contains($0.identifier) }
            .sorted { $0.lastAccessTime < $1.lastAccessTime }

        for entry in candidates {
            guard remainingCount > maximumFileCount || totalSize > maximumSize else { break }
            result.append(entry)
            remainingCount -= 1
            totalSize -= entry.size
        }
        return result
    }
}
