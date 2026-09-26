import Foundation

/// Memoizes immutable preview payloads — bundle files and generated
/// stylesheets — which were otherwise re-read and rebuilt on every render.
/// Keys must carry everything the value depends on (theme, appearance, style),
/// otherwise the wrong sheet gets frozen in.
final class PreviewAssetCache: @unchecked Sendable {
    static let shared = PreviewAssetCache()

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func value(for key: String, build: () -> String) -> String {
        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Built outside the lock: building never touches the cache.
        let value = build()

        lock.lock()
        storage[key] = value
        lock.unlock()
        return value
    }

    /// Tests only: forget everything so a fresh build is observable.
    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

/// Base64 copies of a note's local images. Deliberately *not* in
/// `PreviewAssetCache`: that one is an unbounded dictionary of bundle files
/// whose total size is known and fixed, while these values are megabytes each
/// and arrive from whatever the user's library contains — stored there they
/// would be a slow leak. `NSCache` is the right shape: it evicts under memory
/// pressure and is thread-safe on its own, so a preview that never comes back
/// costs nothing once the pressure arrives.
final class PreviewImageCache: @unchecked Sendable {
    static let shared = PreviewImageCache()

    private let storage = NSCache<NSString, NSString>()

    private init() {
        // A reading session revisits a handful of notes; the byte ceiling is
        // what actually bounds this, the count only keeps it tidy.
        storage.countLimit = 64
        storage.totalCostLimit = 64 * 1024 * 1024
    }

    /// `build` returning nil means "do not inline": nothing is stored, so the
    /// caller falls back to the `file://` URL every time.
    func value(for key: String, build: () -> String?) -> String? {
        if let cached = cached(for: key) { return cached }
        guard let value = build() else { return nil }
        store(value, for: key)
        return value
    }

    /// Lookup with no build behind it. This is what a main-thread render is
    /// allowed to call: a hit is a dictionary read, a miss costs nothing and
    /// sends the work to a background queue instead of doing it here.
    func cached(for key: String) -> String? {
        storage.object(forKey: key as NSString) as String?
    }

    func store(_ value: String, for key: String) {
        storage.setObject(value as NSString, forKey: key as NSString, cost: value.utf8.count)
    }

    /// Tests only.
    func removeAll() {
        storage.removeAllObjects()
    }
}
