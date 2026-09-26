import XCTest
@testable import Shokonotes

final class BookmarkStoreTests: XCTestCase {
    func testMakeAndResolveRoundTripATemporaryFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = try BookmarkStore.makeBookmark(for: root)
        let resolved = try BookmarkStore.resolve(data)
        XCTAssertEqual(resolved.url.standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(resolved.stale)
    }
}

@MainActor
final class FileWatcherStubAPITests: XCTestCase {
    func testStartAndStopAcceptEmptyAndRealPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-watcher-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = FileWatcher { }
        watcher.start(paths: [])
        watcher.stop()
        watcher.start(paths: [root.path])
        watcher.stop()
    }
}
