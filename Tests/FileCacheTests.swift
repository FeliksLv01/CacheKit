import XCTest
@testable import CacheKit

final class FileCacheTests: XCTestCase {
    func testAliasesResolveSameImportedFile() async throws {
        let fixture = try Fixture(maximumSize: 100, maximumFileCount: 10)
        let sourceURL = try fixture.makeFile(name: "source.txt", contents: "hello")
        let cachedURL = try await fixture.cache.async.importFile(
            from: sourceURL,
            keys: ["local"],
            fileExtension: "txt"
        )

        let boundURL = try await fixture.cache.async.bind(
            keys: ["server", "https://cdn.example.com/file"],
            toAnyExistingKey: ["local"]
        )

        XCTAssertEqual(boundURL, cachedURL)
        let serverURL = try await fixture.cache.async.fileURL(for: ["server"])
        let remoteURL = try await fixture.cache.async.fileURL(for: ["https://cdn.example.com/file"])
        XCTAssertEqual(serverURL, cachedURL)
        XCTAssertEqual(remoteURL, cachedURL)
    }

    func testLeastRecentlyUsedFileIsEvicted() async throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1))
        let fixture = try Fixture(maximumSize: 10, maximumFileCount: 2, now: { clock.now() })

        for index in 1 ... 2 {
            let sourceURL = try fixture.makeFile(name: "\(index).txt", contents: "\(index)")
            _ = try await fixture.cache.async.importFile(from: sourceURL, keys: ["\(index)"], fileExtension: "txt")
            clock.advance(by: 1)
        }
        _ = try await fixture.cache.async.fileURL(for: ["1"])
        clock.advance(by: 1)
        let sourceURL = try fixture.makeFile(name: "3.txt", contents: "3")
        _ = try await fixture.cache.async.importFile(from: sourceURL, keys: ["3"], fileExtension: "txt")

        let firstURL = try await fixture.cache.async.fileURL(for: ["1"])
        let secondURL = try await fixture.cache.async.fileURL(for: ["2"])
        let thirdURL = try await fixture.cache.async.fileURL(for: ["3"])
        XCTAssertNotNil(firstURL)
        XCTAssertNil(secondURL)
        XCTAssertNotNil(thirdURL)
    }

    func testIndexSurvivesCacheRecreation() async throws {
        let fixture = try Fixture(maximumSize: 100, maximumFileCount: 10)
        let sourceURL = try fixture.makeFile(name: "source.pdf", contents: "pdf")
        let cachedURL = try await fixture.cache.async.importFile(
            from: sourceURL,
            keys: ["persisted"],
            fileExtension: "pdf"
        )

        let restoredCache = try fixture.makeCache()
        let restoredURL = try await restoredCache.async.fileURL(for: ["persisted"])
        XCTAssertEqual(restoredURL, cachedURL)
    }

    func testLeasedFileIsNotEvictedUntilLeaseIsReleased() async throws {
        let fixture = try Fixture(maximumSize: 100, maximumFileCount: 1)
        let firstSourceURL = try fixture.makeFile(name: "first.txt", contents: "first")
        let firstURL = try await fixture.cache.async.importFile(from: firstSourceURL, keys: ["first"], fileExtension: "txt")
        let leaseID = try await fixture.cache.async.acquireLease(for: ["first"])

        let secondSourceURL = try fixture.makeFile(name: "second.txt", contents: "second")
        _ = try await fixture.cache.async.importFile(from: secondSourceURL, keys: ["second"], fileExtension: "txt")

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        guard let leaseID else { return XCTFail("Expected lease") }
        try await fixture.cache.async.releaseLease(leaseID)
        let releasedURL = try await fixture.cache.async.fileURL(for: ["first"])
        XCTAssertNil(releasedURL)
    }

    func testURLKeyFilterDefaultsToAbsoluteStringAndSupportsCustomization() {
        guard let url = URL(string: "https://cdn.example.com/file.pdf?token=one") else {
            return XCTFail("Expected URL")
        }
        XCTAssertEqual(FileCacheKeyFilter.absoluteString.cacheKey(for: url), url.absoluteString)

        let filter = FileCacheKeyFilter { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return components?.url?.absoluteString
        }
        XCTAssertEqual(filter.cacheKey(for: url), "https://cdn.example.com/file.pdf")
    }

    func testSameContentIsStoredOnceAndCacheDirectoryRemainsFlat() async throws {
        let fixture = try Fixture(maximumSize: 100, maximumFileCount: 10)
        let firstSourceURL = try fixture.makeFile(name: "first.txt", contents: "same")
        let secondSourceURL = try fixture.makeFile(name: "second.txt", contents: "same")

        let firstURL = try await fixture.cache.async.importFile(from: firstSourceURL, keys: ["first"], fileExtension: "txt")
        let secondURL = try await fixture.cache.async.importFile(from: secondSourceURL, keys: ["second"], fileExtension: "txt")

        XCTAssertEqual(firstURL, secondURL)
        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.configuration.directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        XCTAssertEqual(Set(children.map(\.lastPathComponent)), Set([firstURL.lastPathComponent, "cache.sqlite"]))
        for child in children {
            XCTAssertNotEqual(try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        }
    }

    func testSynchronousAPIImportsAndReadsFile() throws {
        let fixture = try Fixture(maximumSize: 100, maximumFileCount: 10)
        let sourceURL = try fixture.makeFile(name: "sync.txt", contents: "sync")
        let importedURL = try fixture.cache.importFile(from: sourceURL, keys: ["sync"], fileExtension: "txt")

        XCTAssertEqual(try fixture.cache.fileURL(for: ["sync"]), importedURL)
    }

    func testAsyncLoaderDownloadsSameKeyOnce() async throws {
        let fixture = try Fixture(maximumSize: 100, maximumFileCount: 10)
        let counter = InvocationCounter()
        let loader: @Sendable (URL) async throws -> Void = { destinationURL in
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            try Data("downloaded".utf8).write(to: destinationURL)
        }

        async let first = fixture.cache.async.fileURL(
            for: ["https://cdn.example.com/file"],
            fileExtension: "pdf",
            orLoad: loader
        )
        async let second = fixture.cache.async.fileURL(
            for: ["https://cdn.example.com/file"],
            fileExtension: "pdf",
            orLoad: loader
        )
        let urls = try await (first, second)
        let invocationCount = await counter.value

        XCTAssertEqual(urls.0, urls.1)
        XCTAssertEqual(urls.0.pathExtension, "pdf")
        XCTAssertEqual(invocationCount, 1)
    }

    func testFileExtensionCannotCreateNestedPath() throws {
        let fixture = try Fixture(maximumSize: 100, maximumFileCount: 10)
        let destinationURL = try fixture.cache.destinationURL(
            primaryKey: "safe",
            fileExtension: "../../PDF"
        )

        XCTAssertEqual(destinationURL.deletingLastPathComponent().path, fixture.configuration.directoryURL.path)
        XCTAssertTrue(destinationURL.lastPathComponent.hasSuffix(".pdf.cachekitdownload"))
    }
}

private final class Fixture {
    let rootURL: URL
    let configuration: FileCacheConfiguration
    let now: @Sendable () -> Date
    let cache: FileCache

    init(
        maximumSize: Int64,
        maximumFileCount: Int,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configuration = FileCacheConfiguration(
            directoryURL: rootURL.appendingPathComponent("cache"),
            maximumSize: maximumSize,
            maximumFileCount: maximumFileCount
        )
        self.now = now
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        cache = try FileCache(configuration: configuration, now: now)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeCache() throws -> FileCache {
        try FileCache(configuration: configuration, now: now)
    }

    func makeFile(name: String, contents: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
