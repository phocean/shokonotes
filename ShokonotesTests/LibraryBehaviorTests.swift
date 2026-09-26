import XCTest
@testable import Shokonotes

/// Product rules of the engine that nothing else pins down: quick capture from
/// the trash, the coalesced watcher path, and the focus / find commands.
@MainActor
final class LibraryBehaviorTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var model: LibraryModel!
    private var openedURLs: [URL] = []
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-behavior-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "shokonotes-behavior-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        openedURLs = []
        model = LibraryModel(settings: AppSettings(defaults: defaults), store: LibraryStore()) {
            [weak self] urls, _ in self?.openedURLs = urls
        }
        model.openRoot(root, skipActivate: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func note(_ name: String, in folder: URL) throws -> NoteRecord {
        try model.store.createNote(
            named: name, in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: name)
        )
    }

    // MARK: - Quick capture preserves the reading context

    func testQuickNoteFromTrashCreatesInInboxWithoutLeavingTrash() throws {
        let doomed = try note("Doomed", in: root)
        try model.store.trash([doomed.url])
        model.reloadEverything()
        model.sidebarSelection = .trash
        model.searchText = "Doo"
        let trashedURL = model.store.snapshots().first { $0.isTrashed }?.url
        model.selectedNoteIDs = Set([trashedURL].compactMap { $0 })
        XCTAssertTrue(model.isViewingTrash)
        let selectionBefore = model.selectedNoteIDs

        model.createQuickNote()

        // The view must not jump to Inbox to show the new note.
        XCTAssertEqual(model.sidebarSelection, .trash)
        XCTAssertTrue(model.isViewingTrash)
        XCTAssertEqual(model.searchText, "Doo")
        XCTAssertEqual(model.selectedNoteIDs, selectionBefore)
        XCTAssertTrue(model.notes.allSatisfy(\.isTrashed))

        // But the note really was created in the Inbox, and opened.
        let created = model.store.snapshots().filter { !$0.isTrashed }
        XCTAssertEqual(created.count, 1)
        let inbox = try XCTUnwrap(created.first)
        XCTAssertEqual(inbox.folderURL.standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(fm.fileExists(atPath: inbox.url.path))
        XCTAssertEqual(openedURLs, [inbox.url])
    }

    func testOrdinaryNewNoteFromTrashStillSwitchesToInbox() throws {
        model.sidebarSelection = .trash
        model.createNote()
        XCTAssertEqual(model.sidebarSelection, .inbox)
        XCTAssertEqual(model.notes.count, 1)
    }

    // MARK: - Coalesced refresh

    /// Counting reloads needs a model with no library open: with a root, the
    /// real FSEvents watcher schedules refreshes of its own and the count
    /// stops being the test's to control.
    private func unwatchedModel() -> LibraryModel {
        let suite = "shokonotes-debounce-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        return LibraryModel(settings: AppSettings(defaults: store), store: LibraryStore()) { _, _ in }
    }

    func testBurstOfEventsProducesExactlyOneReloadAfterTheDelay() async throws {
        let model = unwatchedModel()
        XCTAssertEqual(model.refreshDebounce, 0.4, "Production debounce must stay 0.4 s")
        model.refreshDebounce = 0.05

        // Reloads, not publishes: an unchanged list is published once and then
        // guarded, so a publish counter can no longer tell six reloads from one.
        let before = model.reloadCount

        for _ in 0..<6 { model.scheduleRefresh() }
        XCTAssertEqual(model.reloadCount - before, 0, "Nothing must reload before the delay elapses")

        try await settle(0.3)

        XCTAssertEqual(model.reloadCount - before, 1, "Six coalesced events must yield one reload")
    }

    func testEachSeparateBurstReloadsOnce() async throws {
        let model = unwatchedModel()
        model.refreshDebounce = 0.05
        let before = model.reloadCount

        model.scheduleRefresh()
        model.scheduleRefresh()
        try await settle(0.3)
        XCTAssertEqual(model.reloadCount - before, 1)

        model.scheduleRefresh()
        try await settle(0.3)
        XCTAssertEqual(model.reloadCount - before, 2, "A later event must still schedule its own reload")
    }

    /// The coalesced path, end to end: a file written behind the app's back is
    /// absent until the delay elapses, then present — no direct `reloadFromDisk`.
    func testCoalescedRefreshPicksUpAnExternalFileAfterTheDelay() async throws {
        model.refreshDebounce = 0.05
        try "---\ntitle: Outside\n---\n".write(
            to: root.appendingPathComponent("Outside.md"), atomically: true, encoding: .utf8
        )

        for _ in 0..<6 { model.scheduleRefresh() }
        XCTAssertTrue(model.notes.isEmpty, "No reload before the delay elapses")

        try await settle(0.3)

        XCTAssertTrue(model.notes.contains { $0.title == "Outside" }, "The reload must have happened")
    }

    /// Lets the main queue run the pending work item without a blocking sleep.
    private func settle(_ seconds: TimeInterval) async throws {
        let done = expectation(description: "debounce elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        await fulfillment(of: [done], timeout: seconds + 2)
    }

    // MARK: - Search debounce

    func testTypingDoesNotRecomputeTheListBeforeTheDelay() async throws {
        XCTAssertEqual(model.searchDebounce, 0.15, "Production search debounce must stay 150 ms")
        try note("Pangolin", in: root)
        try note("Zebra", in: root)
        model.reloadEverything()
        XCTAssertEqual(model.notes.count, 2)
        model.searchDebounce = 0.05

        for text in ["P", "Pa", "Pan", "Pang"] { model.searchText = text }

        // The field shows what was typed at once; only the list waits.
        XCTAssertEqual(model.searchText, "Pang")
        XCTAssertEqual(model.notes.count, 2, "No recompute before the delay elapses")

        try await settle(0.3)

        XCTAssertEqual(model.notes.map(\.title), ["Pangolin"])
    }

    func testABurstOfKeystrokesRecomputesOnce() async throws {
        try note("Pangolin", in: root)
        model.reloadEverything()
        model.searchDebounce = 0.05
        let before = model.reloadCount

        for text in ["P", "Pa", "Pan", "Pang", "Pango"] { model.searchText = text }
        try await settle(0.3)

        XCTAssertEqual(model.reloadCount - before, 1, "Five keystrokes must recompute the list once")
    }

    func testClearingTheSearchIsImmediate() async throws {
        try note("Pangolin", in: root)
        try note("Zebra", in: root)
        model.reloadEverything()
        model.searchDebounce = 5  // Long enough that a debounced clear would be visible.
        model.searchText = "Pangolin"
        try await settle(0.05)
        XCTAssertEqual(model.notes.count, 2, "Still the unfiltered list: the query is pending")

        model.searchText = ""

        XCTAssertEqual(model.notes.count, 2)
        XCTAssertTrue(model.notes.contains { $0.title == "Zebra" }, "Escape must land at once")
    }

    func testClearSearchCancelsAPendingQuery() async throws {
        try note("Pangolin", in: root)
        try note("Zebra", in: root)
        model.reloadEverything()
        model.searchDebounce = 0.05
        model.searchText = "Pangolin"

        model.clearSearch()

        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.notes.count, 2)

        // The cancelled keystroke must not fire later and filter the list again.
        try await settle(0.3)
        XCTAssertEqual(model.notes.count, 2)
    }

    func testSettingTheSameTextTwiceDoesNotRecompute() async throws {
        try note("Pangolin", in: root)
        model.reloadEverything()
        model.searchDebounce = 0.05
        let before = model.reloadCount

        model.searchText = "Pan"
        model.searchText = "Pan"
        try await settle(0.3)
        XCTAssertEqual(model.reloadCount - before, 1)
    }

    // MARK: - Focus and find-in-note commands

    func testFocusNotesListSelectsFirstNoteWhenNothingIsSelected() throws {
        try note("Alpha", in: root)
        try note("Beta", in: root)
        model.reloadEverything()
        model.selectedNoteIDs = []

        model.focusNotesList()

        XCTAssertEqual(model.selectedNoteIDs, Set([model.notes.first?.url].compactMap { $0 }))
        XCTAssertEqual(model.focusRequest, .notes)
    }

    func testFocusNotesListKeepsAnExistingSelection() throws {
        try note("Alpha", in: root)
        let beta = try note("Beta", in: root)
        model.reloadEverything()
        model.selectedNoteIDs = [beta.url]

        model.focusNotesList()

        XCTAssertEqual(model.selectedNoteIDs, [beta.url])
        XCTAssertEqual(model.focusRequest, .notes)
    }

    func testFocusNotesListOnAnEmptyLibraryLeavesTheSelectionEmpty() {
        model.selectedNoteIDs = []
        model.focusNotesList()
        XCTAssertTrue(model.selectedNoteIDs.isEmpty)
        XCTAssertEqual(model.focusRequest, .notes)
    }

    func testPreviewFindOpensOnTheLibrarySearch() {
        model.searchText = "kanji"

        model.showPreviewFind()

        XCTAssertTrue(model.previewFindVisible)
        XCTAssertEqual(model.previewFindQuery, "kanji")
        XCTAssertEqual(model.previewFindFocus, 1)
    }

    func testPreviewFindDoesNotOverwriteAQueryAlreadyTyped() {
        model.searchText = "kanji"
        model.previewFindQuery = "radical"

        model.showPreviewFind()

        XCTAssertEqual(model.previewFindQuery, "radical")
        XCTAssertEqual(model.previewFindFocus, 1)

        // Reopening puts the caret back without touching the query.
        model.showPreviewFind()
        XCTAssertEqual(model.previewFindQuery, "radical")
        XCTAssertEqual(model.previewFindFocus, 2)
    }

    func testHidePreviewFindClearsTheQuery() {
        model.searchText = "kanji"
        model.showPreviewFind()

        model.hidePreviewFind()

        XCTAssertFalse(model.previewFindVisible)
        XCTAssertEqual(model.previewFindQuery, "")
        XCTAssertEqual(model.searchText, "kanji", "The library search is a separate field")

        // Next opening seeds from the library search again.
        model.showPreviewFind()
        XCTAssertEqual(model.previewFindQuery, "kanji")
    }

    func testPreviewFindWithAnEmptyLibrarySearchOpensEmpty() {
        model.searchText = ""
        model.showPreviewFind()
        XCTAssertTrue(model.previewFindVisible)
        XCTAssertEqual(model.previewFindQuery, "")
    }
}
