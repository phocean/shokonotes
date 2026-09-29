import XCTest
@testable import Shokonotes

@MainActor
final class AppSettingsTests: XCTestCase {
    func testQuitOnCloseDefaultsToFalseEvenWithRetiredPreferenceEnabled() throws {
        let suite = "shokonotes-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(AppSettings(defaults: defaults).quitOnWindowClose)
        defaults.set(true, forKey: "quitOnWindowClose")
        XCTAssertFalse(AppSettings(defaults: defaults).quitOnWindowClose)
    }

    func testQuitOnCloseExplicitChoicePersistsAcrossSettingsInstances() throws {
        let suite = "shokonotes-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "quitOnWindowClose")
        let settings = AppSettings(defaults: defaults)

        settings.quitOnWindowClose = true
        let reopened = AppSettings(defaults: defaults)
        XCTAssertTrue(reopened.quitOnWindowClose)

        reopened.quitOnWindowClose = false
        XCTAssertFalse(AppSettings(defaults: defaults).quitOnWindowClose)
    }

    /// The folder column is the system sidebar unless he opts out: off by
    /// default, one key, and the choice survives a new settings instance.
    func testOpaqueSidebarIsOffByDefaultAndPersists() throws {
        let suite = "shokonotes-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.opaqueSidebar)
        XCTAssertEqual(defaults.object(forKey: "opaqueSidebar") as? Bool, false)

        settings.opaqueSidebar = true
        XCTAssertEqual(defaults.object(forKey: "opaqueSidebar") as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).opaqueSidebar)

        settings.opaqueSidebar = false
        XCTAssertFalse(AppSettings(defaults: defaults).opaqueSidebar)
    }

    /// `showInboxBadge` moved in the same diff that renamed another key. Its own
    /// key must be untouched, so an existing preference keeps being read.
    func testInboxBadgeKeepsItsUserDefaultsKey() throws {
        let suite = "shokonotes-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(AppSettings(defaults: defaults).showInboxBadge)

        // A preference written by an earlier version of the app.
        defaults.set(true, forKey: "showInboxBadge")
        XCTAssertTrue(AppSettings(defaults: defaults).showInboxBadge)

        let settings = AppSettings(defaults: defaults)
        settings.showInboxBadge = false
        XCTAssertEqual(defaults.object(forKey: "showInboxBadge") as? Bool, false)
        XCTAssertFalse(AppSettings(defaults: defaults).showInboxBadge)

        settings.showInboxBadge = true
        XCTAssertEqual(defaults.object(forKey: "showInboxBadge") as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).showInboxBadge)
    }

    func testLastSelectedTagsUsesItsOwnUserDefaultsKey() throws {
        let suite = "shokonotes-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.lastSelectedTags, [])
        XCTAssertNil(defaults.object(forKey: "lastSelectedTags"))

        settings.lastSelectedTags = ["dfir", "iso"]
        XCTAssertEqual(defaults.stringArray(forKey: "lastSelectedTags"), ["dfir", "iso"])
        XCTAssertEqual(AppSettings(defaults: defaults).lastSelectedTags, ["dfir", "iso"])
        XCTAssertNil(defaults.object(forKey: "lastSidebarToken"), "the tag set must not overload lastSidebarToken")
    }

    func testIncludeFolderDescendantsDefaultsTrueOnAFreshSuite() throws {
        let suite = "shokonotes-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(defaults.object(forKey: "includeFolderDescendants"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.includeFolderDescendants)
        XCTAssertEqual(defaults.object(forKey: "includeFolderDescendants") as? Bool, true)

        settings.includeFolderDescendants = false
        XCTAssertFalse(AppSettings(defaults: defaults).includeFolderDescendants)
    }

    func testInjectedDefaultsKeepTheBookmarkOnThatSuite() throws {
        let suite = "shokonotes-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let bookmark = Data("injected-bookmark".utf8)
        settings.storageBookmark = bookmark
        XCTAssertEqual(defaults.data(forKey: AppGroup.bookmarkKey), bookmark)
        XCTAssertEqual(AppSettings(defaults: defaults).storageBookmark, bookmark)
    }

    func testStorageBookmarkDualWritesToInjectedGroup() throws {
        let standardSuite = "shokonotes-dual-std-\(UUID().uuidString)"
        let groupSuite = "shokonotes-dual-group-\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            group.removePersistentDomain(forName: groupSuite)
        }

        let settings = AppSettings(defaults: standard, groupDefaults: group)
        let bookmark = Data("kiji-bookmark".utf8)
        settings.storageBookmark = bookmark
        XCTAssertEqual(standard.data(forKey: AppGroup.bookmarkKey), bookmark)
        XCTAssertEqual(group.data(forKey: AppGroup.bookmarkKey), bookmark)
        XCTAssertEqual(settings.storageBookmark, bookmark)
    }

    func testStorageBookmarkDualWriteRemovesFromGroup() throws {
        let standardSuite = "shokonotes-dual-std-\(UUID().uuidString)"
        let groupSuite = "shokonotes-dual-group-\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            group.removePersistentDomain(forName: groupSuite)
        }

        let settings = AppSettings(defaults: standard, groupDefaults: group)
        settings.storageBookmark = Data("kiji-bookmark".utf8)
        settings.storageBookmark = nil
        XCTAssertNil(standard.data(forKey: AppGroup.bookmarkKey))
        XCTAssertNil(group.data(forKey: AppGroup.bookmarkKey))
        XCTAssertNil(settings.storageBookmark)
    }

    func testStorageBookmarkGetterIgnoresGroup() throws {
        let standardSuite = "shokonotes-dual-std-\(UUID().uuidString)"
        let groupSuite = "shokonotes-dual-group-\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            group.removePersistentDomain(forName: groupSuite)
        }

        let settings = AppSettings(defaults: standard, groupDefaults: group)
        group.set(Data("group-only".utf8), forKey: AppGroup.bookmarkKey)
        XCTAssertNil(settings.storageBookmark)
    }

    func testMirrorBookmarkNoopsWhenGroupIsNil() {
        AppGroup.mirrorBookmark(Data("ignored".utf8), onto: nil)
    }

    func testMigrateBookmarkCopiesFromGroupWhenStandardHasNone() throws {
        let standardSuite = "shokonotes-migrate-std-\(UUID().uuidString)"
        let groupSuite = "shokonotes-migrate-group-\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            group.removePersistentDomain(forName: groupSuite)
        }

        let bookmark = Data("kiji-bookmark".utf8)
        group.set(bookmark, forKey: AppGroup.bookmarkKey)
        XCTAssertNil(standard.data(forKey: AppGroup.bookmarkKey))

        AppGroup.migrateBookmarkIfNeeded(into: standard, from: group)
        XCTAssertEqual(standard.data(forKey: AppGroup.bookmarkKey), bookmark)
    }

    func testMigrateBookmarkDoesNotOverwriteAnExistingStandardValue() throws {
        let standardSuite = "shokonotes-migrate-std-\(UUID().uuidString)"
        let groupSuite = "shokonotes-migrate-group-\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            group.removePersistentDomain(forName: groupSuite)
        }

        standard.set(Data("kept".utf8), forKey: AppGroup.bookmarkKey)
        group.set(Data("old".utf8), forKey: AppGroup.bookmarkKey)
        AppGroup.migrateBookmarkIfNeeded(into: standard, from: group)
        XCTAssertEqual(standard.data(forKey: AppGroup.bookmarkKey), Data("kept".utf8))
    }

    func testMigrateBookmarkNoopsWhenGroupHasNone() throws {
        let standardSuite = "shokonotes-migrate-std-\(UUID().uuidString)"
        let groupSuite = "shokonotes-migrate-group-\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            group.removePersistentDomain(forName: groupSuite)
        }

        AppGroup.migrateBookmarkIfNeeded(into: standard, from: group)
        XCTAssertNil(standard.data(forKey: AppGroup.bookmarkKey))
    }

    func testResolvedStorageBookmarkPrefersStandardThenGroup() throws {
        let standardSuite = "shokonotes-resolve-std-\(UUID().uuidString)"
        let groupSuite = "shokonotes-resolve-group-\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            group.removePersistentDomain(forName: groupSuite)
        }

        XCTAssertNil(AppGroup.resolvedStorageBookmark(standard: standard, group: group))

        group.set(Data("group".utf8), forKey: AppGroup.bookmarkKey)
        XCTAssertEqual(
            AppGroup.resolvedStorageBookmark(standard: standard, group: group),
            Data("group".utf8)
        )

        standard.set(Data("standard".utf8), forKey: AppGroup.bookmarkKey)
        XCTAssertEqual(
            AppGroup.resolvedStorageBookmark(standard: standard, group: group),
            Data("standard".utf8)
        )
    }
}
