import CryptoKit
import Foundation

final class FileCacheFileStore {
    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func prepare() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func fileURL(fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }

    func destinationURL(identifier: String, fileExtension: String) -> URL {
        fileURL(fileName: fileName(identifier: identifier, fileExtension: fileExtension))
    }

    func isUsableFile(_ url: URL, recordedSize: Int64? = nil) -> Bool {
        guard isRegularFile(url) else { return false }
        guard let recordedSize else { return true }
        return (try? fileSize(at: url)) == recordedSize
    }

    func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return false
        }
        return true
    }

    func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    func contentIdentifier(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try autoreleasepool {
                try handle.read(upToCount: 1024 * 1024)
            }
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "content-sha256:\(digest)"
    }

    func placeFile(from sourceURL: URL, at targetURL: URL, moveSource: Bool) throws {
        guard sourceURL.standardizedFileURL != targetURL.standardizedFileURL else { return }
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        if moveSource {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        }
    }

    func removeFile(fileName: String) {
        try? fileManager.removeItem(at: fileURL(fileName: fileName))
    }

    func removeFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func removeOrphanedFiles(retaining fileNames: Set<String>) {
        let retainedFileNames = fileNames.union([
            "cache.sqlite",
            "cache.sqlite-shm",
            "cache.sqlite-wal",
            "cache.sqlite-journal",
        ])
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for fileURL in fileURLs where !retainedFileNames.contains(fileURL.lastPathComponent) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    static func identifier(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileName(identifier: String, fileExtension: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalizedExtension = String(
            fileExtension
                .lowercased()
                .unicodeScalars
                .filter { allowedCharacters.contains($0) }
                .prefix(32)
        )
        return normalizedExtension.isEmpty ? identifier : "\(identifier).\(normalizedExtension)"
    }
}
