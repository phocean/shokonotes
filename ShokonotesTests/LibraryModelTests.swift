import XCTest
@testable import Shokonotes

@MainActor
final class LibraryModelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var model: LibraryModel!
    private var openedURLs: [URL] = []
    private var openedBundle: String?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "shokonotes-model-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let store = LibraryStore()
        openedURLs = []
        openedBundle = nil
        model = LibraryModel(settings: settings, store: store) { [weak self] urls, bundle in
            self?.openedURLs = urls
            self?.openedBundle = bundle
        }
        model.openRoot(root, skipActivate: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSelectAllVisibleNotes() throws {
        _ = try model.store.createNote(
            named: "One", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "One")
        )
        _ = try model.store.createNote(
            named: "Two", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Two")
        )
        model.reloadEverything()
        XCTAssertEqual(model.notes.count, 2)
        model.selectedNoteIDs = [model.notes[0].url]
        model.selectAllVisibleNotes()
        XCTAssertEqual(model.selectedNoteIDs, Set(model.notes.map(\.url)))
    }

    func testQuickNoteOpensInboxInConfiguredEditorAndPreservesReadingContext() throws {
        let folder = try model.store.createFolder(named: "Project", parent: root)
        let existing = try model.store.createNote(
            named: "Reading", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Reading")
        )
        model.reloadEverything()
        model.sidebarSelection = .project(folder)
        model.searchText = "Reading"
        model.selectedNoteIDs = [existing.url]
        model.focusedPane = .preview
        model.previewFindVisible = true
        model.previewFindQuery = "passage"
        model.settings.openEditorOnCreate = false
        model.settings.externalEditorBundle = "test.editor"

        model.createQuickNote()

        XCTAssertEqual(openedURLs.count, 1)
        XCTAssertEqual(openedURLs.first?.deletingLastPathComponent(), root)
        XCTAssertEqual(openedBundle, "test.editor")
        XCTAssertEqual(model.inboxCount, 1)
        XCTAssertEqual(model.sidebarSelection, .project(folder))
        XCTAssertEqual(model.searchText, "Reading")
        XCTAssertEqual(model.selectedNoteIDs, [existing.url])
        XCTAssertEqual(model.focusedNote?.url, existing.url)
        XCTAssertEqual(model.focusedPane, .preview)
        XCTAssertTrue(model.previewFindVisible)
        XCTAssertEqual(model.previewFindQuery, "passage")
    }

    func testQuickNotePreservesEmptySelection() {
        model.selectedNoteIDs = []
        model.createQuickNote()
        // Exercise the disk reload used by the coalesced watcher as well.
        model.reloadFromDisk()
        XCTAssertTrue(model.selectedNoteIDs.isEmpty)
        XCTAssertEqual(model.sidebarSelection, .all)
        XCTAssertEqual(model.notes.count, 1)
    }

    func testDiskReloadReconcilesExternallyDeletedSelection() throws {
        let removed = try model.store.createNote(
            named: "Removed", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Removed")
        )
        let remaining = try model.store.createNote(
            named: "Remaining", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Remaining")
        )
        model.reloadEverything()
        model.selectedNoteIDs = [removed.url]
        try FileManager.default.removeItem(at: removed.url)

        model.reloadFromDisk()

        XCTAssertEqual(model.selectedNoteIDs, [remaining.url])
    }

    func testOrdinaryCreationStillSelectsNoteInCurrentFolderAndRespectsEditorPreference() throws {
        let folder = try model.store.createFolder(named: "Project", parent: root)
        model.sidebarSelection = .project(folder)
        model.searchText = "no match"
        model.settings.openEditorOnCreate = false

        model.createNote()

        XCTAssertEqual(model.sidebarSelection, .project(folder))
        XCTAssertTrue(model.searchText.isEmpty)
        XCTAssertEqual(model.focusedNote?.url.deletingLastPathComponent(), folder)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testMatchFilenameToTitleOnMultipleNotes() throws {
        _ = try model.store.createNote(
            named: "Untitled Note", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Alpha")
        )
        _ = try model.store.createNote(
            named: "Untitled Note 2", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Beta")
        )
        model.reloadEverything()
        XCTAssertEqual(model.notes.filter(\.fileStemDiffersFromTitle).count, 2)
        _ = model.matchFilenameToTitle(model.notes)
        XCTAssertEqual(model.notes.filter(\.fileStemDiffersFromTitle).count, 0)
        let stems = Set(model.notes.map(\.fileName))
        XCTAssertEqual(stems, ["Alpha", "Beta"])
    }

    func testQueueCountsIgnoreAllNotesAndHideEmptyWork() throws {
        let tagged = try model.store.createNote(
            named: "Tagged", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Tagged")
        )
        _ = try model.store.createNote(
            named: "Loose", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Loose")
        )
        model.store.applyTag("work", add: true, to: [tagged.url])
        model.reloadEverything()
        XCTAssertEqual(model.inboxCount, 2)
        XCTAssertEqual(model.untaggedCount, 1)
        XCTAssertEqual(model.trashCount, 0)
        try model.store.trash([tagged.url])
        model.reloadEverything()
        XCTAssertEqual(model.inboxCount, 1)
        XCTAssertEqual(model.untaggedCount, 1)
        XCTAssertEqual(model.trashCount, 1)
    }

    // MARK: - Folder lists include descendants

    func testProjectFolderListsOwnNotesAndDescendantsByDefault() throws {
        let fixture = try nestedFolderFixture()
        XCTAssertTrue(model.settings.includeFolderDescendants)

        model.sidebarSelection = .project(fixture.work)

        XCTAssertEqual(Set(model.notes.map(\.title)), ["WorkNote", "NestedNote"])
        XCTAssertTrue(model.showsFolderOnRows)
    }

    func testProjectFolderIsExactMatchWhenDescendantsAreOff() throws {
        let fixture = try nestedFolderFixture()
        model.settings.includeFolderDescendants = false
        model.sidebarSelection = .project(fixture.work)
        model.reloadNotes()

        XCTAssertEqual(model.notes.map(\.title), ["WorkNote"])
        XCTAssertFalse(model.showsFolderOnRows)
    }

    func testWorkFolderDoesNotListWork2() throws {
        let fixture = try nestedFolderFixture()
        model.sidebarSelection = .project(fixture.work)

        XCTAssertFalse(model.notes.contains { $0.title == "Work2Note" })
        XCTAssertFalse(LibraryPaths.isInside(fixture.work2, folder: fixture.work))

        model.sidebarSelection = .project(fixture.work2)
        XCTAssertEqual(model.notes.map(\.title), ["Work2Note"])
    }

    func testInboxStaysRootOnlyWhenDescendantsAreIncluded() throws {
        let fixture = try nestedFolderFixture()
        XCTAssertTrue(model.settings.includeFolderDescendants)

        model.sidebarSelection = .inbox

        XCTAssertEqual(model.notes.map(\.title), ["InboxNote"])
        XCTAssertFalse(model.showsFolderOnRows)

        model.sidebarSelection = .all
        XCTAssertEqual(Set(model.notes.map(\.title)), ["InboxNote", "WorkNote", "NestedNote", "Work2Note"])
    }

    func testOpenRootDoesNotSwitchLibraryWhenBookmarkCannotBeSaved() throws {
        model.settings.storageBookmark = Data("folder-a".utf8)
        model.openRoot(root, bookmark: Data("folder-a".utf8), skipActivate: true)
        XCTAssertEqual(model.rootURL?.standardizedFileURL, root.standardizedFileURL)

        var presented: Error?
        model.errorPresenter = { presented = $0 }
        model.bookmarkFactory = { _ in throw CocoaError(.fileWriteUnknown) }

        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-model-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        model.openRoot(folderB)

        XCTAssertNotNil(presented)
        XCTAssertEqual(model.rootURL?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(model.settings.storageBookmark, Data("folder-a".utf8))
        XCTAssertNotEqual(model.store.root?.standardizedFileURL, folderB.standardizedFileURL)
    }

    func testOpenRootProceedsWithoutBookmarkWhenNoneWasStored() throws {
        model.settings.storageBookmark = nil
        var presented: Error?
        model.errorPresenter = { presented = $0 }
        model.bookmarkFactory = { _ in throw CocoaError(.fileWriteUnknown) }

        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-model-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        model.openRoot(folderB)

        XCTAssertNil(presented)
        XCTAssertEqual(model.rootURL?.standardizedFileURL, folderB.standardizedFileURL)
        XCTAssertNil(model.settings.storageBookmark)
    }

    func testTogglingFolderDescendantsRefreshesTheVisibleList() throws {
        let fixture = try nestedFolderFixture()
        model.sidebarSelection = .project(fixture.work)
        XCTAssertEqual(Set(model.notes.map(\.title)), ["WorkNote", "NestedNote"])

        model.settings.includeFolderDescendants = false
        model.reloadNotes()
        XCTAssertEqual(model.notes.map(\.title), ["WorkNote"])

        model.settings.includeFolderDescendants = true
        model.reloadNotes()
        XCTAssertEqual(Set(model.notes.map(\.title)), ["WorkNote", "NestedNote"])
    }

    // MARK: - Tags as additive AND filters

    func testFolderPlusOneTagShowsOnlyMatchingNotes() throws {
        let folder = try model.store.createFolder(named: "Work", parent: root)
        try taggedNote("Kept", tags: ["dfir"], in: folder)
        try taggedNote("Other", tags: [], in: folder)
        try taggedNote("Outside", tags: ["dfir"])
        model.reloadEverything()

        model.sidebarSelection = .project(folder)
        XCTAssertEqual(Set(model.notes.map(\.title)), ["Kept", "Other"])
        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.notes.map(\.title), ["Kept"])
    }

    func testTwoTagsMeanANDAndNeverEnlargeTheList() throws {
        try taggedNote("Both", tags: ["dfir", "incident"])
        try taggedNote("OnlyDFIR", tags: ["dfir"])
        try taggedNote("None", tags: [])
        model.reloadEverything()
        model.sidebarSelection = .all

        model.selectedTags = ["dfir"]
        let afterOne = Set(model.notes.map(\.title))
        XCTAssertEqual(afterOne, ["Both", "OnlyDFIR"])
        let countAfterOne = model.notes.count

        model.selectedTags = ["dfir", "incident"]
        XCTAssertEqual(Set(model.notes.map(\.title)), ["Both"])
        XCTAssertLessThanOrEqual(model.notes.count, countAfterOne)
        XCTAssertFalse(model.notes.contains { $0.title == "OnlyDFIR" })
    }

    func testInboxAndAllPlusTag() throws {
        let folder = try model.store.createFolder(named: "Work", parent: root)
        try taggedNote("InboxTagged", tags: ["dfir"])
        try taggedNote("InboxPlain", tags: [])
        try taggedNote("FolderTagged", tags: ["dfir"], in: folder)
        model.reloadEverything()

        model.sidebarSelection = .inbox
        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.notes.map(\.title), ["InboxTagged"])

        model.sidebarSelection = .all
        XCTAssertEqual(Set(model.notes.map(\.title)), ["InboxTagged", "FolderTagged"])
        XCTAssertEqual(model.selectedTags, ["dfir"])
    }

    func testTrashPlusTagKeepsIsTrashedFirst() throws {
        try taggedNote("Live", tags: ["dfir"])
        let doomed = try taggedNote("Doomed", tags: ["dfir"])
        try model.store.trash([doomed.url])
        model.reloadEverything()

        model.sidebarSelection = .trash
        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.notes.map(\.title), ["Doomed"])
        XCTAssertTrue(model.notes.allSatisfy(\.isTrashed))
        XCTAssertFalse(model.notes.contains { $0.title == "Live" })
    }

    func testSelectingATagWhileUntaggedMovesCollectionToAll() throws {
        try taggedNote("Tagged", tags: ["dfir"])
        try taggedNote("Loose", tags: [])
        model.reloadEverything()
        model.sidebarSelection = .untagged
        XCTAssertEqual(model.notes.map(\.title), ["Loose"])

        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.sidebarSelection, .all)
        XCTAssertEqual(model.selectedTags, ["dfir"])
        XCTAssertEqual(model.notes.map(\.title), ["Tagged"])
    }

    func testSelectingUntaggedWhileTagsAreActiveClearsTags() throws {
        try taggedNote("Tagged", tags: ["dfir"])
        try taggedNote("Loose", tags: [])
        model.reloadEverything()
        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.notes.map(\.title), ["Tagged"])

        model.sidebarSelection = .untagged
        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertEqual(model.sidebarSelection, .untagged)
        XCTAssertEqual(model.notes.map(\.title), ["Loose"])
    }

    func testCollectionTitleAppendsSortedTagNames() throws {
        try taggedNote("Tagged", tags: ["dfir", "incident"])
        model.reloadEverything()
        let inbox = NSLocalizedString("Inbox", comment: "")
        let all = NSLocalizedString("All Notes", comment: "")

        model.sidebarSelection = .inbox
        XCTAssertEqual(model.collectionTitle, inbox)

        model.selectedTags = ["incident", "dfir"]
        XCTAssertEqual(model.collectionTitle, "\(inbox) · dfir, incident")

        model.sidebarSelection = .all
        XCTAssertEqual(model.collectionTitle, "\(all) · dfir, incident")

        model.selectedTags = []
        XCTAssertEqual(model.collectionTitle, all)
    }

    func testPersistAndRestoreCollectionAndSelectedTags() throws {
        try taggedNote("Tagged", tags: ["dfir"])
        try taggedNote("Loose", tags: [])
        model.reloadEverything()
        model.sidebarSelection = .inbox
        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.settings.lastSidebarToken, "inbox")
        XCTAssertEqual(Set(model.settings.lastSelectedTags), ["dfir"])
        XCTAssertFalse(model.settings.lastSidebarToken.hasPrefix("tag:"))

        let restored = LibraryModel(
            settings: AppSettings(defaults: defaults),
            store: LibraryStore()
        ) { _, _ in }
        restored.openRoot(root, skipActivate: true)
        XCTAssertEqual(restored.sidebarSelection, .inbox)
        XCTAssertEqual(restored.selectedTags, ["dfir"])
        XCTAssertEqual(restored.notes.map(\.title), ["Tagged"])
        if case .tag = restored.sidebarSelection {
            XCTFail("a restored session must not select .tag")
        }
    }

    func testRestoreMigratesLegacyTagTokenToAllPlusSelectedTag() throws {
        try taggedNote("ISO", tags: ["iso"])
        model.reloadEverything()
        defaults.removeObject(forKey: "lastSelectedTags")
        defaults.set("tag:iso", forKey: "lastSidebarToken")
        XCTAssertNil(defaults.object(forKey: "lastSelectedTags"))

        let restored = LibraryModel(
            settings: AppSettings(defaults: defaults),
            store: LibraryStore()
        ) { _, _ in }
        restored.openRoot(root, skipActivate: true)
        XCTAssertEqual(restored.sidebarSelection, .all)
        XCTAssertEqual(restored.selectedTags, ["iso"])
        XCTAssertEqual(restored.notes.map(\.title), ["ISO"])
        if case .tag = restored.sidebarSelection {
            XCTFail("migration must not restore .tag as the collection")
        }
    }

    func testRestorePrunesVanishedSelectedTags() throws {
        try taggedNote("Loose", tags: [])
        try taggedNote("Tagged", tags: ["dfir"])
        model.reloadEverything()
        model.settings.lastSidebarToken = "all"
        model.settings.lastSelectedTags = ["dfir", "ghost"]

        let restored = LibraryModel(
            settings: AppSettings(defaults: defaults),
            store: LibraryStore()
        ) { _, _ in }
        restored.openRoot(root, skipActivate: true)
        XCTAssertEqual(restored.selectedTags, ["dfir"])
        XCTAssertFalse(restored.selectedTags.contains("ghost"))
        XCTAssertEqual(restored.notes.map(\.title), ["Tagged"])
    }

    func testPersistingATagRowWritesAllAndTheTagSet() throws {
        try taggedNote("ISO", tags: ["iso"])
        model.reloadEverything()
        model.sidebarSelection = .tag("iso")
        XCTAssertEqual(model.settings.lastSidebarToken, "all")
        XCTAssertEqual(Set(model.settings.lastSelectedTags), ["iso"])
        XCTAssertFalse(model.settings.lastSidebarToken.hasPrefix("tag:"))
        XCTAssertEqual(model.notes.map(\.title), ["ISO"])
    }

    func testReloadEverythingPrunesVanishedSelectedTags() throws {
        let note = try taggedNote("Tagged", tags: ["dfir"])
        model.reloadEverything()
        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.selectedTags, ["dfir"])

        model.store.applyTag("dfir", add: false, to: [note.url])
        model.reloadEverything()
        XCTAssertFalse(model.selectedTags.contains("dfir"))
        XCTAssertTrue(model.selectedTags.isEmpty)
    }

    func testOrdinaryCreateAppliesSelectedTagsSoTheNoteStaysVisible() throws {
        try taggedNote("Existing", tags: ["dfir", "incident"])
        model.reloadEverything()
        model.sidebarSelection = .inbox
        model.selectedTags = ["dfir", "incident"]
        model.settings.openEditorOnCreate = false

        model.createNote()

        let created = try XCTUnwrap(model.focusedNote)
        XCTAssertEqual(Set(created.tags), ["dfir", "incident"])
        XCTAssertTrue(model.notes.contains { $0.url == created.url })
        XCTAssertEqual(model.sidebarSelection, .inbox)
        XCTAssertEqual(model.selectedTags, ["dfir", "incident"])
    }

    func testQuickNoteDoesNotChangeSelectedTagsOrSidebar() throws {
        let folder = try model.store.createFolder(named: "Project", parent: root)
        let existing = try taggedNote("Reading", tags: ["dfir"], in: folder)
        model.reloadEverything()
        model.sidebarSelection = .project(folder)
        model.selectedTags = ["dfir"]
        model.selectedNoteIDs = [existing.url]
        model.settings.openEditorOnCreate = false

        model.createQuickNote()

        XCTAssertEqual(model.sidebarSelection, .project(folder))
        XCTAssertEqual(model.selectedTags, ["dfir"])
        XCTAssertEqual(model.selectedNoteIDs, [existing.url])
        let created = model.store.snapshots().first {
            $0.folderURL.standardizedFileURL == root.standardizedFileURL
        }
        XCTAssertNotNil(created)
        XCTAssertTrue(created?.tags.isEmpty ?? false)
        XCTAssertFalse(model.notes.contains { $0.url == created?.url })
    }

    func testAssigningTheSameSelectedTagsDoesNotReload() throws {
        try taggedNote("Tagged", tags: ["dfir"])
        model.reloadEverything()
        model.selectedTags = ["dfir"]
        let before = model.reloadCount
        model.selectedTags = ["dfir"]
        XCTAssertEqual(model.reloadCount, before)
    }

    func testLegacyTagSelectionStillFiltersWhenSelectedTagsIsEmpty() throws {
        try taggedNote("Tagged", tags: ["dfir"])
        try taggedNote("Loose", tags: [])
        model.reloadEverything()
        model.sidebarSelection = .tag("dfir")
        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertEqual(model.notes.map(\.title), ["Tagged"])
    }

    func testSwitchingLibraryClearsSelectedTags() throws {
        try taggedNote("Tagged", tags: ["dfir"])
        model.reloadEverything()
        model.selectedTags = ["dfir"]
        model.settings.storageBookmark = nil
        model.bookmarkFactory = { _ in throw CocoaError(.fileWriteUnknown) }

        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-model-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        model.openRoot(folderB)

        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertTrue(model.settings.lastSelectedTags.isEmpty)
        XCTAssertEqual(model.settings.lastSidebarToken, "all")
    }

    // MARK: - Favourites

    func testFavouritesPublishAddRemoveAndReorder() throws {
        let zeta = try model.store.createFolder(named: "zeta", parent: root)
        let mu = try model.store.createFolder(named: "mu", parent: root)
        try taggedNote("Tagged", tags: ["alpha"])
        model.reloadEverything()

        model.addFavourite(.folder(LibraryPaths.relativePath(of: zeta, to: root)))
        model.addFavourite(.tag("alpha"))
        XCTAssertEqual(model.favourites, [
            .tag("alpha"),
            .folder(LibraryPaths.relativePath(of: zeta, to: root))
        ])
        XCTAssertTrue(model.isFavourite(.tag("alpha")))

        model.reorderFavourites(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(model.favourites, [
            .folder(LibraryPaths.relativePath(of: zeta, to: root)),
            .tag("alpha")
        ])

        model.addFavourite(.folder(LibraryPaths.relativePath(of: mu, to: root)))
        XCTAssertEqual(model.favourites.last, .folder(LibraryPaths.relativePath(of: mu, to: root)))

        model.removeFavourite(.tag("alpha"))
        XCTAssertFalse(model.favourites.contains(.tag("alpha")))
        XCTAssertTrue(model.isFavourite(.folder(LibraryPaths.relativePath(of: zeta, to: root))))
    }

    func testReloadOfUnchangedFavouritesKeepsTheSameArray() throws {
        let work = try model.store.createFolder(named: "Work", parent: root)
        try taggedNote("Tagged", tags: ["dfir"])
        model.reloadEverything()
        model.addFavourite(.folder(LibraryPaths.relativePath(of: work, to: root)))
        model.addFavourite(.tag("dfir"))
        let published = model.favourites
        model.reloadEverything()
        XCTAssertEqual(model.favourites, published)
        model.store.rescan()
        model.reloadEverything()
        XCTAssertEqual(model.favourites, published)
    }

    func testSwitchingLibraryDoesNotLeakFavourites() throws {
        let work = try model.store.createFolder(named: "Work", parent: root)
        try taggedNote("Tagged", tags: ["dfir"])
        model.reloadEverything()
        model.addFavourite(.folder(LibraryPaths.relativePath(of: work, to: root)))
        model.addFavourite(.tag("dfir"))
        XCTAssertEqual(model.favourites.count, 2)

        model.settings.storageBookmark = nil
        model.bookmarkFactory = { _ in throw CocoaError(.fileWriteUnknown) }

        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-model-favs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        model.openRoot(folderB)

        XCTAssertTrue(model.favourites.isEmpty)
        XCTAssertFalse(model.isFavourite(.tag("dfir")))
    }

    func testVanishedTagFavouriteDropsOnModelReload() throws {
        let record = try taggedNote("Tagged", tags: ["dfir"])
        model.reloadEverything()
        model.addFavourite(.tag("dfir"))
        XCTAssertTrue(model.favourites.contains(.tag("dfir")))

        model.store.applyTag("dfir", add: false, to: [record.url])
        model.reloadEverything()
        XCTAssertFalse(model.favourites.contains(.tag("dfir")))
    }

    func testNoteFavouritePublishAddRemoveAndDoesNotLeakOnLibrarySwitch() throws {
        let record = try model.store.createNote(
            named: "Brief", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Brief")
        )
        model.reloadEverything()
        model.addFavourite(.note(record.relativePath))
        XCTAssertTrue(model.favourites.contains(.note(record.relativePath)))
        XCTAssertTrue(model.isFavourite(.note(record.relativePath)))
        XCTAssertEqual(model.note(relativePath: record.relativePath)?.url, record.url)

        model.removeFavourite(.note(record.relativePath))
        XCTAssertFalse(model.favourites.contains(.note(record.relativePath)))

        model.addFavourite(.note(record.relativePath))
        model.settings.storageBookmark = nil
        model.bookmarkFactory = { _ in throw CocoaError(.fileWriteUnknown) }

        let folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-model-note-favs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        model.openRoot(folderB)
        XCTAssertTrue(model.favourites.isEmpty)
        XCTAssertFalse(model.isFavourite(.note(record.relativePath)))
    }

    func testRevealFavouriteNoteSelectsInboxClearsTagsAndNeverLeavesNoteSelection() throws {
        try taggedNote("Tagged", tags: ["dfir"])
        let target = try model.store.createNote(
            named: "InboxFav", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "InboxFav")
        )
        model.reloadEverything()
        model.sidebarSelection = .all
        model.selectedTags = ["dfir"]
        model.addFavourite(.note(target.relativePath))

        model.revealFavouriteNote(.note(target.relativePath))
        XCTAssertEqual(model.sidebarSelection, .inbox)
        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertEqual(model.selectedNoteIDs, [target.url])
        if case .note = model.sidebarSelection {
            XCTFail("reveal must write a real collection, never .note")
        }
        XCTAssertTrue(model.notes.contains { $0.url == target.url })
    }

    func testRevealFavouriteNoteSelectsProjectFolder() throws {
        let work = try model.store.createFolder(named: "Work", parent: root)
        let target = try model.store.createNote(
            named: "WorkFav", in: work, extension: "md",
            body: NoteActions.newNoteBody(named: "WorkFav")
        )
        _ = try model.store.createNote(
            named: "Decoy", in: work, extension: "md",
            body: NoteActions.newNoteBody(named: "Decoy")
        )
        model.reloadEverything()
        model.sidebarSelection = .inbox
        model.addFavourite(.note(target.relativePath))

        model.revealFavouriteNote(.note(target.relativePath))
        XCTAssertEqual(model.sidebarSelection, .project(work.standardizedFileURL))
        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertEqual(model.selectedNoteIDs, [target.url])
        if case .note = model.sidebarSelection {
            XCTFail("reveal must write a real collection, never .note")
        }
    }

    func testRevealFavouriteNoteSelectsTrash() throws {
        let record = try model.store.createNote(
            named: "Doomed", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Doomed")
        )
        model.reloadEverything()
        model.addFavourite(.note(record.relativePath))
        let snapshot = try XCTUnwrap(model.note(with: record.url))
        model.delete([snapshot])

        let favourite = try XCTUnwrap(model.favourites.first {
            if case .note = $0 { return true }
            return false
        })
        model.sidebarSelection = .inbox
        model.revealFavouriteNote(favourite)
        XCTAssertEqual(model.sidebarSelection, .trash)
        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertEqual(model.selectedNoteIDs.count, 1)
        let shown = try XCTUnwrap(model.notes.first { model.selectedNoteIDs.contains($0.url) })
        XCTAssertTrue(shown.isTrashed)
        if case .note = model.sidebarSelection {
            XCTFail("reveal must write a real collection, never .note")
        }
    }

    func testRevealMissingOrNonNoteFavouriteIsNoOp() throws {
        model.sidebarSelection = .inbox
        let beforeSelection = model.sidebarSelection
        let beforeNotes = model.selectedNoteIDs
        model.revealFavouriteNote(.note("missing.md"))
        model.revealFavouriteNote(.tag("dfir"))
        model.revealFavouriteNote(.folder("Work"))
        XCTAssertEqual(model.sidebarSelection, beforeSelection)
        XCTAssertEqual(model.selectedNoteIDs, beforeNotes)
    }

    func testAssigningSidebarSelectionNoteDoesNotFilterTheList() throws {
        _ = try model.store.createNote(
            named: "One", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "One")
        )
        _ = try model.store.createNote(
            named: "Two", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Two")
        )
        model.reloadEverything()
        XCTAssertEqual(model.notes.count, 2)
        let urls = Set(model.notes.map(\.url))
        let noteItem = LibraryModel.SidebarItem.note(model.notes[0].url)
        XCTAssertEqual(noteItem.token(relativeTo: root), "all")
        XCTAssertEqual(LibraryModel.SidebarItem.from(token: "note:One.md", root: root), .all)
        model.sidebarSelection = noteItem
        XCTAssertEqual(Set(model.notes.map(\.url)), urls)
        XCTAssertEqual(model.settings.lastSidebarToken, "all")
        XCTAssertEqual(model.collectionTitle, NSLocalizedString("All Notes", comment: ""))
        XCTAssertTrue(model.showsFolderOnRows)
    }

    // MARK: - Inbox capture (iOS create-once; Mac tests the same API)

    func testCaptureInboxNoteWhitespaceCreatesNothing() {
        XCTAssertNil(model.captureInboxNote(text: ""))
        XCTAssertNil(model.captureInboxNote(text: "   \n\t  "))
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertTrue(model.store.snapshots().isEmpty)
        XCTAssertEqual(markdownFiles(in: root).count, 0)
    }

    func testCaptureInboxNoteOneLineWritesYAMLAndBodyAtRoot() throws {
        let text = "Hello from the field"
        let url = try XCTUnwrap(model.captureInboxNote(text: text))

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "md")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let parsed = FrontMatterCodec.parse(onDisk)
        XCTAssertEqual(parsed.frontMatter?.title, text)
        XCTAssertEqual(parsed.frontMatter?.tags, [])
        XCTAssertNotNil(parsed.frontMatter?.created)
        XCTAssertEqual(parsed.body, text)
        XCTAssertFalse(onDisk.contains("\n# "))
        XCTAssertTrue(openedURLs.isEmpty, "capture must not open the external editor")
        XCTAssertEqual(model.sidebarSelection, .inbox)
        XCTAssertEqual(model.selectedNoteIDs, [url])
        XCTAssertEqual(model.focusedNote?.url, url)
    }

    func testCaptureInboxNoteTitleIsFirstLineBodyIsFullTypedText() throws {
        let text = "First line\n\nThe rest stays as typed.\n"
        let url = try XCTUnwrap(model.captureInboxNote(text: text))
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let parsed = FrontMatterCodec.parse(onDisk)
        XCTAssertEqual(parsed.frontMatter?.title, "First line")
        XCTAssertEqual(parsed.body, text)
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "First line")
    }

    func testCaptureInboxNoteLeadingBlankLineUsesNextNonEmptyLine() throws {
        let text = "\n  Title from the second line  \nbody"
        XCTAssertEqual(LibraryModel.captureTitle(from: text), "Title from the second line")
        let url = try XCTUnwrap(model.captureInboxNote(text: text))
        let parsed = FrontMatterCodec.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.frontMatter?.title, "Title from the second line")
        XCTAssertEqual(parsed.body, text)
    }

    func testCaptureInboxNoteQuotesColonInTitle() throws {
        let text = "Agenda: Monday"
        let url = try XCTUnwrap(model.captureInboxNote(text: text))
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("title: \"Agenda: Monday\""))
        XCTAssertEqual(FrontMatterCodec.parse(onDisk).body, text)
    }

    func testCaptureInboxNoteDoesNotOpenEditorEvenWhenCreateWould() throws {
        model.settings.openEditorOnCreate = true
        model.settings.externalEditorBundle = "test.editor"
        let url = try XCTUnwrap(model.captureInboxNote(text: "Captured"))
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }

    func testCaptureInboxNoteAlwaysLandsInRootNotTheSelectedFolder() throws {
        let folder = try model.store.createFolder(named: "Project", parent: root)
        model.sidebarSelection = .project(folder)
        model.searchText = "no match"
        model.selectedTags = ["dfir"]

        let url = try XCTUnwrap(model.captureInboxNote(text: "Inbox only"))

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(url.path.contains("/Project/"))
        XCTAssertEqual(model.sidebarSelection, .inbox)
        XCTAssertTrue(model.searchText.isEmpty)
        XCTAssertTrue(model.selectedTags.isEmpty)
        XCTAssertEqual(model.selectedNoteIDs, [url])
        XCTAssertTrue(model.focusedNote?.tags.isEmpty ?? false)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testCaptureInboxNoteLeavesQuickNoteEditorPathUnchanged() throws {
        model.settings.openEditorOnCreate = false
        model.settings.externalEditorBundle = "test.editor"
        model.createQuickNote()
        XCTAssertEqual(openedURLs.count, 1, "createQuickNote must still open the editor")
        openedURLs = []
        _ = model.captureInboxNote(text: "Phone capture")
        XCTAssertTrue(openedURLs.isEmpty)
    }

    private func markdownFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
    }

    @discardableResult
    private func taggedNote(_ name: String, tags: [String], in folder: URL? = nil) throws -> NoteRecord {
        let record = try model.store.createNote(
            named: name, in: folder ?? root, extension: "md",
            body: NoteActions.newNoteBody(named: name)
        )
        for tag in tags {
            model.store.applyTag(tag, add: true, to: [record.url])
        }
        return record
    }

    private struct NestedFolderFixture {
        let work: URL
        let work2: URL
    }

    private func nestedFolderFixture() throws -> NestedFolderFixture {
        let work = try model.store.createFolder(named: "Work", parent: root)
        let nested = try model.store.createFolder(named: "Nested", parent: work)
        let work2 = try model.store.createFolder(named: "Work2", parent: root)
        _ = try model.store.createNote(
            named: "InboxNote", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "InboxNote")
        )
        _ = try model.store.createNote(
            named: "WorkNote", in: work, extension: "md",
            body: NoteActions.newNoteBody(named: "WorkNote")
        )
        _ = try model.store.createNote(
            named: "NestedNote", in: nested, extension: "md",
            body: NoteActions.newNoteBody(named: "NestedNote")
        )
        _ = try model.store.createNote(
            named: "Work2Note", in: work2, extension: "md",
            body: NoteActions.newNoteBody(named: "Work2Note")
        )
        model.reloadEverything()
        return NestedFolderFixture(work: work, work2: work2)
    }
}
