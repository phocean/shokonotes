import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Shokonotes

/// Favourites drop is a different target from the folder tree: a folder over
/// Favourites is a shortcut, never `moveFolder`; a favourite over the tree is
/// refused. `SidebarOutlineDrop.plan` is not asked for those cases.
final class SidebarFavouritesDropTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-fav-drop-\(UUID().uuidString)", isDirectory: true)
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

    private func route(
        _ kind: SidebarDragKind,
        _ target: SidebarDropTarget,
        favourites: [Favourite] = []
    ) -> SidebarRoutedPlan {
        SidebarFavouritesDrop.route(kind: kind, target: target, favourites: favourites, root: root)
    }

    // MARK: - Two targets, two meanings

    func testFolderOverFavouritesIsFavouriteNotMove() throws {
        let work = try folder("Work")
        let plan = route(.folder(work), .favourites(.header))
        XCTAssertEqual(plan, .favourite(.add(.folder("Work"))))
        if case .move = plan {
            XCTFail("folder-over-favourites must not be a tree move")
        }
    }

    func testFolderOverTreeIsStillMove() throws {
        let work = try folder("Work")
        let personal = try folder("Personal")
        let plan = route(.folder(personal), .tree(inside(work)))
        XCTAssertEqual(plan, .move(.onRow(destination: work)))
        XCTAssertEqual(
            SidebarOutlineDrop.plan(payload: .folder(personal), aim: inside(work)),
            .onRow(destination: work))
    }

    func testFavouriteOverTreeIsRefused() throws {
        let personal = try folder("Personal")
        XCTAssertEqual(
            route(.favourite(.folder("Work")), .tree(inside(personal)), favourites: [.folder("Work")]),
            .refuse)
    }

    func testTagOverTreeIsRefused() throws {
        let work = try folder("Work")
        XCTAssertEqual(route(.tag("dfir"), .tree(inside(work))), .refuse)
    }

    func testTagOverFavouritesHeaderAdds() {
        XCTAssertEqual(
            route(.tag("dfir"), .favourites(.header)),
            .favourite(.add(.tag("dfir"))))
    }

    func testAlreadyFavouriteFolderOverHeaderIsRefused() throws {
        let work = try folder("Work")
        XCTAssertEqual(
            route(.folder(work), .favourites(.header), favourites: [.folder("Work")]),
            .refuse)
    }

    func testFavouriteOverHeaderIsRefused() {
        XCTAssertEqual(
            route(.favourite(.tag("dfir")), .favourites(.header), favourites: [.tag("dfir")]),
            .refuse)
    }

    // MARK: - Rank among favourites

    func testFolderOverFavouritesRankPlaces() throws {
        let work = try folder("Work")
        let plan = route(
            .folder(work),
            .favourites(.rank(index: 1)),
            favourites: [.tag("dfir")])
        XCTAssertEqual(plan, .favourite(.place(.folder("Work"), at: 1)))
        if case .move = plan {
            XCTFail("a rank line among favourites is not a folder move")
        }
    }

    func testFavouriteOverRankReorders() {
        let favourites: [Favourite] = [.tag("alpha"), .folder("Work")]
        XCTAssertEqual(
            route(.favourite(.folder("Work")), .favourites(.rank(index: 0)), favourites: favourites),
            .favourite(.reorder(from: 1, to: 0)))
    }

    func testFavouriteOverOwnRankIsRefused() {
        let favourites: [Favourite] = [.tag("alpha"), .folder("Work")]
        XCTAssertEqual(
            route(.favourite(.tag("alpha")), .favourites(.rank(index: 0)), favourites: favourites),
            .refuse)
        XCTAssertEqual(
            route(.favourite(.tag("alpha")), .favourites(.rank(index: 1)), favourites: favourites),
            .refuse)
    }

    func testFolderAlreadyFavouriteOverRankReorders() throws {
        let work = try folder("Work")
        let favourites: [Favourite] = [.tag("alpha"), .folder("Work")]
        XCTAssertEqual(
            route(.folder(work), .favourites(.rank(index: 0)), favourites: favourites),
            .favourite(.reorder(from: 1, to: 0)))
    }

    // MARK: - Notes

    func testNotesOverFavouriteFolderMoveIntoIt() throws {
        let work = try folder("Work")
        let item = Favourite.folder("Work")
        XCTAssertEqual(
            route(.notes, .favourites(.row(index: 0, item: item))),
            .favourite(.moveNotes(into: work)))
    }

    func testNotesOverFavouritesHeaderAdd() {
        XCTAssertEqual(route(.notes, .favourites(.header)), .favourite(.addNotes))
        if case .refuse = route(.notes, .favourites(.header)) {
            XCTFail("notes over the Favourites header add, they do not refuse")
        }
    }

    func testNotesOverFavouritesRankPlace() {
        XCTAssertEqual(
            route(.notes, .favourites(.rank(index: 2))),
            .favourite(.placeNotes(at: 2)))
        if case .refuse = route(.notes, .favourites(.rank(index: 0))) {
            XCTFail("notes over a Favourites rank place, they do not refuse")
        }
    }

    func testNotesOverFavouriteNotePlaceNotMove() {
        let plan = route(
            .notes,
            .favourites(.row(index: 1, item: .note("Inbox.md"))))
        XCTAssertEqual(plan, .favourite(.placeNotes(at: 1)))
        if case .favourite(.moveNotes) = plan {
            XCTFail("a favourite note has no inside; notes place at that rank")
        }
    }

    func testNotesOverFavouriteTagAreRefused() {
        XCTAssertEqual(
            route(.notes, .favourites(.row(index: 0, item: .tag("dfir")))),
            .refuse)
    }

    func testNotesOverTreeAreUnchanged() throws {
        let work = try folder("Work")
        XCTAssertEqual(
            route(.notes, .tree(inside(work))),
            .move(.onRow(destination: work)))
    }

    // MARK: - Pasteboard

    func testTagReferenceSurvivesARoundTripThroughThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shokonotes-tag-\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setData(
            try JSONEncoder().encode(TagTransfer(name: "dfir")),
            forType: NSPasteboard.PasteboardType(UTType.shokonotesTag.identifier))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertEqual(SidebarFavouritesDrop.tagName(on: pasteboard), "dfir")
        pasteboard.releaseGlobally()
    }

    func testFavouriteReferenceSurvivesARoundTripThroughThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shokonotes-fav-\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setData(
            try JSONEncoder().encode(FavouriteTransfer(item: .tag("incident"))),
            forType: NSPasteboard.PasteboardType(UTType.shokonotesFavourite.identifier))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertEqual(SidebarFavouritesDrop.favourite(on: pasteboard), .tag("incident"))
        pasteboard.releaseGlobally()
    }

    func testTagTypeIsNotTheFolderOrNoteType() {
        XCTAssertNotEqual(UTType.shokonotesTag, UTType.shokonotesFolder)
        XCTAssertNotEqual(UTType.shokonotesTag, UTType.shokonotesNote)
        XCTAssertNotEqual(UTType.shokonotesFavourite, UTType.shokonotesFolder)
        XCTAssertNotEqual(UTType.shokonotesFavourite, UTType.shokonotesNote)
        XCTAssertEqual(UTType.shokonotesTag.identifier, "com.jcbaptiste.shokonotes.tag-reference")
        XCTAssertEqual(
            UTType.shokonotesFavourite.identifier,
            "com.jcbaptiste.shokonotes.favourite-reference")
    }
}
