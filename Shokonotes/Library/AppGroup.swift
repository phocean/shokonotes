import Foundation

/// App Group identifier for the share extension.
/// The live iOS bookmark lives in `UserDefaults.standard` (same as Mac);
/// iOS also mirrors it into this suite so a signed extension can write.
/// A free personal team cannot sign `application-groups`.
enum AppGroup {
    static let identifier = "group.com.jcbaptiste.shokonotes"
    static let bookmarkKey = "storageBookmark"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// Standard first, then the group suite, so a bookmark copied into
    /// the group by an earlier build is not stranded.
    static var storageBookmark: Data? {
        resolvedStorageBookmark(standard: .standard, group: defaults)
    }

    static func resolvedStorageBookmark(
        standard: UserDefaults,
        group: UserDefaults?
    ) -> Data? {
        standard.data(forKey: bookmarkKey) ?? group?.data(forKey: bookmarkKey)
    }

    /// Earlier iOS builds stored the bookmark in the App Group suite.
    /// Copy group → standard when standard has none. Never overwrite
    /// a standard value.
    static func migrateBookmarkIfNeeded(
        into standard: UserDefaults = .standard,
        from group: UserDefaults? = defaults
    ) {
        guard standard.data(forKey: bookmarkKey) == nil,
              let existing = group?.data(forKey: bookmarkKey) else { return }
        standard.set(existing, forKey: bookmarkKey)
    }

    /// Mirror a bookmark onto the group suite, or remove it. No-op when
    /// there is no suite (unsigned personal team).
    static func mirrorBookmark(_ data: Data?, onto group: UserDefaults?) {
        guard let group else { return }
        if let data {
            group.set(data, forKey: bookmarkKey)
        } else {
            group.removeObject(forKey: bookmarkKey)
        }
    }
}
