import XCTest
@testable import Shokonotes

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateWritesFileWithYAML() throws {
        let body = NoteActions.newNoteBody(named: "Untitled Note")
        let record = try store.createNote(named: "Untitled Note", in: root, extension: "md", body: body)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.url.path))
        let text = try String(contentsOf: record.url, encoding: .utf8)
        XCTAssertTrue(text.contains("title: \"Untitled Note\""))
        XCTAssertEqual(record.folderURL.standardizedFileURL, root.standardizedFileURL)
    }

    func testCreateInSelectedFolderNotInbox() throws {
        let folder = try store.createFolder(named: "Projects", parent: root)
        let record = try store.createNote(
            named: "In folder",
            in: folder,
            extension: "md",
            body: NoteActions.newNoteBody(named: "In folder")
        )
        XCTAssertEqual(record.folderURL.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(record.url.path.contains("/Projects/"))
    }

    func testTrashAndRestoreToOriginalFolder() throws {
        let folder = try store.createFolder(named: "Kept", parent: root)
        let record = try store.createNote(
            named: "Parked",
            in: folder,
            extension: "md",
            body: NoteActions.newNoteBody(named: "Parked")
        )
        try store.trash([record.url])
        store.rescan()
        let trashed = store.notes.first { $0.fileNameMatches("Parked") }
        XCTAssertEqual(trashed?.isTrashed, true)

        try store.restore([trashed!.url], fallback: root)
        store.rescan()
        let restored = store.notes.first { $0.fileNameMatches("Parked") }
        XCTAssertEqual(restored?.isTrashed, false)
        XCTAssertEqual(restored?.folderURL.lastPathComponent, "Kept")
    }

    func testTagsRoundTripAndAppearOnNote() throws {
        let record = try store.createNote(
            named: "Tagged",
            in: root,
            extension: "md",
            body: NoteActions.newNoteBody(named: "Tagged")
        )
        store.applyTag("alpha", add: true, to: [record.url])
        store.rescan()
        let updated = store.notes.first { $0.fileNameMatches("Tagged") }
        XCTAssertEqual(updated?.tags, ["alpha"])
        XCTAssertTrue(store.tags().contains("alpha"))

        store.applyTag("alpha", add: false, to: [updated!.url])
        store.rescan()
        XCTAssertEqual(store.notes.first { $0.fileNameMatches("Tagged") }?.tags ?? ["x"], [])
    }

    func testSearchFindsBodyOfNeverOpenedNote() throws {
        let unique = "xylophone-unique-token-\(UUID().uuidString)"
        let url = root.appendingPathComponent("silent.md")
        try """
        ---
        title: "Silent"
        tags: []
        created: 2026-01-01
        ---

        Hidden \(unique) in the body.
        """.write(to: url, atomically: true, encoding: .utf8)

        store.rescan()
        let snapshots = store.snapshots()
        let matches = snapshots.filter { $0.matches(terms: [unique]) }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.title, "Silent")
    }

    func testYAMLColonTitleSurvivesCreate() throws {
        let record = try store.createNote(
            named: "Agenda: Monday",
            in: root,
            extension: "md",
            body: NoteActions.newNoteBody(named: "Agenda: Monday")
        )
        let text = try String(contentsOf: record.url, encoding: .utf8)
        XCTAssertTrue(text.contains("title: \"Agenda: Monday\""))
        store.rescan()
        XCTAssertEqual(store.snapshot(for: record.url)?.title, "Agenda: Monday")
    }

    func testDeleteFolderDoesNotTrashSiblingPrefix() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        _ = try store.createNote(
            named: "InWork", in: work, extension: "md",
            body: NoteActions.newNoteBody(named: "InWork")
        )
        _ = try store.createNote(
            named: "InWork2", in: work2, extension: "md",
            body: NoteActions.newNoteBody(named: "InWork2")
        )
        try store.deleteFolder(work)
        store.rescan()
        let remaining = store.notes.filter { $0.fileNameMatches("InWork2") }
        XCTAssertEqual(remaining.count, 1)
        XCTAssertFalse(remaining[0].isTrashed)
        XCTAssertTrue(store.notes.filter { $0.fileNameMatches("InWork") }.allSatisfy(\.isTrashed))
    }

    func testFolderRenameKeepsPins() throws {
        let folder = try store.createFolder(named: "OldPin", parent: root)
        let record = try store.createNote(
            named: "Pinned", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Pinned")
        )
        try store.setPinned(record.url, true)
        let renamed = try store.renameFolder(folder, to: "NewPin")
        store.rescan()
        let pinned = store.snapshots().first { $0.fileName == "Pinned" }
        XCTAssertEqual(pinned?.isPinned, true)
        XCTAssertEqual(pinned?.folderURL.lastPathComponent, "NewPin")
        _ = renamed
    }

    func testSameNameTrashRestoresOriginalFileName() throws {
        let a = try store.createFolder(named: "A", parent: root)
        let b = try store.createFolder(named: "B", parent: root)
        let first = try store.createNote(
            named: "Note", in: a, extension: "md",
            body: NoteActions.newNoteBody(named: "Note")
        )
        let second = try store.createNote(
            named: "Note", in: b, extension: "md",
            body: NoteActions.newNoteBody(named: "Note")
        )
        try store.trash([first.url, second.url])
        store.rescan()
        let trashed = store.notes.filter(\.isTrashed)
        XCTAssertEqual(trashed.count, 2)
        try store.restore(trashed.map(\.url), fallback: root)
        store.rescan()
        let restored = store.notes.filter { !$0.isTrashed }
        XCTAssertEqual(Set(restored.map { $0.folderURL.lastPathComponent }), ["A", "B"])
        XCTAssertTrue(restored.allSatisfy { $0.url.deletingPathExtension().lastPathComponent == "Note" })
    }

    func testICloudSettingDoesNotTrashNumberedUntitledNotes() throws {
        store.conflictResolutionEnabled = true
        _ = try store.createNote(
            named: "Untitled Note", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Untitled Note")
        )
        _ = try store.createNote(
            named: "Untitled Note 2", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Untitled Note 2")
        )
        store.rescan()
        let live = store.notes.filter { !$0.isTrashed }
        XCTAssertEqual(live.count, 2)
    }

    func testPinSurvivesRenameAndRescan() throws {
        let record = try store.createNote(
            named: "Pinned", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Pinned")
        )
        try store.setPinned(record.url, true)
        let renamed = try store.rename(record.url, to: "RenamedPin", updateYAMLTitle: true)
        store.rescan()
        XCTAssertEqual(store.snapshot(for: renamed.url)?.isPinned, true)
    }

    func testDeleteFolderMovesLeftoverFilesToTrash() throws {
        let folder = try store.createFolder(named: "WithImage", parent: root)
        _ = try store.createNote(
            named: "Caption", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Caption")
        )
        let image = folder.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try store.deleteFolder(folder)
        store.rescan()
        let trash = LibraryPaths.trashURL(root: root)
        var foundPhoto = false
        if let enumerator = FileManager.default.enumerator(at: trash, includingPropertiesForKeys: nil) {
            while let item = enumerator.nextObject() as? URL {
                if item.lastPathComponent == "photo.png" { foundPhoto = true }
            }
        }
        XCTAssertTrue(foundPhoto)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testWriteTitleDoesNotRenameFile() throws {
        let record = try store.createNote(
            named: "Untitled Note",
            in: root,
            extension: "md",
            body: NoteActions.newNoteBody(named: "Untitled Note")
        )
        try store.writeTitle(record.url, title: "toto")
        store.rescan()
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.url.path))
        XCTAssertEqual(record.url.deletingPathExtension().lastPathComponent, "Untitled Note")
        XCTAssertEqual(store.snapshot(for: record.url)?.title, "toto")
        let text = try String(contentsOf: record.url, encoding: .utf8)
        XCTAssertTrue(text.contains("title: \"toto\""))
    }

    func testRenameToTitleLeavesYAMLAndMovesFile() throws {
        let record = try store.createNote(
            named: "Untitled Note",
            in: root,
            extension: "md",
            body: NoteActions.newNoteBody(named: "toto")
        )
        let moved = try store.rename(record.url, to: "toto", updateYAMLTitle: false)
        XCTAssertEqual(moved.url.deletingPathExtension().lastPathComponent, "toto")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.url.path))
        let text = try String(contentsOf: moved.url, encoding: .utf8)
        XCTAssertTrue(text.contains("title: \"toto\""))
        XCTAssertFalse(text.contains("title: \"Untitled Note\""))
    }

    func testFollowTitleDoesNotRenameOnRescan() throws {
        let record = try store.createNote(
            named: "Untitled Note", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Real title")
        )
        store.rescan()
        XCTAssertEqual(
            store.snapshot(for: record.url)?.url.deletingPathExtension().lastPathComponent,
            "Untitled Note"
        )
    }

    func testRenameFolderAndDeleteFolder() throws {
        let folder = try store.createFolder(named: "Old", parent: root)
        _ = try store.createNote(
            named: "Inside",
            in: folder,
            extension: "md",
            body: NoteActions.newNoteBody(named: "Inside")
        )
        let renamed = try store.renameFolder(folder, to: "New")
        XCTAssertEqual(renamed.lastPathComponent, "New")
        store.rescan()
        XCTAssertTrue(store.notes.contains { $0.folderURL.lastPathComponent == "New" })

        try store.deleteFolder(renamed)
        store.rescan()
        XCTAssertTrue(store.notes.filter { $0.fileNameMatches("Inside") }.allSatisfy(\.isTrashed))
    }

    func testAttachmentFoldersAreHiddenFromSidebar() throws {
        let images = root.appendingPathComponent("i", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: images.appendingPathComponent("pic.png"))
        let assets = root.appendingPathComponent("Note.assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        _ = try store.createFolder(named: "Projects", parent: root)
        store.rescan()
        let names = Set(store.folders().map(\.name))
        XCTAssertTrue(names.contains("Projects"))
        XCTAssertFalse(names.contains("i"))
        XCTAssertFalse(names.contains("Note.assets"))
    }

    func testRestoreReunitesLeftoverFilesWithTheNote() throws {
        let folder = try store.createFolder(named: "WithImage", parent: root)
        let record = try store.createNote(
            named: "Caption", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Caption")
        )
        let image = folder.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try store.deleteFolder(folder)
        store.rescan()

        let trash = LibraryPaths.trashURL(root: root)
        XCTAssertTrue(fileExists(named: "photo.png", under: trash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        let trashed = try XCTUnwrap(store.notes.first { $0.fileNameMatches("Caption") })
        try store.restore([trashed.url], fallback: root)
        store.rescan()

        let restored = try XCTUnwrap(store.notes.first { $0.fileNameMatches("Caption") })
        XCTAssertFalse(restored.isTrashed)
        let restoredPhoto = restored.folderURL.appendingPathComponent("photo.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPhoto.path))
        XCTAssertFalse(fileExists(named: "photo.png", under: trash))
        _ = record
    }

    func testDeleteFolderPreservesHiddenLeftovers() throws {
        let folder = try store.createFolder(named: "HiddenBits", parent: root)
        _ = try store.createNote(
            named: "Note", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Note")
        )
        let hidden = folder.appendingPathComponent(".secret")
        try Data([0x01]).write(to: hidden)
        try store.deleteFolder(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(fileExists(named: ".secret", under: LibraryPaths.trashURL(root: root)))
    }

    func testDeleteFolderMovesFolderToTrashWhenListingFails() throws {
        let fm = FailingDirectoryListFileManager()
        let isolated = root.appendingPathComponent("iso", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        let failingStore = LibraryStore(fileManager: fm)
        failingStore.setRoot(isolated)

        let folder = try failingStore.createFolder(named: "Opaque", parent: isolated)
        _ = try failingStore.createNote(
            named: "Inside", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Inside")
        )
        let hidden = folder.appendingPathComponent(".keep")
        try Data([0x01]).write(to: hidden)

        fm.failListingOf = folder
        try failingStore.deleteFolder(folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(fileExists(named: ".keep", under: LibraryPaths.trashURL(root: isolated)))
        XCTAssertTrue(
            failingStore.notes.filter { $0.fileNameMatches("Inside") }.allSatisfy(\.isTrashed)
        )
    }

    func testTrashPersistsOriginsBeforeALaterFailure() throws {
        let folderA = try store.createFolder(named: "A", parent: root)
        let folderB = try store.createFolder(named: "B", parent: root)
        let first = try store.createNote(
            named: "KeepMe", in: folderA, extension: "md",
            body: NoteActions.newNoteBody(named: "KeepMe")
        )
        let second = try store.createNote(
            named: "Gone", in: folderB, extension: "md",
            body: NoteActions.newNoteBody(named: "Gone")
        )
        try FileManager.default.removeItem(at: second.url)
        XCTAssertThrowsError(try store.trash([first.url, second.url]))

        store.rescan()
        let trashed = try XCTUnwrap(store.notes.first { $0.fileNameMatches("KeepMe") })
        XCTAssertTrue(trashed.isTrashed)
        try store.restore([trashed.url], fallback: root)
        store.rescan()
        let restored = try XCTUnwrap(store.notes.first { $0.fileNameMatches("KeepMe") })
        XCTAssertFalse(restored.isTrashed)
        XCTAssertEqual(restored.folderURL.lastPathComponent, "A")
    }

    func testOriginFileDecodesWithoutFolderResidue() throws {
        let json = Data(#"{"items":{"Note.md":{"folder":"Kept","fileName":"Note.md"}}}"#.utf8)
        let file = try JSONDecoder().decode(OriginFile.self, from: json)
        XCTAssertEqual(file.items["Note.md"]?.folder, "Kept")
        XCTAssertNil(file.folderResidue)
    }

    func testEmptyTrashWipesFolderResidue() throws {
        let folder = try store.createFolder(named: "WithImage", parent: root)
        _ = try store.createNote(
            named: "Caption", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Caption")
        )
        let image = folder.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try store.deleteFolder(folder)

        let trash = LibraryPaths.trashURL(root: root)
        XCTAssertTrue(fileExists(named: "photo.png", under: trash))

        try store.emptyTrash()

        XCTAssertFalse(fileExists(named: "photo.png", under: trash))
        let origins = try decodeOrigins()
        XCTAssertTrue(origins.folderResidue == nil || origins.folderResidue?.isEmpty == true)
        XCTAssertTrue(store.notes.filter(\.isTrashed).isEmpty)

        let recreated = try store.createFolder(named: "WithImage", parent: root)
        let fresh = try store.createNote(
            named: "NewCaption", in: recreated, extension: "md",
            body: NoteActions.newNoteBody(named: "NewCaption")
        )
        try store.trash([fresh.url])
        let trashed = try XCTUnwrap(store.notes.first { $0.fileNameMatches("NewCaption") })
        try store.restore([trashed.url], fallback: root)
        let restored = try XCTUnwrap(store.notes.first { $0.fileNameMatches("NewCaption") })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: restored.folderURL.appendingPathComponent("photo.png").path
        ))
    }

    func testRemoveForeverPrunesResidueOnlyWhenNothingCanRestoreIntoIt() throws {
        let folder = try store.createFolder(named: "WithImage", parent: root)
        _ = try store.createNote(
            named: "Caption", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Caption")
        )
        _ = try store.createNote(
            named: "Other", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Other")
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("photo.png"))
        try store.deleteFolder(folder)

        let trash = LibraryPaths.trashURL(root: root)
        let first = try XCTUnwrap(store.notes.first { $0.fileNameMatches("Caption") })
        try store.removeForever([first.url])
        XCTAssertTrue(fileExists(named: "photo.png", under: trash))
        XCTAssertEqual(try decodeOrigins().folderResidue?.values.contains("WithImage"), true)

        let remaining = try XCTUnwrap(store.notes.first { $0.fileNameMatches("Other") })
        try store.removeForever([remaining.url])
        XCTAssertFalse(fileExists(named: "photo.png", under: trash))
        let origins = try decodeOrigins()
        XCTAssertTrue(origins.folderResidue == nil || origins.folderResidue?.isEmpty == true)
    }

    func testRemoveForeverKeepsOriginWhenUnlinkFails() throws {
        let fm = FailingRemoveFileManager()
        let isolated = root.appendingPathComponent("unlink", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        let failingStore = LibraryStore(fileManager: fm)
        failingStore.setRoot(isolated)

        let folder = try failingStore.createFolder(named: "Kept", parent: isolated)
        let record = try failingStore.createNote(
            named: "Parked", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Parked")
        )
        try failingStore.trash([record.url])
        let trashed = try XCTUnwrap(failingStore.notes.first { $0.fileNameMatches("Parked") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.url.path))

        fm.failRemoveOf = trashed.url
        XCTAssertThrowsError(try failingStore.removeForever([trashed.url]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.url.path))
        XCTAssertEqual(failingStore.snapshot(for: trashed.url)?.isTrashed, true)

        fm.failRemoveOf = nil
        try failingStore.restore([trashed.url], fallback: isolated)
        let restored = try XCTUnwrap(failingStore.notes.first { $0.fileNameMatches("Parked") })
        XCTAssertFalse(restored.isTrashed)
        XCTAssertEqual(restored.folderURL.lastPathComponent, "Kept")
    }

    func testPinPersistFailureRevertsMemory() throws {
        let record = try store.createNote(
            named: "Pinned", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Pinned")
        )
        try store.setPinned(record.url, true)
        XCTAssertEqual(store.snapshot(for: record.url)?.isPinned, true)

        let pinsURL = LibraryPaths.pinsURL(root: root)
        let originalPins = try Data(contentsOf: pinsURL)
        try FileManager.default.removeItem(at: pinsURL)
        try FileManager.default.createDirectory(at: pinsURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.setPinned(record.url, false)) { error in
            XCTAssertEqual(error as? LibraryError, .sidecarWriteFailed)
        }
        XCTAssertEqual(store.snapshot(for: record.url)?.isPinned, true)

        XCTAssertThrowsError(try store.togglePins([record.url])) { error in
            XCTAssertEqual(error as? LibraryError, .sidecarWriteFailed)
        }
        XCTAssertEqual(store.snapshot(for: record.url)?.isPinned, true)

        try FileManager.default.removeItem(at: pinsURL)
        try originalPins.write(to: pinsURL, options: .atomic)
        store.rescan()
        XCTAssertEqual(store.snapshot(for: record.url)?.isPinned, true)
    }

    func testNestedTrashNotesKeepDistinctOrigins() throws {
        let trash = LibraryPaths.trashURL(root: root)
        let nestedDir = trash.appendingPathComponent("Leftover", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let body = NoteActions.newNoteBody(named: "Note")
        try body.write(to: trash.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try body.write(to: nestedDir.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let file = OriginFile(
            items: [
                "Note.md": OriginRecord(folder: "A", fileName: "Note.md"),
                "Leftover/Note.md": OriginRecord(folder: "B", fileName: "Note.md")
            ],
            folderResidue: nil
        )
        try JSONEncoder().encode(file).write(to: LibraryPaths.originsURL(root: root), options: .atomic)
        store.rescan()

        let nested = try XCTUnwrap(store.notes.first {
            $0.isTrashed && $0.url.path.contains("/Leftover/")
        })
        let flat = try XCTUnwrap(store.notes.first {
            $0.isTrashed && $0.folderURL.standardizedFileURL == trash.standardizedFileURL
        })

        try store.restore([nested.url], fallback: root)
        let restoredNested = try XCTUnwrap(store.notes.first { $0.fileNameMatches("Note") && !$0.isTrashed })
        XCTAssertEqual(restoredNested.folderURL.lastPathComponent, "B")

        let stillTrashed = try XCTUnwrap(store.notes.first { $0.isTrashed })
        XCTAssertEqual(stillTrashed.url.standardizedFileURL, flat.url.standardizedFileURL)
        try store.restore([stillTrashed.url], fallback: root)
        let restoredFlat = try XCTUnwrap(store.notes.first {
            $0.fileNameMatches("Note") && $0.folderURL.lastPathComponent == "A"
        })
        XCTAssertFalse(restoredFlat.isTrashed)
    }

    func testApplyTagDoesNotSplitSingleQuotedCommaTags() throws {
        let url = root.appendingPathComponent("quoted.md")
        try """
        ---
        title: "A"
        tags: ['hello, world', 'c']
        created: 2026-01-01
        ---
        Body
        """.write(to: url, atomically: true, encoding: .utf8)
        store.rescan()
        store.applyTag("d", add: true, to: [url])
        XCTAssertEqual(store.snapshot(for: url)?.tags, ["hello, world", "c", "d"])
    }

    func testApplyTagDoesNotBakeInlineTitleComment() throws {
        let url = root.appendingPathComponent("comment.md")
        try """
        ---
        title: "Hello" # keep
        tags: []
        created: 2026-01-01
        ---
        Body
        """.write(to: url, atomically: true, encoding: .utf8)
        store.rescan()
        store.applyTag("x", add: true, to: [url])
        XCTAssertEqual(store.snapshot(for: url)?.title, "Hello")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("title: \"Hello\""))
        XCTAssertFalse(text.contains("\\\"Hello\\\""))
    }

    func testShouldReadNoteFileWhenNotUbiquitous() {
        XCTAssertTrue(LibraryStore.shouldReadNoteFile(isUbiquitous: false, downloadingStatus: nil))
        XCTAssertTrue(LibraryStore.shouldReadNoteFile(isUbiquitous: false, downloadingStatus: .notDownloaded))
    }

    func testShouldReadNoteFileWhenUbiquitousKeysMissing() {
        XCTAssertTrue(LibraryStore.shouldReadNoteFile(isUbiquitous: nil, downloadingStatus: nil))
    }

    func testShouldReadNoteFileWhenUbiquitousAndStatusMissing() {
        XCTAssertTrue(LibraryStore.shouldReadNoteFile(isUbiquitous: true, downloadingStatus: nil))
    }

    func testShouldReadNoteFileWhenUbiquitousAndCurrent() {
        XCTAssertTrue(LibraryStore.shouldReadNoteFile(isUbiquitous: true, downloadingStatus: .current))
    }

    func testShouldReadNoteFileWhenUbiquitousAndNotDownloaded() {
        XCTAssertFalse(LibraryStore.shouldReadNoteFile(isUbiquitous: true, downloadingStatus: .notDownloaded))
    }

    func testShouldReadNoteFileWhenUbiquitousAndDownloadedNotCurrent() {
        XCTAssertFalse(LibraryStore.shouldReadNoteFile(isUbiquitous: true, downloadingStatus: .downloaded))
    }

    func testAttachmentFolderPatternsAreConfigurable() throws {
        XCTAssertTrue(LibraryPaths.isAttachmentFolderName("i", patterns: ["i", "*.assets"]))
        XCTAssertTrue(LibraryPaths.isAttachmentFolderName("Note.assets", patterns: ["*.assets"]))
        XCTAssertFalse(LibraryPaths.isAttachmentFolderName("i", patterns: ["img"]))
        XCTAssertTrue(LibraryPaths.isAttachmentFolderName("img", patterns: ["img"]))
        XCTAssertFalse(LibraryPaths.isAttachmentFolderName("i", patterns: []))

        let images = root.appendingPathComponent("i", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let img = root.appendingPathComponent("img", isDirectory: true)
        try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)
        store.attachmentFolderPatterns = ["img"]
        let names = Set(store.folders().map(\.name))
        XCTAssertTrue(names.contains("i"))
        XCTAssertFalse(names.contains("img"))
    }

    // MARK: - Incremental rescan

    /// The 15-second poll on the phone must not re-read 443 files to learn that
    /// nothing changed.
    func testIdleRescanReusesEveryRecordAndReadsNothing() throws {
        for index in 1...3 {
            try write("Note \(index)", body: "---\ntitle: \"Note \(index)\"\n---\nbody \(index)")
        }
        store.rescan()
        let first = store.notes.sorted { $0.title < $1.title }

        store.rescan()
        XCTAssertEqual(store.reusedRecordCount, 3)
        let second = store.notes.sorted { $0.title < $1.title }
        XCTAssertEqual(first, second)
    }

    func testChangedContentIsRereadEvenAtTheSameSize() throws {
        let url = try write("Same size", body: "---\ntitle: \"AAA\"\n---\nbody")
        store.rescan()
        XCTAssertEqual(store.notes.first(where: { $0.url == url })?.title, "AAA")

        let before = try String(contentsOf: url, encoding: .utf8)
        let after = before.replacingOccurrences(of: "AAA", with: "BBB")
        XCTAssertEqual(before.count, after.count, "the size must not move, only the bytes")
        try after.write(to: url, atomically: true, encoding: .utf8)

        store.rescan()
        XCTAssertEqual(store.reusedRecordCount, 0)
        XCTAssertEqual(store.notes.first(where: { $0.url == url })?.title, "BBB")
    }

    func testGrownContentIsReread() throws {
        let url = try write("Grows", body: "---\ntitle: \"Grows\"\n---\nshort")
        store.rescan()
        try "---\ntitle: \"Grows\"\n---\nmuch longer body than before"
            .write(to: url, atomically: true, encoding: .utf8)
        store.rescan()
        XCTAssertEqual(store.notes.first(where: { $0.url == url })?.rawBody.contains("much longer"), true)
    }

    func testDeletedFileDisappearsFromAnIncrementalPass() throws {
        let kept = try write("Kept", body: "---\ntitle: \"Kept\"\n---\nkept")
        let gone = try write("Gone", body: "---\ntitle: \"Gone\"\n---\ngone")
        store.rescan()
        XCTAssertEqual(store.notes.count, 2)

        try FileManager.default.removeItem(at: gone)
        store.rescan()
        XCTAssertEqual(store.notes.map(\.url), [kept.standardizedFileURL])
        XCTAssertEqual(store.reusedRecordCount, 1)
    }

    func testMovedFileKeepsOneRecordUnderItsNewPath() throws {
        let url = try write("Travels", body: "---\ntitle: \"Travels\"\n---\nbody")
        store.rescan()
        let folder = try store.createFolder(named: "Elsewhere", parent: root)
        try FileManager.default.moveItem(
            at: url, to: folder.appendingPathComponent("Travels.md")
        )
        store.rescan()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.folderURL.lastPathComponent, "Elsewhere")
        XCTAssertEqual(store.reusedRecordCount, 0)
    }

    /// The trap of this cache: no file moved, but the title rule did.
    func testChangingUseFirstLineAsTitleInvalidatesTheCache() throws {
        try write("Filed", body: "The first line wins\n\nmore body")
        store.useFirstLineAsTitle = true
        store.rescan()
        XCTAssertEqual(store.notes.first?.title, "The first line wins")

        store.useFirstLineAsTitle = false
        store.rescan()
        XCTAssertEqual(store.reusedRecordCount, 0)
        XCTAssertEqual(store.notes.first?.title, "Filed")

        // And the pass after that is cheap again.
        store.rescan()
        XCTAssertEqual(store.reusedRecordCount, 1)
        XCTAssertEqual(store.notes.first?.title, "Filed")
    }

    /// An incremental pass must land on exactly what a cold store reads.
    func testIncrementalResultMatchesAFullRescan() throws {
        let folder = try store.createFolder(named: "Deep", parent: root)
        try write("One", body: "---\ntitle: \"One\"\ntags: [a, b]\n---\nbody one")
        try write("Two", body: "Two by first line\n\nbody two")
        let nested = folder.appendingPathComponent("Three.md")
        try "---\ntitle: \"Three\"\n---\nbody three".write(to: nested, atomically: true, encoding: .utf8)
        store.rescan()
        try store.trash([nested.standardizedFileURL])
        store.rescan()
        store.rescan()

        let fresh = LibraryStore()
        fresh.setRoot(root)
        XCTAssertEqual(
            store.notes.sorted { $0.relativePath < $1.relativePath },
            fresh.notes.sorted { $0.relativePath < $1.relativePath }
        )
    }

    @discardableResult
    private func write(_ name: String, body: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }
}

private extension LibraryStoreTests {
    func decodeOrigins() throws -> OriginFile {
        let data = try Data(contentsOf: LibraryPaths.originsURL(root: root))
        return try JSONDecoder().decode(OriginFile.self, from: data)
    }

    func fileExists(named name: String, under directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return false }
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == name { return true }
        }
        return false
    }
}

private extension NoteRecord {
    func fileNameMatches(_ name: String) -> Bool {
        url.deletingPathExtension().lastPathComponent == name
    }
}

/// `contentsOfDirectory` throws for one path so deleteFolder cannot treat a
/// failed listing as empty.
private final class FailingDirectoryListFileManager: FileManager, @unchecked Sendable {
    var failListingOf: URL?

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if let failListingOf,
           url.standardizedFileURL == failListingOf.standardizedFileURL {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}

/// `removeItem` throws for one URL so a failed unlink cannot drop the origin.
private final class FailingRemoveFileManager: FileManager, @unchecked Sendable {
    var failRemoveOf: URL?

    override func removeItem(at url: URL) throws {
        if let failRemoveOf,
           url.standardizedFileURL == failRemoveOf.standardizedFileURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
