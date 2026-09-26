import AppKit
import XCTest
@testable import Shokonotes

/// AppKit's swipe banner contract: `rowActionsVisible` may be set to `false`,
/// never to `true`. These tests hold `NoteListRowActions` to that, without
/// synthesising a swipe, creating an `NSWindow`, or driving the installed app.
///
/// A windowed table was tried and pulled: XCTest's memory checker then
/// `objc_release`s the window on the way out of the test (`EXC_BAD_ACCESS` in
/// `XCTMemoryChecker`). The register path does not need a window.
@MainActor
final class NoteListRowActionsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NoteListRowActions.reset()
    }

    override func tearDown() {
        NoteListRowActions.reset()
        super.tearDown()
    }

    func testDismissOnAPlainTableWithHiddenActionsIsANoOp() {
        let table = NSTableView()
        XCTAssertFalse(table.rowActionsVisible)
        NoteListRowActions.dismiss()
        XCTAssertFalse(table.rowActionsVisible)
        XCTAssertNil(NoteListRowActions.registeredTable)
    }

    func testDismissAfterRegisterDoesNotSetRowActionsVisibleTrue() {
        let table = RecordingTableView()
        NoteListRowActions.register(table)
        XCTAssertTrue(NoteListRowActions.registeredTable === table)
        XCTAssertFalse(table.rowActionsVisible)
        NoteListRowActions.dismiss()
        XCTAssertFalse(table.assignments.contains(true), "dismiss must never write true")
        XCTAssertFalse(table.rowActionsVisible)
    }

    func testDismissHidesAVisibleBannerByWritingFalse() {
        let table = OpenBannerTable()
        NoteListRowActions.register(table)
        XCTAssertTrue(table.rowActionsVisible)
        NoteListRowActions.dismiss()
        XCTAssertEqual(table.assignments, [false])
        XCTAssertFalse(table.rowActionsVisible)
    }

    func testRegisterFromTheRowProbeTalksToThatTable() {
        let other = OpenBannerTable()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 36))
        table.addSubview(row)
        let probe = ListHighlightSuppressor.Probe(frame: .zero)
        row.addSubview(probe)
        probe.suppress()

        XCTAssertTrue(NoteListRowActions.registeredTable === table)
        XCTAssertFalse(NoteListRowActions.registeredTable === other)
        XCTAssertFalse(table.rowActionsVisible)
        NoteListRowActions.dismiss()
        XCTAssertFalse(table.rowActionsVisible)
        XCTAssertTrue(other.assignments.isEmpty, "dismiss must not talk to a table it did not register")

        probe.removeFromSuperview()
        row.removeFromSuperview()
    }

    func testRegisterSkipsTheSidebarOutline() {
        let sidebar = SidebarOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        NoteListRowActions.register(sidebar)
        XCTAssertNil(NoteListRowActions.registeredTable)
        NoteListRowActions.dismiss()
    }

    func testRegisterReplacesTheTableDismissTalksTo() {
        let first = OpenBannerTable()
        let second = OpenBannerTable()
        NoteListRowActions.register(first)
        NoteListRowActions.register(second)
        NoteListRowActions.dismiss()
        XCTAssertTrue(first.assignments.isEmpty)
        XCTAssertEqual(second.assignments, [false])
    }
}

/// Records every write to `rowActionsVisible` so a test can see a `true` that
/// must never be sent.
private final class RecordingTableView: NSTableView {
    private(set) var assignments: [Bool] = []

    override var rowActionsVisible: Bool {
        get { super.rowActionsVisible }
        set { assignments.append(newValue) }
    }
}

/// Getter reports a live banner without asking AppKit to present one. Neither
/// write goes to `super`: a table with no columns is cell-based, and AppKit
/// throws `NSInternalInconsistencyException` ("setRowActionsVisible: is only
/// for view based NSTableView") on any assignment. The real note list is
/// view-based; this double only records what `dismiss()` would write.
private final class OpenBannerTable: NSTableView {
    private var visible = true
    private(set) var assignments: [Bool] = []

    override var rowActionsVisible: Bool {
        get { visible }
        set {
            assignments.append(newValue)
            visible = newValue
        }
    }
}
