import XCTest
@testable import Shokonotes

@MainActor
final class FolderSymbolTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-folder-symbols-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    /// Breadth-first walk over one folder tree. Iterative on purpose: the tree is
    /// read from `store.folders()` exactly once per lookup, and no call re-enters
    /// on its own input, so a malformed tree cannot exhaust the stack.
    private func folder(named name: String, in items: [FolderSnapshot]? = nil) -> FolderSnapshot? {
        var pending = items ?? store.folders()
        var index = 0
        while index < pending.count {
            let item = pending[index]
            index += 1
            if item.name == name { return item }
            if let children = item.children { pending.append(contentsOf: children) }
        }
        return nil
    }

    func testDefaultFoldersHaveNilSymbol() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        _ = work
        XCTAssertNil(folder(named: "Work")?.symbol)
        XCTAssertTrue(store.folders().allSatisfy { $0.symbol == nil })
    }

    func testSetAndClearPersistAcrossNewStore() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        store.setFolderSymbol(work, "briefcase")
        XCTAssertEqual(folder(named: "Work")?.symbol, "briefcase")

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertEqual(
            reopened.folders().first { $0.name == "Work" }?.symbol,
            "briefcase"
        )

        store.setFolderSymbol(work, nil)
        XCTAssertNil(folder(named: "Work")?.symbol)

        let cleared = LibraryStore()
        cleared.setRoot(root)
        XCTAssertNil(cleared.folders().first { $0.name == "Work" }?.symbol)
    }

    func testEmptyStringClearsSymbol() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        store.setFolderSymbol(work, "briefcase")
        store.setFolderSymbol(work, "")
        XCTAssertNil(folder(named: "Work")?.symbol)
        store.setFolderSymbol(work, "folder.fill")
        store.setFolderSymbol(work, "   ")
        XCTAssertNil(folder(named: "Work")?.symbol)
    }

    func testRenameRemapsSymbolKey() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let sub = try store.createFolder(named: "Sub", parent: work)
        store.setFolderSymbol(work, "briefcase")
        store.setFolderSymbol(sub, "folder.fill")

        let renamed = try store.renameFolder(work, to: "Office")
        XCTAssertEqual(folder(named: "Office")?.symbol, "briefcase")
        XCTAssertEqual(folder(named: "Sub")?.symbol, "folder.fill")
        XCTAssertNil(folder(named: "Work"))

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertEqual(
            reopened.folders().first { $0.name == "Office" }?.symbol,
            "briefcase"
        )
        XCTAssertEqual(
            reopened.folders().first { $0.name == "Office" }?.children?.first { $0.name == "Sub" }?.symbol,
            "folder.fill"
        )
        _ = renamed
    }

    func testWorkSymbolDoesNotApplyToWork2() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        store.setFolderSymbol(work, "briefcase")
        store.setFolderSymbol(work2, "archivebox")

        XCTAssertEqual(folder(named: "Work")?.symbol, "briefcase")
        XCTAssertEqual(folder(named: "Work2")?.symbol, "archivebox")

        _ = try store.renameFolder(work, to: "Office")
        XCTAssertEqual(folder(named: "Office")?.symbol, "briefcase")
        XCTAssertEqual(folder(named: "Work2")?.symbol, "archivebox")

        XCTAssertNil(LibraryPaths.remappedRelativePath("Work2", from: "Work", to: "Office"))
        XCTAssertNil(LibraryPaths.remappedRelativePath("Work2/Sub", from: "Work", to: "Office"))
        XCTAssertEqual(LibraryPaths.remappedRelativePath("Work", from: "Work", to: "Office"), "Office")
        XCTAssertFalse(LibraryPaths.isRelativePath("Work2", under: "Work"))
    }

    /// Pins and folder symbols are the same kind of stored intent. Deleting a
    /// folder sends its notes to the Trash, and restoring one recreates the
    /// folder: the glyph must survive that round trip exactly as the pin does.
    func testRestoreBringsBackTheDeletedFolderSymbolAndItsPin() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        store.setFolderSymbol(work, "briefcase")
        let note = try store.createNote(named: "Report", in: work, extension: "md", body: "# Report\n")
        try store.setPinned(note.url, true)
        XCTAssertEqual(folder(named: "Work")?.symbol, "briefcase")

        try store.deleteFolder(work)
        XCTAssertNil(folder(named: "Work"))

        let trashed = try XCTUnwrap(store.snapshots().first { $0.isTrashed })
        XCTAssertTrue(trashed.isPinned)
        try store.restore([trashed.url], fallback: root)

        let restored = try XCTUnwrap(store.snapshots().first { !$0.isTrashed })
        XCTAssertEqual(restored.folderURL.lastPathComponent, "Work")
        XCTAssertTrue(restored.isPinned, "the pin came back")
        XCTAssertEqual(folder(named: "Work")?.symbol, "briefcase", "so must the symbol")

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertEqual(reopened.folders().first { $0.name == "Work" }?.symbol, "briefcase")
    }

    /// The stale key has a bound: once the Trash can no longer bring the folder
    /// back, its symbol is collected.
    func testEmptyingTheTrashCollectsTheDeadFolderSymbol() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        store.setFolderSymbol(work, "briefcase")
        store.setFolderSymbol(work2, "archivebox")
        _ = try store.createNote(named: "Report", in: work, extension: "md", body: "# Report\n")

        try store.deleteFolder(work)
        let trashed = store.snapshots().filter(\.isTrashed)
        XCTAssertEqual(trashed.count, 1)
        try store.removeForever(trashed.map(\.url))

        // Nothing can recreate Work now, so a folder later created at the same
        // path starts from the default glyph.
        let recreated = try store.createFolder(named: "Work", parent: root)
        XCTAssertNil(folder(named: "Work")?.symbol)
        XCTAssertEqual(folder(named: "Work2")?.symbol, "archivebox", "the sibling is untouched")
        _ = recreated

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertNil(reopened.folders().first { $0.name == "Work" }?.symbol)
        XCTAssertEqual(reopened.folders().first { $0.name == "Work2" }?.symbol, "archivebox")
    }

    /// `folderSymbols.json` is written when the map changes and not otherwise —
    /// the write counter is only a witness if it counts real writes.
    func testDeleteWritesFolderSymbolsOnlyWhenTheMapChanges() throws {
        let plain = try store.createFolder(named: "Plain", parent: root)
        _ = try store.createNote(named: "Note", in: plain, extension: "md", body: "x\n")
        var before = store.folderSymbolWriteCount
        try store.deleteFolder(plain)
        XCTAssertEqual(store.folderSymbolWriteCount, before, "no symbol anywhere: nothing to write")

        let work = try store.createFolder(named: "Work", parent: root)
        store.setFolderSymbol(work, "briefcase")
        _ = try store.createNote(named: "Report", in: work, extension: "md", body: "x\n")
        before = store.folderSymbolWriteCount
        try store.deleteFolder(work)
        XCTAssertEqual(
            store.folderSymbolWriteCount, before,
            "the symbol is kept for the restore: the file did not change"
        )

        let trashed = store.snapshots().filter(\.isTrashed)
        before = store.folderSymbolWriteCount
        try store.removeForever(trashed.map(\.url))
        XCTAssertEqual(store.folderSymbolWriteCount - before, 1, "collected once, written once")

        before = store.folderSymbolWriteCount
        try store.removeForever([])
        XCTAssertEqual(store.folderSymbolWriteCount, before, "nothing left to collect")
    }

    /// Empty folders leave no note in the Trash, so nothing can restore them and
    /// their symbols go at once — with the siblings left alone.
    func testDeleteDropsSymbolsNothingCanRestoreNotSiblings() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let sub = try store.createFolder(named: "Sub", parent: work)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        store.setFolderSymbol(work, "briefcase")
        store.setFolderSymbol(sub, "folder.fill")
        store.setFolderSymbol(work2, "archivebox")

        // Guard the guard: the helper must actually find the folder and its
        // descendant before the delete, or the XCTAssertNil below would pass
        // for the wrong reason.
        XCTAssertEqual(folder(named: "Work")?.symbol, "briefcase")
        XCTAssertEqual(folder(named: "Sub")?.symbol, "folder.fill")

        try store.deleteFolder(work)

        XCTAssertNil(folder(named: "Work"))
        XCTAssertNil(folder(named: "Sub"))
        XCTAssertEqual(folder(named: "Work2")?.symbol, "archivebox")

        // The key itself is gone, not merely the folder: recreating Work must
        // not inherit the old glyph.
        _ = try store.createFolder(named: "Work", parent: root)
        XCTAssertNil(folder(named: "Work")?.symbol)

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertEqual(
            reopened.folders().first { $0.name == "Work2" }?.symbol,
            "archivebox"
        )
        XCTAssertNil(reopened.folders().first { $0.name == "Work" }?.symbol)
    }

    func testSettingManyFoldersCostsOneWrite() throws {
        let a = try store.createFolder(named: "A", parent: root)
        let b = try store.createFolder(named: "B", parent: root)
        let c = try store.createFolder(named: "C", parent: root)
        let before = store.folderSymbolWriteCount

        store.setFolderSymbols([(a, "a.circle"), (b, "b.circle"), (c, "c.circle")])

        XCTAssertEqual(store.folderSymbolWriteCount - before, 1)
        XCTAssertEqual(folder(named: "A")?.symbol, "a.circle")
        XCTAssertEqual(folder(named: "B")?.symbol, "b.circle")
        XCTAssertEqual(folder(named: "C")?.symbol, "c.circle")
    }

    func testUnchangedSymbolWritesNothing() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        store.setFolderSymbol(work, "briefcase")
        let before = store.folderSymbolWriteCount
        store.setFolderSymbol(work, "briefcase")
        store.setFolderSymbol(work.appendingPathComponent("Ghost", isDirectory: true), "x")
        XCTAssertEqual(store.folderSymbolWriteCount, before)
    }
}

@MainActor
final class FolderSymbolModelTests: XCTestCase {
    private var root: URL!
    private var model: LibraryModel!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-folder-symbols-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "shokonotes-folder-symbols-model-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        model = LibraryModel(settings: AppSettings(defaults: defaults), store: LibraryStore()) { _, _ in }
        model.openRoot(root, skipActivate: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSetFolderSymbolRefreshesPublishedFolders() throws {
        let work = try model.store.createFolder(named: "Work", parent: root)
        model.reloadEverything()
        XCTAssertNil(model.folder(with: work)?.symbol)

        model.setFolderSymbol(work, "briefcase")
        XCTAssertEqual(model.folder(with: work)?.symbol, "briefcase")
        XCTAssertEqual(model.folders.first { $0.name == "Work" }?.symbol, "briefcase")

        model.setFolderSymbol(work, "")
        XCTAssertNil(model.folder(with: work)?.symbol)
        model.setFolderSymbol(work, "briefcase")
        XCTAssertEqual(model.allFoldersFlat().first { $0.url == work }?.symbol, "briefcase")
    }

    /// `resolved(_:)` is memoized because the sidebar calls it once per visible
    /// row on every redraw. The cache must not change any of its answers, and in
    /// particular must not answer `folder` for a name that is simply not in the
    /// curated catalogue — the human may carry one over from a newer build.
    func testResolvedSymbolAnswersTheSameWhetherCachedOrNot() {
        XCTAssertEqual(FolderSymbolCatalogue.resolved(nil), FolderSymbolCatalogue.defaultSymbol)
        XCTAssertEqual(FolderSymbolCatalogue.resolved(""), FolderSymbolCatalogue.defaultSymbol)

        let catalogued = FolderSymbolCatalogue.groups.first!.names.first!
        XCTAssertEqual(FolderSymbolCatalogue.resolved(catalogued), catalogued)
        XCTAssertEqual(FolderSymbolCatalogue.resolved(catalogued), catalogued)

        // Drawable, deliberately outside the curated list: the answer is the
        // name itself, not the default glyph.
        let outsideCatalogue = "car.side"
        XCTAssertFalse(
            FolderSymbolCatalogue.groups.contains { $0.names.contains(outsideCatalogue) },
            "pick a symbol the catalogue does not list")
        XCTAssertTrue(FolderSymbolCatalogue.exists(outsideCatalogue))
        XCTAssertEqual(FolderSymbolCatalogue.resolved(outsideCatalogue), outsideCatalogue)
        XCTAssertEqual(FolderSymbolCatalogue.resolved(outsideCatalogue), outsideCatalogue)

        let unknown = "shokonotes.not.a.symbol"
        XCTAssertFalse(FolderSymbolCatalogue.exists(unknown))
        XCTAssertEqual(FolderSymbolCatalogue.resolved(unknown), FolderSymbolCatalogue.defaultSymbol)
        XCTAssertEqual(FolderSymbolCatalogue.resolved(unknown), FolderSymbolCatalogue.defaultSymbol)
    }
}
