import XCTest
@testable import Shokonotes

@MainActor
final class FavouritesTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-favourites-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func relative(_ url: URL) -> String {
        LibraryPaths.relativePath(of: url, to: root)
    }

    private func loadFile() throws -> FavouriteFile {
        let data = try Data(contentsOf: LibraryPaths.favouritesURL(root: root))
        return try JSONDecoder().decode(FavouriteFile.self, from: data)
    }

    @discardableResult
    private func tagged(_ name: String, tag: String, in folder: URL? = nil) throws -> NoteRecord {
        let record = try store.createNote(
            named: name, in: folder ?? root, extension: "md",
            body: NoteActions.newNoteBody(named: name)
        )
        store.applyTag(tag, add: true, to: [record.url])
        return record
    }

    func testAddFolderAndTagPersistAcrossNewStore() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        try tagged("Report", tag: "dfir")
        try store.addFavourite(.folder(relative(work)))
        try store.addFavourite(.tag("dfir"))

        XCTAssertEqual(store.favourites(), [.tag("dfir"), .folder(relative(work))])
        XCTAssertEqual(LibraryPaths.favouritesURL(root: root).lastPathComponent, "favourites.json")
        XCTAssertEqual(
            LibraryPaths.favouritesURL(root: root).deletingLastPathComponent().lastPathComponent,
            ".shokonotes"
        )

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertEqual(reopened.favourites(), [.tag("dfir"), .folder(relative(work))])
        XCTAssertTrue(reopened.isFavourite(.folder(relative(work))))
        XCTAssertTrue(reopened.isFavourite(.tag("dfir")))
    }

    func testSidecarJSONUsesExplicitKeys() throws {
        let folder = try store.createFolder(named: "CHFI", parent: root)
        try tagged("Note", tag: "dfir")
        try store.addFavourite(.folder(relative(folder)))
        try store.addFavourite(.tag("dfir"))

        let text = try String(contentsOf: LibraryPaths.favouritesURL(root: root), encoding: .utf8)
        XCTAssertFalse(text.contains("_0"))
        XCTAssertTrue(text.contains("\"folder\""))
        XCTAssertTrue(text.contains("\"tag\""))
        XCTAssertTrue(text.contains("\"ranked\""))
        XCTAssertTrue(text.contains("\"items\""))

        let decoded = try JSONDecoder().decode(
            FavouriteFile.self,
            from: Data("""
            {
              "ranked": false,
              "items": [
                { "folder": "Formation/Investigation/CHFI" },
                { "tag": "dfir" }
              ]
            }
            """.utf8)
        )
        XCTAssertFalse(decoded.ranked)
        XCTAssertEqual(decoded.items, [
            .folder("Formation/Investigation/CHFI"),
            .tag("dfir")
        ])
    }

    func testAddingADuplicateDoesNotWrite() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        try tagged("Note", tag: "dfir")
        try store.addFavourite(.folder(relative(work)))
        try store.addFavourite(.tag("dfir"))
        let before = store.favouriteWriteCount

        try store.addFavourite(.folder(relative(work)))
        try store.addFavourite(.tag("dfir"))
        try store.addFavourite(.folder(relative(work) + "/"))
        try store.addFavourite(.tag("  dfir  "))

        XCTAssertEqual(store.favouriteWriteCount, before)
        XCTAssertEqual(store.favourites().count, 2)
    }

    func testUnrankedDisplayOrderIsAlphabeticalByName() throws {
        let zeta = try store.createFolder(named: "zeta", parent: root)
        try tagged("Note", tag: "alpha")
        try store.addFavourite(.folder(relative(zeta)))
        try store.addFavourite(.tag("alpha"))

        XCTAssertEqual(store.favourites(), [
            .tag("alpha"),
            .folder(relative(zeta))
        ])
        XCTAssertFalse(try loadFile().ranked)
    }

    func testSameFolderNameTieBreaksByRelativePath() throws {
        let formation = try store.createFolder(named: "Formation", parent: root)
        let other = try store.createFolder(named: "Other", parent: root)
        let a = try store.createFolder(named: "CHFI", parent: formation)
        let b = try store.createFolder(named: "CHFI", parent: other)
        try store.addFavourite(.folder(relative(b)))
        try store.addFavourite(.folder(relative(a)))

        XCTAssertEqual(store.favourites(), [
            .folder(relative(a)),
            .folder(relative(b))
        ])
    }

    func testFirstReorderSeedsAlphaThenLocksRankAndLaterAddAppends() throws {
        let zeta = try store.createFolder(named: "zeta", parent: root)
        let mu = try store.createFolder(named: "mu", parent: root)
        try tagged("Note", tag: "alpha")
        try store.addFavourite(.folder(relative(zeta)))
        try store.addFavourite(.tag("alpha"))
        XCTAssertEqual(store.favourites(), [.tag("alpha"), .folder(relative(zeta))])

        let before = store.favouriteWriteCount
        try store.reorderFavourites(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.favouriteWriteCount - before, 1)
        XCTAssertEqual(store.favourites(), [.folder(relative(zeta)), .tag("alpha")])

        let file = try loadFile()
        XCTAssertTrue(file.ranked)
        XCTAssertEqual(file.items, [.folder(relative(zeta)), .tag("alpha")])

        try store.addFavourite(.folder(relative(mu)))
        XCTAssertEqual(store.favourites(), [
            .folder(relative(zeta)),
            .tag("alpha"),
            .folder(relative(mu))
        ])
        XCTAssertTrue(try loadFile().ranked)
    }

    func testNoOpReorderAfterRankedWritesNothing() throws {
        let zeta = try store.createFolder(named: "zeta", parent: root)
        try tagged("Note", tag: "alpha")
        try store.addFavourite(.folder(relative(zeta)))
        try store.addFavourite(.tag("alpha"))
        try store.reorderFavourites(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let before = store.favouriteWriteCount
        try store.reorderFavourites(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertEqual(store.favouriteWriteCount, before)
    }

    func testRenameFolderRemapsFavouriteAndLeavesWork2() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let sub = try store.createFolder(named: "Sub", parent: work)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        try tagged("Note", tag: "dfir")
        try store.addFavourite(.folder(relative(work)))
        try store.addFavourite(.folder(relative(sub)))
        try store.addFavourite(.folder(relative(work2)))
        try store.addFavourite(.tag("dfir"))
        try store.reorderFavourites(fromOffsets: IndexSet(integer: 0), toOffset: 4)

        let rankedBefore = try loadFile()
        XCTAssertTrue(rankedBefore.ranked)
        let workIndex = try XCTUnwrap(rankedBefore.items.firstIndex(of: .folder(relative(work))))

        _ = try store.renameFolder(work, to: "Office")
        let office = root.appendingPathComponent("Office", isDirectory: true)
        let officeSub = office.appendingPathComponent("Sub", isDirectory: true)

        let items = store.favourites()
        XCTAssertTrue(items.contains(.folder(relative(office))))
        XCTAssertTrue(items.contains(.folder(relative(officeSub))))
        XCTAssertTrue(items.contains(.folder(relative(work2))))
        XCTAssertFalse(items.contains(.folder("Work")))
        XCTAssertEqual(items.firstIndex(of: .folder(relative(office))), workIndex)

        XCTAssertNil(LibraryPaths.remappedRelativePath("Work2", from: "Work", to: "Office"))

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertTrue(reopened.favourites().contains(.folder(relative(office))))
        XCTAssertTrue(reopened.favourites().contains(.folder(relative(officeSub))))
        XCTAssertTrue(reopened.favourites().contains(.folder(relative(work2))))
        XCTAssertTrue(try loadFile().ranked)
    }

    func testMoveFolderRemapsFavouriteTheSameWay() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let sub = try store.createFolder(named: "Sub", parent: work)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        let archive = try store.createFolder(named: "Archive", parent: root)
        try store.addFavourite(.folder(relative(work)))
        try store.addFavourite(.folder(relative(sub)))
        try store.addFavourite(.folder(relative(work2)))

        _ = try store.moveFolder(work, into: archive)
        let moved = archive.appendingPathComponent("Work", isDirectory: true)
        let movedSub = moved.appendingPathComponent("Sub", isDirectory: true)

        let items = store.favourites()
        XCTAssertTrue(items.contains(.folder(relative(moved))))
        XCTAssertTrue(items.contains(.folder(relative(movedSub))))
        XCTAssertTrue(items.contains(.folder(relative(work2))))
        XCTAssertFalse(items.contains(.folder("Work")))
        XCTAssertFalse(items.contains(.folder("Work/Sub")))
    }

    func testDeleteKeepsFavouriteWhileTrashedNoteCanRestoreThenDrops() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        try tagged("Report", tag: "dfir", in: work)
        try store.addFavourite(.folder(relative(work)))
        try store.addFavourite(.folder(relative(work2)))

        try store.deleteFolder(work)
        XCTAssertTrue(store.favourites().contains(.folder("Work")))
        XCTAssertTrue(store.favourites().contains(.folder(relative(work2))))

        let trashed = try XCTUnwrap(store.snapshots().first { $0.isTrashed })
        try store.restore([trashed.url], fallback: root)
        XCTAssertTrue(store.favourites().contains(.folder("Work")))

        try store.deleteFolder(root.appendingPathComponent("Work", isDirectory: true))
        let trashedAgain = store.snapshots().filter(\.isTrashed)
        try store.removeForever(trashedAgain.map(\.url))
        XCTAssertFalse(store.favourites().contains(.folder("Work")))
        XCTAssertTrue(store.favourites().contains(.folder(relative(work2))))

        _ = try store.createFolder(named: "Work", parent: root)
        XCTAssertFalse(store.favourites().contains(.folder("Work")))
    }

    func testDeleteEmptyFolderDropsFavouriteImmediately() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        try store.addFavourite(.folder(relative(work)))
        try store.addFavourite(.folder(relative(work2)))

        try store.deleteFolder(work)
        XCTAssertFalse(store.favourites().contains(.folder("Work")))
        XCTAssertTrue(store.favourites().contains(.folder(relative(work2))))
    }

    func testDeleteKeepsFavouriteWhileFolderResidueCanRestore() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        try Data("leftover\n".utf8).write(to: work.appendingPathComponent("keep.bin"))
        try store.addFavourite(.folder(relative(work)))

        try store.deleteFolder(work)
        XCTAssertTrue(
            store.favourites().contains(.folder("Work")),
            "residue in Trash can still bring the folder back"
        )
    }

    func testVanishedTagFavouriteDropsOnReload() throws {
        let record = try tagged("Report", tag: "dfir")
        try store.addFavourite(.tag("dfir"))
        XCTAssertTrue(store.favourites().contains(.tag("dfir")))

        store.applyTag("dfir", add: false, to: [record.url])
        store.rescan()
        XCTAssertFalse(store.favourites().contains(.tag("dfir")))

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertFalse(reopened.favourites().contains(.tag("dfir")))
    }

    func testRemovingTheLastFavouriteLeavesAnEmptySidecar() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        try store.addFavourite(.folder(relative(work)))
        try store.reorderFavourites(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertTrue(try loadFile().ranked)

        try store.removeFavourite(.folder(relative(work)))
        XCTAssertTrue(store.favourites().isEmpty)
        let file = try loadFile()
        XCTAssertTrue(file.items.isEmpty)
        XCTAssertFalse(file.ranked)

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertTrue(reopened.favourites().isEmpty)
    }

    func testMissingFavouritesFileStartsEmpty() {
        XCTAssertTrue(store.favourites().isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: LibraryPaths.favouritesURL(root: root).path))
    }

    func testMalformedFavouritesFileDoesNotCrashSetRoot() throws {
        try fm.createDirectory(
            at: LibraryPaths.sidecarURL(root: root), withIntermediateDirectories: true
        )
        try Data("{not json".utf8).write(
            to: LibraryPaths.favouritesURL(root: root), options: .atomic
        )
        store.setRoot(root)
        XCTAssertTrue(store.favourites().isEmpty)
    }

    func testEmptyAndInvalidEntriesAreIgnoredOnAdd() throws {
        let before = store.favouriteWriteCount
        try store.addFavourite(.folder(""))
        try store.addFavourite(.folder("  /  "))
        try store.addFavourite(.tag(""))
        try store.addFavourite(.tag("   "))
        try store.addFavourite(.note(""))
        try store.addFavourite(.note("   "))
        try store.addFavourite(.note("  /  "))
        XCTAssertEqual(store.favouriteWriteCount, before)
        XCTAssertTrue(store.favourites().isEmpty)
    }

    // MARK: - Note favourites

    @discardableResult
    private func note(_ name: String, in folder: URL? = nil) throws -> NoteRecord {
        try store.createNote(
            named: name, in: folder ?? root, extension: "md",
            body: NoteActions.newNoteBody(named: name)
        )
    }

    func testAddNotePersistsAcrossNewStoreAndSidecarUsesNoteKey() throws {
        let record = try note("Brief")
        try store.addFavourite(.note(record.relativePath))

        XCTAssertEqual(store.favourites(), [.note(record.relativePath)])
        let text = try String(contentsOf: LibraryPaths.favouritesURL(root: root), encoding: .utf8)
        XCTAssertTrue(text.contains("\"note\""))
        XCTAssertFalse(text.contains("_0"))

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertEqual(reopened.favourites(), [.note(record.relativePath)])
        XCTAssertTrue(reopened.isFavourite(.note(record.relativePath)))
    }

    func testOldFavouritesJSONWithoutNoteKeyStillDecodes() throws {
        let decoded = try JSONDecoder().decode(
            FavouriteFile.self,
            from: Data("""
            {
              "ranked": false,
              "items": [
                { "folder": "Work" },
                { "tag": "dfir" }
              ]
            }
            """.utf8)
        )
        XCTAssertFalse(decoded.ranked)
        XCTAssertEqual(decoded.items, [.folder("Work"), .tag("dfir")])

        let withNote = try JSONDecoder().decode(
            FavouriteFile.self,
            from: Data("""
            {
              "ranked": false,
              "items": [
                { "note": "Inbox/Brief.md" }
              ]
            }
            """.utf8)
        )
        XCTAssertEqual(withNote.items, [.note("Inbox/Brief.md")])
    }

    func testAddingADuplicateNoteDoesNotWrite() throws {
        let record = try note("Brief")
        try store.addFavourite(.note(record.relativePath))
        let before = store.favouriteWriteCount

        try store.addFavourite(.note(record.relativePath))
        try store.addFavourite(.note("  \(record.relativePath)  "))
        try store.addFavourite(.note(record.relativePath + "/"))

        XCTAssertEqual(store.favouriteWriteCount, before)
        XCTAssertEqual(store.favourites().count, 1)
    }

    func testUnrankedNoteSortsByLiveTitleThenTypeOrder() throws {
        let folder = try store.createFolder(named: "alpha", parent: root)
        let record = try note("report")
        try store.writeTitle(record.url, title: "alpha")
        try tagged("Tagged", tag: "alpha")

        try store.addFavourite(.tag("alpha"))
        try store.addFavourite(.note(record.relativePath))
        try store.addFavourite(.folder(relative(folder)))

        XCTAssertEqual(store.favourites(), [
            .folder(relative(folder)),
            .note(record.relativePath),
            .tag("alpha")
        ])
        XCTAssertFalse(try loadFile().ranked)
    }

    func testUnrankedNoteSortsByStemWhenTitleMatchesFile() throws {
        let zeta = try store.createFolder(named: "zeta", parent: root)
        let record = try note("alpha")
        try tagged("Tagged", tag: "beta")
        try store.addFavourite(.folder(relative(zeta)))
        try store.addFavourite(.note(record.relativePath))
        try store.addFavourite(.tag("beta"))

        XCTAssertEqual(store.favourites(), [
            .note(record.relativePath),
            .tag("beta"),
            .folder(relative(zeta))
        ])
    }

    func testReorderThenRankGovernsNote() throws {
        let folder = try store.createFolder(named: "zeta", parent: root)
        let record = try note("alpha")
        try tagged("Tagged", tag: "beta")
        try store.addFavourite(.folder(relative(folder)))
        try store.addFavourite(.note(record.relativePath))
        try store.addFavourite(.tag("beta"))
        XCTAssertEqual(store.favourites().first, .note(record.relativePath))

        try store.reorderFavourites(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.favourites(), [
            .folder(relative(folder)),
            .note(record.relativePath),
            .tag("beta")
        ])
        XCTAssertTrue(try loadFile().ranked)
    }

    func testRenameNoteRemapsFavouritePath() throws {
        let record = try note("Report")
        try store.addFavourite(.note(record.relativePath))
        try store.setPinned(record.url, true)

        let updated = try store.rename(record.url, to: "Brief", updateYAMLTitle: true)
        XCTAssertEqual(updated.relativePath, "Brief.md")
        XCTAssertTrue(store.isFavourite(.note(updated.relativePath)))
        XCTAssertFalse(store.isFavourite(.note("Report.md")))
        XCTAssertTrue(store.snapshot(for: updated.url)?.isPinned == true)

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertTrue(reopened.isFavourite(.note(updated.relativePath)))
        XCTAssertFalse(reopened.isFavourite(.note("Report.md")))
    }

    func testFolderRenameRemapsFavouriteNoteAndLeavesCousin() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        let nested = try note("Nested", in: work)
        let cousin = try note("Cousin", in: work2)
        try store.addFavourite(.note(nested.relativePath))
        try store.addFavourite(.note(cousin.relativePath))

        _ = try store.renameFolder(work, to: "Office")
        XCTAssertTrue(store.isFavourite(.note("Office/Nested.md")))
        XCTAssertFalse(store.isFavourite(.note("Work/Nested.md")))
        XCTAssertTrue(store.isFavourite(.note(cousin.relativePath)))

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertTrue(reopened.isFavourite(.note("Office/Nested.md")))
        XCTAssertTrue(reopened.isFavourite(.note(cousin.relativePath)))
    }

    func testMoveFolderRemapsFavouriteNoteAndLeavesCousin() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        let archive = try store.createFolder(named: "Archive", parent: root)
        let nested = try note("Nested", in: work)
        let cousin = try note("Cousin", in: work2)
        try store.addFavourite(.note(nested.relativePath))
        try store.addFavourite(.note(cousin.relativePath))

        _ = try store.moveFolder(work, into: archive)
        XCTAssertTrue(store.isFavourite(.note("Archive/Work/Nested.md")))
        XCTAssertFalse(store.isFavourite(.note("Work/Nested.md")))
        XCTAssertTrue(store.isFavourite(.note(cousin.relativePath)))
    }

    func testMoveNoteRemapsFavourite() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let record = try note("InboxNote")
        try store.addFavourite(.note(record.relativePath))

        try store.move([record.url], to: work)
        XCTAssertTrue(store.isFavourite(.note("Work/InboxNote.md")))
        XCTAssertFalse(store.isFavourite(.note("InboxNote.md")))
    }

    func testTrashKeepsFavouriteNoteRetargetedThenPermanentDeleteDrops() throws {
        let record = try note("Brief")
        try store.addFavourite(.note(record.relativePath))
        try store.setPinned(record.url, true)

        try store.trash([record.url])
        XCTAssertFalse(store.isFavourite(.note("Brief.md")))
        let trashed = try XCTUnwrap(store.snapshots().first { $0.isTrashed })
        XCTAssertTrue(store.isFavourite(.note(trashed.relativePath)))
        XCTAssertTrue(trashed.isPinned)

        try store.restore([trashed.url], fallback: root)
        let restored = try XCTUnwrap(store.snapshots().first { $0.title == "Brief" })
        XCTAssertFalse(restored.isTrashed)
        XCTAssertTrue(store.isFavourite(.note(restored.relativePath)))
        XCTAssertTrue(restored.isPinned)

        try store.trash([restored.url])
        let trashedAgain = try XCTUnwrap(store.snapshots().first { $0.isTrashed })
        try store.removeForever([trashedAgain.url])
        XCTAssertTrue(store.favourites().isEmpty)
        XCTAssertNil(store.snapshot(relativePath: trashedAgain.relativePath))
    }

    func testVanishedNoteFileDropsFavouriteOnReload() throws {
        let record = try note("Brief")
        try store.addFavourite(.note(record.relativePath))
        XCTAssertTrue(store.isFavourite(.note(record.relativePath)))

        try fm.removeItem(at: record.url)
        store.rescan()
        XCTAssertFalse(store.isFavourite(.note(record.relativePath)))

        let reopened = LibraryStore()
        reopened.setRoot(root)
        XCTAssertFalse(reopened.isFavourite(.note("Brief.md")))
    }

    func testNoteFavouriteIsIndependentOfPin() throws {
        let record = try note("Brief")
        try store.setPinned(record.url, true)
        try store.addFavourite(.note(record.relativePath))
        XCTAssertTrue(store.snapshot(for: record.url)?.isPinned == true)
        XCTAssertTrue(store.isFavourite(.note(record.relativePath)))

        try store.removeFavourite(.note(record.relativePath))
        XCTAssertTrue(store.snapshot(for: record.url)?.isPinned == true)
        XCTAssertFalse(store.isFavourite(.note(record.relativePath)))
    }
}
