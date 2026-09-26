import AppKit
import XCTest
@testable import Shokonotes

/// The sidebar's two-dimensional selection, taken apart from `NSOutlineView`:
/// given the rows AppKit proposed, the current collection and tag set, and the
/// modifier, what collection and tags should light up.
final class SidebarTagSelectionTests: XCTestCase {

    private let work = URL(fileURLWithPath: "/notes/Work")

    private func resolve(
        _ proposed: [SidebarTagSelection.Kind],
        collection: LibraryModel.SidebarItem = .inbox,
        tags: Set<String> = [],
        _ modifier: SidebarTagSelection.Modifier = .replace
    ) -> SidebarTagSelection.Resolution {
        SidebarTagSelection.resolve(
            proposed: proposed,
            currentCollection: collection,
            currentTags: tags,
            modifier: modifier
        )
    }

    // MARK: - Plain click / arrow

    func testClickCollectionKeepsTags() {
        let result = resolve(
            [.collection(.all)],
            collection: .inbox,
            tags: ["dfir", "incident"]
        )
        XCTAssertEqual(result.collection, .all)
        XCTAssertEqual(result.tags, ["dfir", "incident"])
    }

    func testClickUnselectedTagReplacesTheTagSet() {
        let result = resolve(
            [.tag("incident")],
            collection: .inbox,
            tags: ["dfir"]
        )
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["incident"])
    }

    func testClickSoleSelectedTagClearsIt() {
        let result = resolve(
            [.tag("dfir")],
            collection: .inbox,
            tags: ["dfir"]
        )
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertTrue(result.tags.isEmpty)
    }

    func testClickOneOfSeveralSelectedTagsIsolatesIt() {
        let result = resolve(
            [.tag("dfir")],
            collection: .inbox,
            tags: ["dfir", "incident"]
        )
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    func testArrowOntoATagReplacesTheTagSet() {
        let result = resolve(
            [.tag("iso")],
            collection: .project(work),
            tags: ["dfir", "incident"]
        )
        XCTAssertEqual(result.collection, .project(work))
        XCTAssertEqual(result.tags, ["iso"])
    }

    // MARK: - Command

    func testCommandClickTogglesATagOn() {
        let result = resolve(
            [.collection(.inbox), .tag("dfir"), .tag("incident")],
            collection: .inbox,
            tags: ["dfir"],
            .toggle
        )
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["dfir", "incident"])
    }

    func testCommandClickTogglesATagOff() {
        let result = resolve(
            [.collection(.inbox), .tag("dfir")],
            collection: .inbox,
            tags: ["dfir", "incident"],
            .toggle
        )
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    func testCommandClickCollectionSwitchesAndKeepsTags() {
        let result = resolve(
            [.collection(.inbox), .collection(.all), .tag("dfir")],
            collection: .inbox,
            tags: ["dfir"],
            .toggle
        )
        XCTAssertEqual(result.collection, .all)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    func testCommandClickCollectionOnlyProposalKeepsTags() {
        let result = resolve(
            [.collection(.all)],
            collection: .inbox,
            tags: ["dfir"],
            .toggle
        )
        XCTAssertEqual(result.collection, .all)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    // MARK: - Two collections / tag-only

    func testTwoCollectionsInProposedLeavesExactlyOne() {
        let kept = resolve(
            [.collection(.all), .collection(.inbox)],
            collection: .inbox,
            tags: ["dfir"],
            .extend
        )
        XCTAssertEqual(kept.collection, .inbox)
        XCTAssertEqual(kept.tags, ["dfir"])

        let last = resolve(
            [.collection(.all), .collection(.inbox)],
            collection: .trash,
            tags: ["dfir"],
            .extend
        )
        XCTAssertEqual(last.collection, .inbox)
        XCTAssertEqual(last.tags, ["dfir"])
    }

    func testTagOnlyProposedReattachesTheCollection() {
        let result = resolve(
            [.tag("dfir"), .tag("incident")],
            collection: .inbox,
            tags: ["iso"],
            .extend
        )
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["dfir", "incident"])
    }

    func testEmptyProposedKeepsTheCurrentSelection() {
        let result = resolve([], collection: .inbox, tags: ["dfir"])
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    // MARK: - Untagged

    func testUntaggedPlusTagProposedHighlightsAllNotesAndTheTag() {
        let result = resolve(
            [.tag("dfir")],
            collection: .untagged,
            tags: []
        )
        XCTAssertEqual(result.collection, .all)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    func testCommandClickTagWhileUntaggedHighlightsAllNotes() {
        let result = resolve(
            [.collection(.untagged), .tag("dfir")],
            collection: .untagged,
            tags: [],
            .toggle
        )
        XCTAssertEqual(result.collection, .all)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    func testClickUntaggedClearsTags() {
        let result = resolve(
            [.collection(.untagged)],
            collection: .inbox,
            tags: ["dfir"]
        )
        XCTAssertEqual(result.collection, .untagged)
        XCTAssertTrue(result.tags.isEmpty)
    }

    // MARK: - Shift among tags

    func testShiftRangeAmongTagsKeepsTheCollection() {
        let result = resolve(
            [.tag("dfir"), .tag("incident"), .tag("iso")],
            collection: .project(work),
            tags: ["dfir"],
            .extend
        )
        XCTAssertEqual(result.collection, .project(work))
        XCTAssertEqual(result.tags, ["dfir", "incident", "iso"])
    }

    func testShiftRangeCrossingCollectionsAndTagsKeepsOneCollection() {
        let result = resolve(
            [.collection(.inbox), .collection(.trash), .tag("dfir")],
            collection: .inbox,
            tags: [],
            .extend
        )
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["dfir"])
    }

    // MARK: - Modifiers

    func testModifierFlags() {
        XCTAssertEqual(SidebarTagSelection.modifier(from: []), .replace)
        XCTAssertEqual(SidebarTagSelection.modifier(from: .command), .toggle)
        XCTAssertEqual(SidebarTagSelection.modifier(from: .shift), .extend)
        XCTAssertEqual(SidebarTagSelection.modifier(from: [.shift, .command]), .extend)
    }

    // MARK: - Favourite note is not a collection

    func testNoteKindIsNotACollection() {
        let url = URL(fileURLWithPath: "/notes/Inbox.md")
        XCTAssertEqual(SidebarTagSelection.Kind.of(.note(url)), .note)
        XCTAssertNil(SidebarTagSelection.Kind.of(.note(url)).collection)
        XCTAssertNil(SidebarTagSelection.Kind.of(.note(url)).tag)
        XCTAssertEqual(SidebarTagSelection.collection(from: .note(url)), .all)
    }

    func testNoteProposalDoesNotSwitchToNote() {
        let url = URL(fileURLWithPath: "/notes/Inbox.md")
        let result = resolve([.note], collection: .inbox, tags: ["dfir"])
        XCTAssertEqual(result.collection, .inbox)
        XCTAssertEqual(result.tags, ["dfir"])
        if case .note = result.collection {
            XCTFail(".note is row identity, never a live sidebarSelection")
        }
    }

    func testLeakedNoteCollectionMapsToAll() {
        let url = URL(fileURLWithPath: "/notes/Inbox.md")
        let kept = resolve([], collection: .note(url), tags: ["dfir"])
        XCTAssertEqual(kept.collection, .all)
        XCTAssertEqual(kept.tags, ["dfir"])

        let proposed = resolve(
            [.collection(.note(url))],
            collection: .inbox,
            tags: []
        )
        XCTAssertEqual(proposed.collection, .all)
        if case .note = proposed.collection {
            XCTFail("a leaked .note collection must not stay .note")
        }
    }
}
