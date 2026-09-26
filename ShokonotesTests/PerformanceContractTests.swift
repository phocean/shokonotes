import XCTest
@testable import Shokonotes

/// Wave 1 of the performance plan. Every optimization here must be invisible
/// at use; these tests pin the behavior that must not move.
@MainActor
final class PerformanceContractTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-perf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ text: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name + ".md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Search stays strictly equivalent

    private func snapshot(_ name: String, _ text: String) throws -> NoteSnapshot {
        let url = try write(name, text)
        store.rescan()
        return try XCTUnwrap(store.snapshot(for: url))
    }

    func testSearchIgnoresDiacriticsAndCaseBothWays() throws {
        let note = try snapshot(
            "Voyage",
            "---\ntitle: Séjour à Tôkyô\ntags: [Été]\n---\nLe café était déjà PRÊT.\n"
        )
        // Unaccented query finds accented text, and the reverse.
        XCTAssertTrue(note.matches(terms: ["sejour"]))
        XCTAssertTrue(note.matches(terms: ["SÉJOUR"]))
        XCTAssertTrue(note.matches(terms: ["cafe"]))
        XCTAssertTrue(note.matches(terms: ["CAFÉ"]))
        XCTAssertTrue(note.matches(terms: ["prêt"]))
        XCTAssertTrue(note.matches(terms: ["PRET"]))
        XCTAssertTrue(note.matches(terms: ["tokyo"]))
        XCTAssertFalse(note.matches(terms: ["kyoto"]))
    }

    func testSearchMatchesTitleTagsAndBodyWithSeveralTerms() throws {
        let note = try snapshot(
            "Mixed",
            "---\ntitle: Réunion\ntags: [Travail, urgent]\n---\nOrdre du jour: budget.\n"
        )
        XCTAssertTrue(note.matches(terms: ["reunion", "TRAVAIL", "Budget"]))
        XCTAssertTrue(note.matches(terms: ["urgent"]))
        XCTAssertFalse(note.matches(terms: ["reunion", "absent"]), "All terms must match")
        XCTAssertTrue(note.matches(terms: []), "An empty query matches everything")
    }

    func testPrefoldedTermsGiveTheSameAnswerAsRawTerms() throws {
        let note = try snapshot("Folding", "---\ntitle: Élan\n---\nNaïve façade\n")
        for raw in ["ELAN", "élan", "naive", "FAÇADE", "facade", "zzz"] {
            XCTAssertEqual(
                note.matches(terms: [raw]),
                note.matches(foldedTerms: [NoteSnapshot.fold(raw)]),
                "Folding a term up front must not change the answer for \(raw)"
            )
        }
    }

    func testSearchStillFindsTheBodyOfANoteNeverOpened() throws {
        let note = try snapshot("Hidden", "---\ntitle: Plain\n---\nSecret pangolin inside.\n")
        XCTAssertTrue(note.matches(terms: ["pangolin"]))
    }

    // MARK: - Raw body

    func testRawBodyIsTheMarkdownWithoutFrontMatter() throws {
        let note = try snapshot("Raw", "---\ntitle: Doc\ntags: [a]\n---\n# Heading\n\nText.\n")
        XCTAssertEqual(note.rawBody, "# Heading\n\nText.\n")
        XCTAssertFalse(note.rawBody.contains("title:"), "Front matter must not reach the preview")
        // The searchable text is separate, folded, and still covers the title.
        XCTAssertTrue(note.searchHaystack.contains("doc"))
        XCTAssertTrue(note.searchHaystack.contains("heading"))
    }

    func testRawBodyMatchesTheFileForANoteWithoutFrontMatter() throws {
        let text = "Just a plain note\nwith two lines\n"
        let note = try snapshot("Plain", text)
        XCTAssertEqual(note.rawBody, text)
    }

    func testPrecomputedFileStemFlagMatchesTheOldRule() throws {
        let matching = try snapshot("Agenda", "---\ntitle: Agenda\n---\nBody\n")
        XCTAssertFalse(matching.fileStemDiffersFromTitle)

        let differing = try snapshot("note-1", "---\ntitle: Quite Another Name\n---\nBody\n")
        XCTAssertTrue(differing.fileStemDiffersFromTitle)
    }

    // MARK: - Memoized sidebar counts

    func testCountsFollowEveryMutation() throws {
        XCTAssertEqual(store.counts(), LibraryStore.SidebarCounts(trashed: 0, inbox: 0, untagged: 0))

        let a = try store.createNote(
            named: "A", in: root, extension: "md", body: NoteActions.newNoteBody(named: "A")
        )
        XCTAssertEqual(store.counts().inbox, 1)
        XCTAssertEqual(store.counts().untagged, 1)
        XCTAssertEqual(store.counts().trashed, 0)

        let folder = try store.createFolder(named: "Work", parent: root)
        try store.move([a.url], to: folder)
        XCTAssertEqual(store.counts().inbox, 0, "A moved note leaves the Inbox count")
        XCTAssertEqual(store.counts().untagged, 1)

        let moved = try XCTUnwrap(store.notes.first)
        try store.trash([moved.url])
        XCTAssertEqual(store.counts().trashed, 1)
        XCTAssertEqual(store.counts().untagged, 0)

        let trashed = try XCTUnwrap(store.notes.first)
        try store.restore([trashed.url], fallback: root)
        XCTAssertEqual(store.counts().trashed, 0)
        XCTAssertEqual(store.counts().untagged, 1)

        store.applyTag("done", add: true, to: store.notes.map(\.url))
        XCTAssertEqual(store.counts().untagged, 0, "Tagging clears the untagged count")

        try store.removeForever(store.notes.map(\.url))
        XCTAssertEqual(store.counts(), LibraryStore.SidebarCounts(trashed: 0, inbox: 0, untagged: 0))
    }

    func testCountsRefreshAfterAnExternalChangeAndRescan() throws {
        try write("Outside", "---\ntitle: Outside\n---\nbody\n")
        store.rescan()
        XCTAssertEqual(store.counts().inbox, 1)

        try fm.removeItem(at: root.appendingPathComponent("Outside.md"))
        store.rescan()
        XCTAssertEqual(store.counts().inbox, 0)
    }

    // MARK: - Batched pin writes

    func testPinningManyNotesCostsOneWrite() throws {
        var urls: [URL] = []
        for index in 1...5 {
            urls.append(try store.createNote(
                named: "N\(index)", in: root, extension: "md",
                body: NoteActions.newNoteBody(named: "N\(index)")
            ).url)
        }
        let before = store.pinWriteCount

        try store.togglePins(urls)

        XCTAssertEqual(store.pinWriteCount - before, 1, "Five notes must cost one pins.json write")
        XCTAssertTrue(store.snapshots().allSatisfy(\.isPinned))

        // And the pins really are on disk.
        store.rescan()
        XCTAssertTrue(store.snapshots().allSatisfy(\.isPinned))

        try store.togglePins(urls)
        XCTAssertTrue(store.snapshots().allSatisfy { !$0.isPinned })
    }

    // MARK: - Sidecar writes are one per operation, never one per note

    private func createNotes(_ count: Int, prefix: String) throws -> [URL] {
        try (1...count).map { index in
            let name = "\(prefix)\(index)"
            return try store.createNote(
                named: name, in: root, extension: "md",
                body: NoteActions.newNoteBody(named: name)
            ).url
        }
    }

    func testTrashingManyNotesCostsWhatTrashingOneCosts() throws {
        var origins = store.originWriteCount
        var pins = store.pinWriteCount
        try store.trash(try createNotes(1, prefix: "Solo"))
        let oneOrigins = store.originWriteCount - origins
        let onePins = store.pinWriteCount - pins
        XCTAssertEqual(oneOrigins, 1, "One note: one origins.json write")
        XCTAssertEqual(onePins, 1, "One note: one pins.json write")

        let many = try createNotes(50, prefix: "Crowd")
        origins = store.originWriteCount
        pins = store.pinWriteCount
        try store.trash(many)
        XCTAssertEqual(
            store.originWriteCount - origins, oneOrigins,
            "Fifty notes must cost exactly what one note costs"
        )
        XCTAssertEqual(store.pinWriteCount - pins, onePins)

        // One write, but the whole batch is in it: the sidecar read back from
        // disk still knows every note's origin.
        store.rescan()
        XCTAssertEqual(store.snapshots().filter(\.isTrashed).count, 51)
        let trashed = store.notes.map(\.url)
        try store.restore(trashed, fallback: root)
        XCTAssertTrue(store.snapshots().allSatisfy { !$0.isTrashed })
    }

    func testRestoringAndEmptyingManyNotesEachCostOneWrite() throws {
        let urls = try createNotes(40, prefix: "Batch")
        try store.togglePins(urls)
        try store.trash(urls)
        store.rescan()
        let trashed = store.snapshots().filter(\.isTrashed).map(\.url)
        XCTAssertEqual(trashed.count, 40)

        var origins = store.originWriteCount
        var pins = store.pinWriteCount
        try store.restore(trashed, fallback: root)
        XCTAssertEqual(store.originWriteCount - origins, 1, "Restoring forty notes: one origins.json write")
        XCTAssertEqual(store.pinWriteCount - pins, 1)
        XCTAssertTrue(store.snapshots().allSatisfy { !$0.isTrashed && $0.isPinned })

        try store.trash(store.notes.map(\.url))
        let doomed = store.notes.map(\.url)
        origins = store.originWriteCount
        pins = store.pinWriteCount
        let symbols = store.folderSymbolWriteCount
        try store.removeForever(doomed)
        XCTAssertEqual(store.originWriteCount - origins, 1, "Emptying the Trash: one origins.json write")
        XCTAssertEqual(store.pinWriteCount - pins, 1)
        XCTAssertEqual(store.folderSymbolWriteCount, symbols, "No symbol anywhere: nothing to collect")
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testAFailingBatchStillCostsOneWriteAndKeepsDiskConsistent() throws {
        let folder = try store.createFolder(named: "Kept", parent: root)
        let first = try store.createNote(
            named: "Survivor", in: folder, extension: "md",
            body: NoteActions.newNoteBody(named: "Survivor")
        )
        let others = try createNotes(20, prefix: "Doomed")
        // A note whose file vanished behind the store's back: `trash` throws
        // partway through the batch.
        let ghost = try store.createNote(
            named: "Ghost", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Ghost")
        )
        try fm.removeItem(at: ghost.url)

        let origins = store.originWriteCount
        let pins = store.pinWriteCount
        XCTAssertThrowsError(try store.trash([first.url] + others + [ghost.url]))
        XCTAssertEqual(store.originWriteCount - origins, 1, "The error path writes once, not once per note")
        XCTAssertEqual(store.pinWriteCount - pins, 1)

        // And that single write is consistent with the files that really moved.
        store.rescan()
        let trashed = try XCTUnwrap(store.notes.first { $0.url.lastPathComponent == "Survivor.md" })
        XCTAssertTrue(trashed.isTrashed)
        try store.restore([trashed.url], fallback: root)
        store.rescan()
        let restored = try XCTUnwrap(store.notes.first { $0.url.lastPathComponent == "Survivor.md" })
        XCTAssertEqual(restored.folderURL.lastPathComponent, "Kept", "The origin survived the failure")
    }

    func testTogglingUnknownURLsWritesNothing() throws {
        let before = store.pinWriteCount
        try store.togglePins([root.appendingPathComponent("Ghost.md")])
        XCTAssertEqual(store.pinWriteCount, before, "Nothing changed, nothing written")
    }

    // MARK: - Enumeration

    func testTrashNotesStillReachRecords() throws {
        let note = try store.createNote(
            named: "Doomed", in: root, extension: "md",
            body: NoteActions.newNoteBody(named: "Doomed")
        )
        try store.trash([note.url])
        store.rescan()
        XCTAssertEqual(store.snapshots().filter(\.isTrashed).count, 1)
        XCTAssertEqual(store.counts().trashed, 1)
    }

    func testSidecarFolderIsStillSkipped() throws {
        let sidecar = LibraryPaths.sidecarURL(root: root)
        try fm.createDirectory(at: sidecar, withIntermediateDirectories: true)
        try write("notes", "hidden", in: sidecar)
        store.rescan()
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.folders().isEmpty)
    }

    func testNotesInNestedFoldersAreStillFound() throws {
        let folder = try store.createFolder(named: "Deep", parent: root)
        let inner = try store.createFolder(named: "Deeper", parent: folder)
        try write("Buried", "---\ntitle: Buried\n---\nfound me\n", in: inner)
        store.rescan()
        XCTAssertTrue(store.snapshots().contains { $0.title == "Buried" })
    }
}

/// Caches on the preview payload. The trap is a key that forgets the
/// appearance or the style and freezes the wrong sheet in.
@MainActor
final class PreviewCacheTests: XCTestCase {
    override func setUp() async throws {
        PreviewAssetCache.shared.removeAll()
    }

    func testSyntaxCSSIsStableAndDistinguishesLightFromDark() {
        let light = PreviewCodeTheme.github.css(isDark: false)
        let dark = PreviewCodeTheme.github.css(isDark: true)
        XCTAssertEqual(light, PreviewCodeTheme.github.css(isDark: false), "Second read must be identical")
        XCTAssertEqual(dark, PreviewCodeTheme.github.css(isDark: true))
        if !light.isEmpty || !dark.isEmpty {
            XCTAssertNotEqual(light, dark, "The cache key must carry the appearance")
        }
        XCTAssertNotEqual(
            PreviewCodeTheme.solarized.css(isDark: false),
            PreviewCodeTheme.github.css(isDark: false) + "x",
            "Each theme keeps its own entry"
        )
    }

    func testHighlightScriptIsIdenticalOnEveryRead() {
        let first = PreviewCodeTheme.highlightScript()
        let second = PreviewCodeTheme.highlightScript()
        XCTAssertEqual(first, second)
    }

    func testSheetCacheKeyDiscriminatesEveryStyleField() {
        let base = PreviewCSS.sheet(PreviewStyle())
        XCTAssertEqual(base, PreviewCSS.sheet(PreviewStyle()), "Same style, same sheet")
        XCTAssertNotEqual(base, PreviewCSS.sheet(PreviewStyle(fontSize: 21)))
        XCTAssertNotEqual(base, PreviewCSS.sheet(PreviewStyle(maxWidthEm: 60)))
        XCTAssertNotEqual(base, PreviewCSS.sheet(PreviewStyle(font: .serif)))
        XCTAssertNotEqual(base, PreviewCSS.sheet(PreviewStyle(lineHeight: .compact)))
        XCTAssertNotEqual(base, PreviewCSS.sheet(PreviewStyle(images: .hidden)))
        XCTAssertNotEqual(base, PreviewCSS.sheet(PreviewStyle(theme: .paper)))
    }

    func testResolveHandlesManyImagesInOrder() {
        let base = URL(fileURLWithPath: "/notes/folder/")
        let html = """
        <img src="i/one.png"><img src='i/two.png'>
        <a href="../other.md">x</a><img src="https://example.com/keep.png">
        <a href="#anchor">a</a><img src="data:image/png;base64,AAA">
        """
        let out = MarkdownRenderer.resolve(html, base: base, target: .screen).html
        XCTAssertTrue(out.contains("src=\"file:///notes/folder/i/one.png\""))
        XCTAssertTrue(out.contains("src='file:///notes/folder/i/two.png'"), "Single quotes are preserved")
        XCTAssertTrue(out.contains("href=\"file:///notes/other.md\""))
        XCTAssertTrue(out.contains("src=\"https://example.com/keep.png\""), "Absolute URLs are untouched")
        XCTAssertTrue(out.contains("href=\"#anchor\""))
        XCTAssertTrue(out.contains("src=\"data:image/png;base64,AAA\""))
        XCTAssertTrue(out.contains("<a href=\"file:///notes/other.md\">x</a>"), "Surrounding markup survives")
    }

    func testResolveLeavesPlainHTMLAlone() {
        let html = "<p>No links here</p>"
        XCTAssertEqual(
            MarkdownRenderer.resolve(
                html,
                base: URL(fileURLWithPath: "/notes/"),
                target: .screen
            ).html,
            html
        )
    }
}
