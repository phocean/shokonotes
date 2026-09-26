import XCTest
@testable import Shokonotes

final class LibraryKeyboardTests: XCTestCase {
    // Moving between columns is not covered here on purpose: it lives in the
    // three guarded handlers (`LibraryView`'s note-list and preview
    // `.onKeyPress`, and `SidebarOutlineView.keyDown`), not in a pure function.
    // The `movePane` assertions that used to sit here asserted a copy nobody
    // called. What follows tests what the handlers actually ask.

    func testSpaceTogglesOnlyFoldersWithChildren() {
        let child = FolderSnapshot(url: URL(fileURLWithPath: "/notes/Work/A"), name: "A", parentURL: URL(fileURLWithPath: "/notes/Work"), children: nil)
        let work = FolderSnapshot(url: URL(fileURLWithPath: "/notes/Work"), name: "Work", parentURL: URL(fileURLWithPath: "/notes"), children: [child])
        let leaf = FolderSnapshot(url: URL(fileURLWithPath: "/notes/Leaf"), name: "Leaf", parentURL: URL(fileURLWithPath: "/notes"), children: nil)

        XCTAssertNil(LibraryKeyboard.toggling(.inbox, in: [work, leaf], expanded: []))
        XCTAssertNil(LibraryKeyboard.toggling(.project(leaf.url), in: [work, leaf], expanded: []))

        let opened = LibraryKeyboard.toggling(.project(work.url), in: [work, leaf], expanded: [])
        XCTAssertEqual(opened, [work.url])
        let closed = LibraryKeyboard.toggling(.project(work.url), in: [work, leaf], expanded: [work.url])
        XCTAssertEqual(closed, [])
    }

    func testRightArrowExpandsThenMovesToNotes() {
        let child = FolderSnapshot(url: URL(fileURLWithPath: "/notes/Work/A"), name: "A", parentURL: URL(fileURLWithPath: "/notes/Work"), children: nil)
        let work = FolderSnapshot(url: URL(fileURLWithPath: "/notes/Work"), name: "Work", parentURL: URL(fileURLWithPath: "/notes"), children: [child])

        switch LibraryKeyboard.sidebarRight(.project(work.url), in: [work], expanded: []) {
        case .expand(let next):
            XCTAssertEqual(next, [work.url])
        default:
            XCTFail("expected expand")
        }
        switch LibraryKeyboard.sidebarRight(.project(work.url), in: [work], expanded: [work.url]) {
        case .moveToNotes:
            break
        default:
            XCTFail("expected moveToNotes")
        }
        switch LibraryKeyboard.sidebarRight(.inbox, in: [work], expanded: []) {
        case .moveToNotes:
            break
        default:
            XCTFail("inbox right goes to notes")
        }
    }

    func testLeftArrowCollapsesThenSelectsParent() {
        let child = FolderSnapshot(url: URL(fileURLWithPath: "/notes/Work/A"), name: "A", parentURL: URL(fileURLWithPath: "/notes/Work"), children: nil)
        let work = FolderSnapshot(url: URL(fileURLWithPath: "/notes/Work"), name: "Work", parentURL: URL(fileURLWithPath: "/notes"), children: [child])

        switch LibraryKeyboard.sidebarLeft(.project(work.url), in: [work], expanded: [work.url]) {
        case .collapse(let next):
            XCTAssertEqual(next, [])
        default:
            XCTFail("expected collapse")
        }
        switch LibraryKeyboard.sidebarLeft(.project(child.url), in: [work], expanded: [work.url]) {
        case .select(let item):
            XCTAssertEqual(item, .project(work.url))
        default:
            XCTFail("expected parent")
        }
    }

    func testTypingInNoteListStartsSearch() {
        XCTAssertEqual(
            LibraryKeyboard.searchInsertion(characters: "p", command: false, control: false, option: false),
            "p")
        XCTAssertEqual(
            LibraryKeyboard.searchInsertion(characters: "P", command: false, control: false, option: false),
            "P")
        XCTAssertEqual(
            LibraryKeyboard.searchInsertion(characters: "8", command: false, control: false, option: false),
            "8")
        XCTAssertEqual(
            LibraryKeyboard.searchInsertion(characters: "#", command: false, control: false, option: false),
            "#")
        XCTAssertEqual(
            LibraryKeyboard.searchInsertion(characters: " ", command: false, control: false, option: false),
            " ")
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "f", command: true, control: false, option: false))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "a", command: true, control: false, option: false))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "a", command: false, control: true, option: false))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "e", command: false, control: false, option: true))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "\r", command: false, control: false, option: false))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "\u{1B}", command: false, control: false, option: false))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "\u{7F}", command: false, control: false, option: false))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "\t", command: false, control: false, option: false))
        XCTAssertNil(LibraryKeyboard.searchInsertion(characters: "", command: false, control: false, option: false))
    }

    func testSidebarItemTokenRoundTrip() {
        let root = URL(fileURLWithPath: "/notes")
        let nested = root.appendingPathComponent("Work", isDirectory: true)
        XCTAssertEqual(LibraryModel.SidebarItem.from(token: "inbox", root: root), .inbox)
        XCTAssertEqual(
            LibraryModel.SidebarItem.project(nested).token(relativeTo: root),
            "project:Work"
        )
        XCTAssertEqual(
            LibraryModel.SidebarItem.from(token: "project:Work", root: root),
            .project(nested)
        )
        XCTAssertEqual(LibraryModel.SidebarItem.from(token: "tag:iso", root: root), .tag("iso"))
    }
}
