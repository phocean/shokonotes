import XCTest
@testable import Shokonotes

@MainActor
final class SampleLibraryTests: XCTestCase {
    private var dest: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: LibraryModel!
    private let fm = FileManager.default

    override func setUp() async throws {
        dest = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-sample-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Sample Library", isDirectory: true)
        suiteName = "shokonotes-sample-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        model = makeModel()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: dest.deletingLastPathComponent())
    }

    private func makeModel() -> LibraryModel {
        let model = LibraryModel(
            settings: AppSettings(defaults: defaults),
            store: LibraryStore()
        )
        model.errorPresenter = { _ in }
        model.bookmarkFactory = { _ in Data("sample-bookmark".utf8) }
        model.preferredLocalization = { "en" }
        model.sampleLibrarySourceURL = { locale in Self.fixture(locale) }
        model.sampleLibraryDestinationURL = { [unowned self] _ in self.dest }
        return model
    }

    private static func fixture(_ locale: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shokonotes/Resources/SampleLibrary/\(locale)", isDirectory: true)
    }

    private func folder(named name: String, in items: [FolderSnapshot]? = nil) -> FolderSnapshot? {
        var pending = items ?? model.folders
        var index = 0
        while index < pending.count {
            let item = pending[index]
            index += 1
            if item.name == name { return item }
            if let children = item.children { pending.append(contentsOf: children) }
        }
        return nil
    }

    /// App Store Connect rejects the Mac package when bundled paths are not
    /// ASCII (see `SampleLibrary.decodeNames`). Every name stays encoded.
    func testBundledSamplePathsAreASCII() throws {
        let root = Self.fixture("en").deletingLastPathComponent()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let offenders = enumerator.compactMap { $0 as? URL }
            .map(\.lastPathComponent)
            .filter { !$0.allSatisfy(\.isASCII) }
        XCTAssertEqual(offenders, [])
    }

    func testDefaultDestinationLivesInApplicationSupport() {
        let url = SampleLibrary.defaultDestinationURL()
        XCTAssertEqual(url.lastPathComponent, "Sample Library-en")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Shokonotes")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testLocaleCodeMapsKnownPrefixesOtherwiseEnglish() {
        XCTAssertEqual(SampleLibrary.localeCode(from: "fr"), "fr")
        XCTAssertEqual(SampleLibrary.localeCode(from: "fr-CA"), "fr")
        XCTAssertEqual(SampleLibrary.localeCode(from: "FR"), "fr")
        XCTAssertEqual(SampleLibrary.localeCode(from: "en"), "en")
        XCTAssertEqual(SampleLibrary.localeCode(from: "en-GB"), "en")
        XCTAssertEqual(SampleLibrary.localeCode(from: "de"), "de")
        XCTAssertEqual(SampleLibrary.localeCode(from: "de-DE"), "de")
        XCTAssertEqual(SampleLibrary.localeCode(from: "es-MX"), "es")
        XCTAssertEqual(SampleLibrary.localeCode(from: "it"), "it")
        XCTAssertEqual(SampleLibrary.localeCode(from: "ja-JP"), "ja")
        XCTAssertEqual(SampleLibrary.localeCode(from: "ko"), "ko")
        XCTAssertEqual(SampleLibrary.localeCode(from: "ru"), "ru")
        XCTAssertEqual(SampleLibrary.localeCode(from: "ru-RU"), "ru")
        XCTAssertEqual(SampleLibrary.localeCode(from: "pt-BR"), "pt-BR")
        XCTAssertEqual(SampleLibrary.localeCode(from: "pt-PT"), "pt-BR")
        XCTAssertEqual(SampleLibrary.localeCode(from: "zh-Hans"), "zh-Hans")
        XCTAssertEqual(SampleLibrary.localeCode(from: "zh-CN"), "zh-Hans")
        XCTAssertEqual(SampleLibrary.localeCode(from: "nl"), "en")
    }

    func testCopySeedsNotesPinTagSymbolsAndFavourites() throws {
        var requestedLocale: String?
        model.sampleLibrarySourceURL = { locale in
            requestedLocale = locale
            return Self.fixture(locale)
        }

        model.openSampleLibrary()

        XCTAssertEqual(requestedLocale, "en")
        XCTAssertEqual(model.rootURL?.standardizedFileURL, dest.standardizedFileURL)
        XCTAssertEqual(model.notes.count, 7)
        XCTAssertTrue(model.tags.contains("recipes"))

        let shopping = model.notes.first { $0.relativePath == "Shopping.md" }
        XCTAssertEqual(shopping?.isPinned, true)
        XCTAssertEqual(model.notes.filter(\.isPinned).map(\.relativePath), ["Shopping.md"])

        XCTAssertEqual(folder(named: "Recipes")?.symbol, "fork.knife")
        XCTAssertEqual(folder(named: "Home")?.symbol, "house")
        XCTAssertEqual(folder(named: "Projects")?.symbol, "briefcase")

        XCTAssertEqual(model.favourites, [
            .folder("Recipes"),
            .tag("recipes"),
            .note("Recipes/Bouillabaisse.md"),
        ])

        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Recipes/bouillabaisse.png").path))
        XCTAssertTrue(fm.fileExists(atPath: LibraryPaths.pinsURL(root: dest).path))
        XCTAssertEqual(model.settings.storageBookmark, Data("sample-bookmark".utf8))
    }

    func testSecondCallDoesNotOverwriteEdits() throws {
        model.openSampleLibrary()
        let shopping = dest.appendingPathComponent("Shopping.md")
        var text = try String(contentsOf: shopping, encoding: .utf8)
        text += "\n- Butter\n"
        try text.write(to: shopping, atomically: true, encoding: .utf8)

        var copied = false
        model.sampleLibrarySourceURL = { locale in
            copied = true
            return Self.fixture(locale)
        }
        model.openSampleLibrary()

        XCTAssertFalse(copied, "a destination that already has notes must not recopy")
        let after = try String(contentsOf: shopping, encoding: .utf8)
        XCTAssertTrue(after.contains("Butter"))
        XCTAssertEqual(model.rootURL?.standardizedFileURL, dest.standardizedFileURL)
    }

    func testEmptyDestinationIsSeeded() throws {
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        XCTAssertTrue(fm.fileExists(atPath: dest.path))
        XCTAssertFalse(SampleLibrary.containsNotes(at: dest))

        model.openSampleLibrary()

        XCTAssertEqual(model.notes.count, 7)
        XCTAssertEqual(model.notes.first { $0.relativePath == "Shopping.md" }?.isPinned, true)
    }

    func testFrenchSourceOverrideOpensRecettesCoursesAndRecettesFavourite() throws {
        var requestedLocale: String?
        model.preferredLocalization = { "fr-FR" }
        model.sampleLibrarySourceURL = { locale in
            requestedLocale = locale
            return Self.fixture(locale)
        }

        model.openSampleLibrary()

        XCTAssertEqual(requestedLocale, "fr")
        XCTAssertNotNil(folder(named: "Recettes"))
        XCTAssertEqual(model.notes.first { $0.relativePath == "Courses.md" }?.isPinned, true)
        XCTAssertTrue(model.tags.contains("recettes"))
        XCTAssertEqual(model.favourites, [
            .folder("Recettes"),
            .tag("recettes"),
            .note("Recettes/Bouillabaisse.md"),
        ])
        XCTAssertEqual(folder(named: "Recettes")?.symbol, "fork.knife")
        XCTAssertEqual(folder(named: "Maison")?.symbol, "house")
        XCTAssertEqual(folder(named: "Projets")?.symbol, "briefcase")
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Recettes/bouillabaisse.png").path))
    }

    func testKoreanSourceGetsTranslatedTreeAndSharedImage() throws {
        model.preferredLocalization = { "ko-KR" }
        model.sampleLibrarySourceURL = { locale in Self.fixture(locale) }

        model.openSampleLibrary()

        XCTAssertNotNil(folder(named: "레시피"))
        XCTAssertEqual(model.notes.first { $0.relativePath == "장보기.md" }?.isPinned, true)
        XCTAssertTrue(model.tags.contains("레시피"))
        XCTAssertEqual(model.favourites, [
            .folder("레시피"),
            .tag("레시피"),
            .note("레시피/부야베스.md"),
        ])
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("레시피/bouillabaisse.png").path))
    }

    func testMissingSourcePresentsAndLeavesRootNil() {
        var presented: Error?
        model.errorPresenter = { presented = $0 }
        model.sampleLibrarySourceURL = { _ in nil }

        model.openSampleLibrary()

        XCTAssertEqual(presented as? LibraryError, .sampleLibraryMissing)
        XCTAssertNil(model.rootURL)
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
        XCTAssertNil(model.settings.storageBookmark)
    }

    func testCopyFailurePresentsAndLeavesRootNil() throws {
        let blocker = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-sample-block-\(UUID().uuidString)")
        try Data("not-a-dir".utf8).write(to: blocker)
        defer { try? fm.removeItem(at: blocker) }

        var presented: Error?
        model.errorPresenter = { presented = $0 }
        model.sampleLibraryDestinationURL = { _ in
            blocker.appendingPathComponent("Sample Library", isDirectory: true)
        }

        model.openSampleLibrary()

        XCTAssertEqual(presented as? LibraryError, .sampleLibraryCopyFailed)
        XCTAssertNil(model.rootURL)
        XCTAssertNil(model.settings.storageBookmark)
    }

    func testOpenSampleLibraryUsesOpenRootAndStoresBookmark() throws {
        var bookmarked: URL?
        model.bookmarkFactory = { url in
            bookmarked = url
            return Data("sample-bookmark".utf8)
        }

        model.openSampleLibrary()

        XCTAssertEqual(bookmarked?.standardizedFileURL, dest.standardizedFileURL)
        XCTAssertEqual(model.rootURL?.standardizedFileURL, dest.standardizedFileURL)
        XCTAssertEqual(model.store.root?.standardizedFileURL, dest.standardizedFileURL)
        XCTAssertEqual(model.settings.storageBookmark, Data("sample-bookmark".utf8))
        XCTAssertEqual(model.settings.lastSidebarToken, "all")
    }

    func testSecondOpenAfterBookmarkRoundTripFindsTheCopy() throws {
        model.openSampleLibrary()
        let shopping = dest.appendingPathComponent("Shopping.md")
        var text = try String(contentsOf: shopping, encoding: .utf8)
        text += "\n- Butter\n"
        try text.write(to: shopping, atomically: true, encoding: .utf8)
        XCTAssertEqual(model.settings.storageBookmark, Data("sample-bookmark".utf8))

        let restored = makeModel()
        restored.settings.storageBookmark = Data("sample-bookmark".utf8)
        restored.sampleLibrarySourceURL = { _ in
            XCTFail("existing notes must not recopy")
            return nil
        }

        restored.openSampleLibrary()

        XCTAssertEqual(restored.rootURL?.standardizedFileURL, dest.standardizedFileURL)
        XCTAssertEqual(restored.settings.storageBookmark, Data("sample-bookmark".utf8))
        let after = try String(contentsOf: shopping, encoding: .utf8)
        XCTAssertTrue(after.contains("Butter"))
        XCTAssertEqual(restored.notes.first { $0.relativePath == "Shopping.md" }?.isPinned, true)
    }

    func testBundledEnglishLibraryCopiesSidecars() throws {
        model.sampleLibrarySourceURL = { locale in
            Bundle.main.url(forResource: locale, withExtension: nil, subdirectory: "SampleLibrary")
                ?? Bundle.main.url(forResource: locale, withExtension: nil)
        }

        model.openSampleLibrary()

        XCTAssertEqual(model.notes.count, 7)
        XCTAssertEqual(model.notes.first { $0.relativePath == "Shopping.md" }?.isPinned, true)
        XCTAssertEqual(model.favourites, [
            .folder("Recipes"),
            .tag("recipes"),
            .note("Recipes/Bouillabaisse.md"),
        ])
        XCTAssertEqual(folder(named: "Recipes")?.symbol, "fork.knife")
    }
}
