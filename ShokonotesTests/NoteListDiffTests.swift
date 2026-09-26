import XCTest
import Combine
@testable import Shokonotes

/// The published `notes` array is what the note list's `ForEach` diffs. A pin
/// or an unpin must move one element and change nothing else: same count, same
/// set of identities, no identity twice. A blank row in the window is what a
/// broken identity set looks like on screen, and this is the part of it a unit
/// test can actually hold.
@MainActor
final class NoteListDiffTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var model: LibraryModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-listdiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "shokonotes-listdiff-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        model = LibraryModel(settings: AppSettings(defaults: defaults), store: LibraryStore()) { _, _ in }
        model.openRoot(root, skipActivate: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeNotes(_ names: [String]) throws {
        for name in names {
            _ = try model.store.createNote(
                named: name, in: root, extension: "md",
                body: NoteActions.newNoteBody(named: name)
            )
        }
        model.reloadEverything()
    }

    func testPinAndUnpinKeepTheIdentitySetIntact() throws {
        try makeNotes(["Aerospace", "Beryl", "Cobalt", "Dune", "Ember"])
        let before = Set(model.notes.map(\.url))
        XCTAssertEqual(model.notes.count, 5)

        guard let target = model.notes.first(where: { $0.title == "Cobalt" }) else {
            return XCTFail("missing fixture note")
        }

        model.togglePin([target])
        XCTAssertEqual(model.notes.count, 5, "pinning must move a row, never add one")
        XCTAssertEqual(Set(model.notes.map(\.url)).count, 5, "no identity twice")
        XCTAssertEqual(Set(model.notes.map(\.url)), before)
        XCTAssertEqual(model.notes.first?.title, "Cobalt")
        XCTAssertTrue(model.notes.allSatisfy { !$0.title.isEmpty }, "no row renders empty")

        model.togglePin([model.notes[0]])
        XCTAssertEqual(model.notes.count, 5, "unpinning must move a row, never leave one behind")
        XCTAssertEqual(Set(model.notes.map(\.url)).count, 5, "no identity twice")
        XCTAssertEqual(Set(model.notes.map(\.url)), before)
        XCTAssertTrue(model.notes.allSatisfy { !$0.title.isEmpty }, "no row renders empty")
        XCTAssertFalse(model.notes.contains(where: \.isPinned))
    }

    /// `togglePin` writes `pins.json` inside the library, which the watcher sees,
    /// so a full rescan lands on top of the direct update. The array the list
    /// diffs against after that rescan must be the same array.
    func testRescanAfterUnpinPublishesTheSameArray() throws {
        try makeNotes(["Aerospace", "Beryl", "Cobalt", "Dune", "Ember"])
        guard let target = model.notes.first(where: { $0.title == "Cobalt" }) else {
            return XCTFail("missing fixture note")
        }

        model.togglePin([target])
        let afterPin = model.notes.map(\.url)
        model.store.rescan()
        model.reloadEverything(preservingSelection: true)
        XCTAssertEqual(model.notes.map(\.url), afterPin, "a rescan must not reorder or add a row")

        model.togglePin([model.notes[0]])
        let afterUnpin = model.notes.map(\.url)
        XCTAssertEqual(afterUnpin.count, 5)
        model.store.rescan()
        model.reloadEverything(preservingSelection: true)
        XCTAssertEqual(model.notes.map(\.url), afterUnpin, "a rescan must not reorder or add a row")
        XCTAssertEqual(Set(model.notes.map(\.url)).count, 5)
    }
}

// MARK: - Redundant publishes

/// `@Published` fires on assignment, not on change. A reload that recomputes
/// the same values and assigns them anyway republishes the whole list, and the
/// blank row he photographed is what that costs when the republish lands on an
/// `NSTableView` in the middle of a row-move animation. These count emissions:
/// an unchanged library must emit nothing at all.
extension NoteListDiffTests {
    private struct Counters {
        var notes = 0
        var selection = 0
        var folders = 0
        var tags = 0
        var tagCounts = 0
        var favourites = 0
    }

    /// Subscribes to every list-bearing publisher, dropping the value Combine
    /// replays on subscription, and returns the live counts.
    private func countEmissions(_ body: () -> Void) -> Counters {
        var bag: [AnyCancellable] = []
        let box = CounterBox()
        bag.append(model.$notes.dropFirst().sink { _ in box.notes += 1 })
        bag.append(model.$selectedNoteIDs.dropFirst().sink { _ in box.selection += 1 })
        bag.append(model.$folders.dropFirst().sink { _ in box.folders += 1 })
        bag.append(model.$tags.dropFirst().sink { _ in box.tags += 1 })
        bag.append(model.$tagCounts.dropFirst().sink { _ in box.tagCounts += 1 })
        bag.append(model.$favourites.dropFirst().sink { _ in box.favourites += 1 })
        body()
        bag.forEach { $0.cancel() }
        return Counters(
            notes: box.notes, selection: box.selection, folders: box.folders,
            tags: box.tags, tagCounts: box.tagCounts, favourites: box.favourites
        )
    }

    func testReloadOfAnUnchangedLibraryPublishesNothing() throws {
        try makeNotes(["Aerospace", "Beryl", "Cobalt", "Dune", "Ember"])
        XCTAssertFalse(model.selectedNoteIDs.isEmpty, "the fixture selects the first note")

        let counters = countEmissions {
            model.store.rescan()
            model.reloadEverything()
        }
        XCTAssertEqual(counters.notes, 0, "an unchanged list must not republish")
        XCTAssertEqual(counters.selection, 0, "an unchanged selection must not republish")
        XCTAssertEqual(counters.folders, 0, "unchanged folders must not republish")
        XCTAssertEqual(counters.tags, 0, "unchanged tags must not republish")
        XCTAssertEqual(counters.tagCounts, 0, "unchanged tag counts must not republish")
        XCTAssertEqual(counters.favourites, 0, "unchanged favourites must not republish")
    }

    /// His repro: pin, then unpin, with the note selected throughout. The list
    /// itself genuinely changes once per toggle. Nothing else may fire, and the
    /// watcher's rescan on `pins.json` afterwards may fire nothing at all.
    func testPinAndUnpinPublishTheListOnceAndNothingElse() throws {
        try makeNotes(["Aerospace", "Beryl", "Cobalt", "Dune", "Ember"])
        guard let target = model.notes.first(where: { $0.title == "Cobalt" }) else {
            return XCTFail("missing fixture note")
        }
        model.selectedNoteIDs = [target.url]

        let pin = countEmissions { model.togglePin([target]) }
        XCTAssertEqual(pin.notes, 1, "pinning reorders the list exactly once")
        XCTAssertEqual(pin.selection, 0, "the selected note stayed visible: no selection change")

        let echo = countEmissions {
            model.store.rescan()
            model.reloadEverything(preservingSelection: true)
        }
        XCTAssertEqual(echo.notes, 0, "the watcher's echo on pins.json must publish nothing")
        XCTAssertEqual(echo.folders, 0)
        XCTAssertEqual(echo.tags, 0)
        XCTAssertEqual(echo.tagCounts, 0)

        let unpin = countEmissions { model.togglePin([model.notes[0]]) }
        XCTAssertEqual(unpin.notes, 1, "unpinning reorders the list exactly once")
        XCTAssertEqual(unpin.selection, 0, "the selected note stayed visible: no selection change")

        let echo2 = countEmissions {
            model.store.rescan()
            model.reloadEverything(preservingSelection: true)
        }
        XCTAssertEqual(echo2.notes, 0, "the watcher's echo on pins.json must publish nothing")
    }
}

/// A class so the sinks mutate one instance rather than capturing a `var`.
private final class CounterBox {
    var notes = 0
    var selection = 0
    var folders = 0
    var tags = 0
    var tagCounts = 0
    var favourites = 0
}
