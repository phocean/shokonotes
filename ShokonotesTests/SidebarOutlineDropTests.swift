import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Shokonotes

/// The sidebar's drop decision, taken apart from `NSOutlineView`: given what is
/// dragged and where the cursor is, what lights up and where the item goes.
/// Nothing here proves a rendering — the insertion line itself is the human's
/// to look at.
final class SidebarOutlineDropTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ components: String...) throws -> URL {
        var url = root!
        for component in components {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func inside(_ destination: URL) -> SidebarDropAim {
        SidebarDropAim(rowDestination: destination, siblingParent: nil, onEdge: false)
    }

    private func edge(of row: URL, parent: URL) -> SidebarDropAim {
        SidebarDropAim(rowDestination: row, siblingParent: parent, onEdge: true)
    }

    // MARK: - Structure

    func testDropIntoOwnDescendantIsRefused() throws {
        let work = try folder("Work")
        let nested = try folder("Work", "Notes")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(work), aim: inside(nested)),
            .refuse)
    }

    func testDropOnItselfIsRefused() throws {
        let work = try folder("Work")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(work), aim: inside(work)),
            .refuse)
    }

    /// Dropping a folder back on the parent it already has changes nothing, so
    /// the row does not light up at all.
    func testDropOnCurrentParentIsRefused() throws {
        let work = try folder("Work")
        let child = try folder("Work", "Ideas")
        XCTAssertEqual(SidebarOutlineDrop.structuralVerdict(moving: child, into: work), .noChange)
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(child), aim: inside(work)),
            .refuse)
    }

    /// The same non-event through the insertion line: a first-level folder aimed
    /// at the first level is already there.
    func testSiblingLineAtTheLevelItAlreadyHasIsRefused() throws {
        let work = try folder("Work")
        let other = try folder("Personal")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(work), aim: edge(of: other, parent: root)),
            .refuse)
    }

    /// A collision is invisible to the eye: it is accepted for display so the
    /// engine can refuse it and the human is told why.
    func testNameCollisionStaysAcceptedForDisplay() throws {
        let work = try folder("Work")
        let ideas = try folder("Work", "Ideas")
        let personal = try folder("Personal")
        _ = try folder("Personal", "Ideas")
        XCTAssertEqual(
            SidebarOutlineDrop.structuralVerdict(moving: ideas, into: personal),
            .nameExists("Ideas"))
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(ideas), aim: inside(personal)),
            .onRow(destination: personal))
        XCTAssertNotNil(work)
    }

    // MARK: - Level

    func testEdgeOfAFirstLevelRowAimsAtTheLibraryRoot() throws {
        let deep = try folder("Work", "Ideas", "Later")
        let personal = try folder("Personal")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(deep), aim: edge(of: personal, parent: root)),
            .between(parent: root))
    }

    func testEdgeOfANestedRowAimsAtThatRowsParent() throws {
        let personal = try folder("Personal")
        let work = try folder("Work")
        let sibling = try folder("Work", "Ideas")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(personal), aim: edge(of: sibling, parent: work)),
            .between(parent: work))
    }

    func testBodyOfARowMeansInsideIt() throws {
        let personal = try folder("Personal")
        let work = try folder("Work")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(personal), aim: inside(work)),
            .onRow(destination: work))
    }

    // MARK: - Notes

    /// A note has no level to choose, so an aim between two rows is retargeted
    /// onto the row itself.
    func testNoteOnAnEdgeIsRetargetedOntoTheRow() throws {
        let work = try folder("Work")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .notes, aim: edge(of: work, parent: root)),
            .onRow(destination: work))
    }

    func testNoteOnARowWithNoFolderIsRefused() {
        XCTAssertEqual(SidebarOutlineDrop.plan(payload: .notes, aim: .nowhere), .refuse)
    }

    /// Notes land in the Inbox, which is the library root itself, and the
    /// structural rules for folders do not apply to them.
    func testNoteLandsInTheInboxRow() {
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .notes, aim: inside(root)),
            .onRow(destination: root))
    }

    // MARK: - Rows that take nothing

    func testAimAtNothingIsRefusedForAFolderToo() throws {
        let work = try folder("Work")
        XCTAssertEqual(SidebarOutlineDrop.plan(payload: .folder(work), aim: .nowhere), .refuse)
    }

    /// A row that stands for no folder — All Notes, Untagged, Trash, a tag —
    /// reports no sibling level, so its edges decide nothing either.
    func testRowWithoutALevelNeverDrawsAnInsertionLine() throws {
        let work = try folder("Work")
        let aim = SidebarDropAim(rowDestination: nil, siblingParent: nil, onEdge: true)
        XCTAssertEqual(SidebarOutlineDrop.plan(payload: .folder(work), aim: aim), .refuse)
    }

    // MARK: - The decision, with the verdict stubbed

    func testPlanAsksTheValidatorForTheDestinationItReports() throws {
        let work = try folder("Work")
        let personal = try folder("Personal")
        var asked: [String] = []
        let plan = SidebarOutlineDrop.plan(
            payload: .folder(work),
            aim: edge(of: personal, parent: root),
            validate: { source, destination in
                asked.append("\(source.lastPathComponent)→\(destination.lastPathComponent)")
                return nil
            })
        XCTAssertEqual(plan, .between(parent: root))
        XCTAssertEqual(asked, ["Work→\(root.lastPathComponent)"])
    }

    func testPlanRefusesWhateverTheValidatorRefuses() throws {
        let work = try folder("Work")
        let personal = try folder("Personal")
        XCTAssertEqual(
            SidebarOutlineDrop.plan(
                payload: .folder(work), aim: inside(personal),
                validate: { _, _ in .invalidDestination }),
            .refuse)
    }

    // MARK: - Reading the payload
    //
    // The one decodable step of both note paths: the synchronous pasteboard
    // read and the `NSItemProvider` fallback hand their bytes to the same
    // function, so what holds here holds for both. Nothing here proves that
    // AppKit materializes a promised type — that is exactly why the fallback
    // exists.

    func testNoteReferenceDecodesToItsURL() throws {
        let note = root.appendingPathComponent("Ideas.md")
        let payload = try JSONEncoder().encode(NoteTransfer(url: note))
        XCTAssertEqual(SidebarOutlineDrop.noteURL(from: payload), note)
    }

    func testNoteReferenceSurvivesARoundTripThroughThePasteboard() throws {
        let note = root.appendingPathComponent("Ideas.md")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shokonotes-test-\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(NoteTransfer(url: note)),
                     forType: NSPasteboard.PasteboardType(UTType.shokonotesNote.identifier))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertEqual(SidebarOutlineDrop.noteURLs(on: pasteboard), [note])
        pasteboard.releaseGlobally()
    }

    func testGarbagePayloadDecodesToNothing() {
        XCTAssertNil(SidebarOutlineDrop.noteURL(from: Data("not json".utf8)))
        XCTAssertNil(SidebarOutlineDrop.noteURL(from: Data()))
    }

    /// An undecodable payload is dropped, never substituted: the notes that did
    /// decode still move, and the one that did not is simply not in the list.
    func testUndecodablePayloadsAreDroppedNotSubstituted() throws {
        let first = root.appendingPathComponent("One.md")
        let second = root.appendingPathComponent("Two.md")
        let payloads = [
            try JSONEncoder().encode(NoteTransfer(url: first)),
            Data("{}".utf8),
            try JSONEncoder().encode(NoteTransfer(url: second)),
        ]
        XCTAssertEqual(SidebarOutlineDrop.noteURLs(from: payloads), [first, second])
    }

    /// The fallback in `payload(on:)`: when `endedAt` has already cleared the
    /// session record, the folder is still readable from the bytes the outline
    /// wrote itself.
    func testFolderReferenceIsReadableFromThePasteboard() throws {
        let work = try folder("Work")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shokonotes-test-\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(FolderTransfer(url: work)),
                     forType: NSPasteboard.PasteboardType(UTType.shokonotesFolder.identifier))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertEqual(SidebarOutlineDrop.folderURL(on: pasteboard), work)
        pasteboard.releaseGlobally()
    }
}
