import Foundation

final class DiskCoordinator: @unchecked Sendable {
    let mutationLock = UnfairLock()
    var externalFileNames: [String: String] = [:]
    var isExternalFileIndexLoaded = false
    private let generationPrefix = UUID().uuidString
    private var generationSequence: UInt64 = 0

    func nextGenerationAssumingLockHeld() -> String {
        generationSequence &+= 1
        return "\(generationPrefix)-\(generationSequence)"
    }
}

final class DiskCoordinatorRegistry: @unchecked Sendable {
    private struct Entry {
        let coordinator: DiskCoordinator
        var referenceCount: Int

        init(coordinator: DiskCoordinator) {
            self.coordinator = coordinator
            referenceCount = 1
        }
    }

    static let shared = DiskCoordinatorRegistry()

    private let lock = UnfairLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    func coordinator(for directoryURL: URL) -> DiskCoordinator {
        let path = directoryURL.path
        return lock.withLock {
            if var entry = entries[path] {
                entry.referenceCount += 1
                entries[path] = entry
                return entry.coordinator
            }
            let coordinator = DiskCoordinator()
            entries[path] = Entry(coordinator: coordinator)
            return coordinator
        }
    }

    func releaseCoordinator(for directoryURL: URL) {
        let path = directoryURL.path
        lock.withLock {
            guard var entry = entries[path] else { return }
            entry.referenceCount -= 1
            if entry.referenceCount == 0 {
                entries.removeValue(forKey: path)
            } else {
                entries[path] = entry
            }
        }
    }
}
