import XCTest
@testable import Shokonotes

@MainActor
final class WatcherTests: XCTestCase {
    func testExternalSaveShowsUpWithoutClick() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults(suiteName: "shokonotes.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let model = LibraryModel(settings: settings, store: LibraryStore())
        model.openRoot(root)

        let marker = "watcher-token-\(UUID().uuidString)"
        let url = root.appendingPathComponent("from-editor.md")
        try """
        ---
        title: "From editor"
        tags: []
        created: 2026-09-09
        ---

        \(marker)
        """.write(to: url, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if model.store.snapshots().contains(where: { $0.matches(terms: [marker]) }) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("FSEvents refresh did not pick up \(url.path)")
    }
}
