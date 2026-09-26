import Foundation

enum BookmarkStore {
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        // Keep the bookmark URL as resolved. `standardizedFileURL` before
        // `startAccessingSecurityScopedResource` can drop the security scope.
        return (url, stale)
    }

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    // `.withSecurityScope` is macOS-only. iOS bookmarks still start access
    // through `ScopedRoot.startAccessingSecurityScopedResource`.
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}

/// Holds the security-scoped root so access lives as long as the app.
@MainActor
final class ScopedRoot {
    private(set) var url: URL?
    private var accessURL: URL?
    private var isAccessing = false

    @discardableResult
    func activate(_ url: URL) -> Bool {
        stop()
        let ok = url.startAccessingSecurityScopedResource()
        accessURL = url
        self.url = url.standardizedFileURL
        isAccessing = ok
        return ok
    }

    func stop() {
        if isAccessing, let accessURL {
            accessURL.stopAccessingSecurityScopedResource()
        }
        isAccessing = false
        accessURL = nil
        url = nil
    }
}
