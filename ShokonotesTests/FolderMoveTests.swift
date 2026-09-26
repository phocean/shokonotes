import XCTest
@testable import Shokonotes

@MainActor
final class FolderMoveTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-foldermove-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func note(_ name: String, in folder: URL) throws -> NoteRecord {
        try store.createNote(
            named: name, in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: name)
        )
    }

    // MARK: - Nominal

    func testMoveFolderCarriesNotesAndSubfolders() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let sub = try store.createFolder(named: "Sub", parent: work)
        let target = try store.createFolder(named: "Archive", parent: root)
        try note("Report", in: work)
        try note("Deep", in: sub)
        store.rescan()

        let moved = try store.moveFolder(work, into: target)

        XCTAssertEqual(moved, target.appendingPathComponent("Work", isDirectory: true).standardizedFileURL)
        XCTAssertFalse(fm.fileExists(atPath: work.path))
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("Report.md").path))
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("Sub/Deep.md").path))

        let deep = try String(
            contentsOf: moved.appendingPathComponent("Sub/Deep.md"), encoding: .utf8
        )
        XCTAssertEqual(deep, NoteActions.newNoteBody(named: "Deep"), "The body must not be rewritten")

        store.rescan()
        XCTAssertTrue(store.notes.contains { $0.relativePath == "Archive/Work/Report.md" })
        XCTAssertTrue(store.notes.contains { $0.relativePath == "Archive/Work/Sub/Deep.md" })
    }

    func testMoveFromSubfolderOntoRootIsAccepted() throws {
        let parent = try store.createFolder(named: "Parent", parent: root)
        let child = try store.createFolder(named: "Child", parent: parent)
        try note("Leaf", in: child)
        store.rescan()

        let moved = try store.moveFolder(child, into: root)

        XCTAssertEqual(moved, root.appendingPathComponent("Child", isDirectory: true).standardizedFileURL)
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("Leaf.md").path))
        XCTAssertFalse(fm.fileExists(atPath: parent.appendingPathComponent("Child").path))
    }

    // MARK: - Refusals

    func testDropIntoDescendantIsRefusedAndNothingMoves() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let sub = try store.createFolder(named: "Sub", parent: work)
        let deeper = try store.createFolder(named: "Deeper", parent: sub)
        try note("Report", in: work)
        store.rescan()

        XCTAssertThrowsError(try store.moveFolder(work, into: deeper)) { error in
            XCTAssertEqual(error as? FolderMoveError, .intoDescendant)
        }
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("Report.md").path))
        XCTAssertTrue(fm.fileExists(atPath: deeper.path))
        XCTAssertFalse(fm.fileExists(atPath: deeper.appendingPathComponent("Work").path))
    }

    func testDropOnItselfIsRefused() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        store.rescan()

        XCTAssertThrowsError(try store.moveFolder(work, into: work)) { error in
            XCTAssertEqual(error as? FolderMoveError, .intoDescendant)
        }
        XCTAssertTrue(fm.fileExists(atPath: work.path))
    }

    func testSiblingWithSharedPrefixIsNotADescendant() throws {
        let work = try store.createFolder(named: "Work", parent: root)
        let work2 = try store.createFolder(named: "Work2", parent: root)
        store.rescan()

        let moved = try store.moveFolder(work, into: work2)
        XCTAssertEqual(moved, work2.appendingPathComponent("Work", isDirectory: true).standardizedFileURL)
    }

    func testNameCollisionIsRefusedAndExistingFolderIsIntact() throws {
        let source = try store.createFolder(named: "Notes", parent: root)
        try note("Mine", in: source)
        let target = try store.createFolder(named: "Archive", parent: root)
        let clash = try store.createFolder(named: "Notes", parent: target)
        try note("Theirs", in: clash)
        store.rescan()

        XCTAssertThrowsError(try store.moveFolder(source, into: target)) { error in
            XCTAssertEqual(error as? FolderMoveError, .nameExists("Notes"))
        }
        // Nothing overwritten, nothing merged.
        XCTAssertTrue(fm.fileExists(atPath: clash.appendingPathComponent("Theirs.md").path))
        XCTAssertFalse(fm.fileExists(atPath: clash.appendingPathComponent("Mine.md").path))
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("Mine.md").path))
    }

    func testDropOnCurrentParentIsRefusedAsNoChange() throws {
        let parent = try store.createFolder(named: "Parent", parent: root)
        let child = try store.createFolder(named: "Child", parent: parent)
        store.rescan()

        XCTAssertThrowsError(try store.moveFolder(child, into: parent)) { error in
            XCTAssertEqual(error as? FolderMoveError, .noChange)
        }
        let rootLevel = try store.createFolder(named: "Loose", parent: root)
        XCTAssertThrowsError(try store.moveFolder(rootLevel, into: root)) { error in
            XCTAssertEqual(error as? FolderMoveError, .noChange)
        }
    }

    // MARK: - Sidecars

    func testMoveKeepsPins() throws {
        let folder = try store.createFolder(named: "Pinned", parent: root)
        let record = try note("Kept", in: folder)
        let target = try store.createFolder(named: "Box", parent: root)
        try store.setPinned(record.url, true)
        store.rescan()

        let moved = try store.moveFolder(folder, into: target)
        let snapshot = store.snapshot(for: moved.appendingPathComponent("Kept.md"))
        XCTAssertEqual(snapshot?.isPinned, true)
    }

    func testMoveRemapsFolderSymbols() throws {
        let folder = try store.createFolder(named: "Work", parent: root)
        let sub = try store.createFolder(named: "Sub", parent: folder)
        let target = try store.createFolder(named: "Box", parent: root)
        store.setFolderSymbol(folder, "briefcase")
        store.setFolderSymbol(sub, "folder.fill")

        let moved = try store.moveFolder(folder, into: target)
        let tree = store.folders()
        let box = tree.first { $0.name == "Box" }
        let work = box?.children?.first { $0.name == "Work" }
        XCTAssertEqual(work?.symbol, "briefcase")
        XCTAssertEqual(work?.children?.first { $0.name == "Sub" }?.symbol, "folder.fill")

        let reopened = LibraryStore()
        reopened.setRoot(root)
        let again = reopened.folders().first { $0.name == "Box" }?.children?.first { $0.name == "Work" }
        XCTAssertEqual(again?.symbol, "briefcase")
        XCTAssertEqual(again?.children?.first { $0.name == "Sub" }?.symbol, "folder.fill")
        XCTAssertEqual(moved.lastPathComponent, "Work")
    }
}

@MainActor
final class FolderMoveModelTests: XCTestCase {
    private var root: URL!
    private var model: LibraryModel!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-foldermove-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "shokonotes-foldermove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        model = LibraryModel(settings: AppSettings(defaults: defaults), store: LibraryStore()) { _, _ in }
        model.openRoot(root, skipActivate: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSelectionSurvivesMoveOfItsFolder() throws {
        let work = try model.store.createFolder(named: "Work", parent: root)
        let target = try model.store.createFolder(named: "Archive", parent: root)
        let record = try model.store.createNote(
            named: "Open", in: work, extension: "md",
            body: NoteActions.newNoteBody(named: "Open")
        )
        model.reloadEverything()
        model.sidebarSelection = .project(work)
        model.selectedNoteIDs = [record.url]

        guard let snapshot = model.folder(with: work) else {
            return XCTFail("Work folder missing from the sidebar tree")
        }
        XCTAssertNil(model.moveFolder(snapshot, into: target))

        let expected = target
            .appendingPathComponent("Work/Open.md")
            .standardizedFileURL
        XCTAssertEqual(model.selectedNoteIDs, [expected])
        XCTAssertEqual(model.focusedNote?.url, expected)
        XCTAssertEqual(
            model.sidebarSelection,
            .project(target.appendingPathComponent("Work", isDirectory: true).standardizedFileURL)
        )
        XCTAssertTrue(model.notes.contains { $0.url == expected })
    }

    func testRefusalIsReturnedAndLibraryIsUnchanged() throws {
        let work = try model.store.createFolder(named: "Work", parent: root)
        let sub = try model.store.createFolder(named: "Sub", parent: work)
        model.reloadEverything()

        guard let snapshot = model.folder(with: work) else {
            return XCTFail("Work folder missing from the sidebar tree")
        }
        XCTAssertEqual(model.moveFolder(snapshot, into: sub), .intoDescendant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        XCTAssertNotNil(model.folder(with: work))
    }
}
