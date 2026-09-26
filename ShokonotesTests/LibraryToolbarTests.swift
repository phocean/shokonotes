import XCTest
@testable import Shokonotes

/// Identifier order and the single-note enablement rule, without an `NSWindow`.
final class LibraryToolbarTests: XCTestCase {

    func testExportPrintAndShareAreAdjacentInThePreviewZoneWhenTheSidebarIsVisible() {
        XCTAssertEqual(
            LibraryToolbarLayout.identifiers(sidebarVisible: true),
            [
                .flexibleSpace,
                LibraryToolbarLayout.sidebar, .space, LibraryToolbarLayout.newFolder, .space,
                LibraryToolbarLayout.sidebarSeparator,
                LibraryToolbarLayout.newNote, LibraryToolbarLayout.search, LibraryToolbarLayout.sort,
                LibraryToolbarLayout.listSeparator,
                .flexibleSpace,
                LibraryToolbarLayout.exportPDF, LibraryToolbarLayout.print, LibraryToolbarLayout.share, .space,
                LibraryToolbarLayout.settings, LibraryToolbarLayout.editor,
            ]
        )
    }

    func testExportPrintAndShareAreAdjacentInThePreviewZoneWhenTheSidebarIsHidden() {
        XCTAssertEqual(
            LibraryToolbarLayout.identifiers(sidebarVisible: false),
            [
                LibraryToolbarLayout.sidebar, .space, LibraryToolbarLayout.newFolder, .space,
                LibraryToolbarLayout.newNote, LibraryToolbarLayout.search, LibraryToolbarLayout.sort,
                LibraryToolbarLayout.listSeparator,
                .flexibleSpace,
                LibraryToolbarLayout.exportPDF, LibraryToolbarLayout.print, LibraryToolbarLayout.share, .space,
                LibraryToolbarLayout.settings, LibraryToolbarLayout.editor,
            ]
        )
    }

    func testSingleNoteActionNeedsExactlyOneNoteStillInTheList() {
        let a = URL(fileURLWithPath: "/notes/a.md")
        let b = URL(fileURLWithPath: "/notes/b.md")
        XCTAssertFalse(
            LibraryToolbarLayout.isSingleNoteActionEnabled(selectedNoteIDs: [], visibleNoteIDs: [a]),
            "nothing selected")
        XCTAssertFalse(
            LibraryToolbarLayout.isSingleNoteActionEnabled(selectedNoteIDs: [a, b], visibleNoteIDs: [a, b]),
            "several selected")
        XCTAssertFalse(
            LibraryToolbarLayout.isSingleNoteActionEnabled(selectedNoteIDs: [a], visibleNoteIDs: [b]),
            "the selected note is not in the visible list")
        XCTAssertFalse(
            LibraryToolbarLayout.isSingleNoteActionEnabled(selectedNoteIDs: [a], visibleNoteIDs: []),
            "empty list")
        XCTAssertTrue(
            LibraryToolbarLayout.isSingleNoteActionEnabled(selectedNoteIDs: [a], visibleNoteIDs: [a, b]))
        XCTAssertTrue(
            LibraryToolbarLayout.isSingleNoteActionEnabled(selectedNoteIDs: [a], visibleNoteIDs: [a]))
    }
}
