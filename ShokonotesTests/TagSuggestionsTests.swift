import XCTest
@testable import Shokonotes

/// `TagSuggestions` and `TagHygiene` are pure: every test here builds its
/// library in memory. No temporary folder, no rescan, no disk.
final class TagSuggestionsTests: XCTestCase {
    // MARK: - Builders

    private func note(
        _ name: String,
        tags: [String] = [],
        body: String = "",
        folder: String = "",
        modified: Date = Date(timeIntervalSince1970: 0),
        trashed: Bool = false
    ) -> NoteSnapshot {
        let root = URL(fileURLWithPath: "/library", isDirectory: true)
        let folderURL = folder.isEmpty
            ? root
            : root.appendingPathComponent(folder, isDirectory: true)
        let url = folderURL.appendingPathComponent(name + ".md")
        return NoteSnapshot(
            url: url,
            title: name,
            excerpt: "",
            tags: tags,
            modifiedAt: modified,
            createdAt: modified,
            isPinned: false,
            folderURL: folderURL,
            relativePath: folder.isEmpty ? name + ".md" : folder + "/" + name + ".md",
            isTrashed: trashed,
            rawBody: body,
            searchHaystack: NoteSnapshot.haystack(title: name, tags: tags, body: body),
            fileStemDiffersFromTitle: false
        )
    }

    /// `count` filler notes carrying `tags`, so a library can cross the
    /// co-occurrence floor without the fillers influencing anything else.
    private func filler(_ count: Int, tags: [String] = ["filler"], from index: Int = 0) -> [NoteSnapshot] {
        (0..<count).map { note("filler\(index + $0)", tags: tags, folder: "Filler") }
    }

    private func tags(_ suggestions: [TagSuggestion]) -> [String] {
        suggestions.map(\.tag)
    }

    // MARK: - Signal 1: the tag is written in the text

    func testLiteralTagInTheBodyIsSuggestedAndSaysWhy() {
        let library = [
            note("Other", tags: ["swift"]),
            note("Second", tags: ["swift"])
        ]
        let target = note("Target", body: "A long day of swift and coffee.")
        let result = TagSuggestions.suggest(for: target, in: library)
        XCTAssertEqual(tags(result), ["swift"])
        XCTAssertEqual(result.first?.reason, .inText)
    }

    func testLiteralMatchFoldsCaseAndAccents() {
        let library = [note("Other", tags: ["Été"])]
        let target = note("Target", body: "Nous partons cet ete.")
        XCTAssertEqual(tags(TagSuggestions.suggest(for: target, in: library)), ["Été"])
    }

    func testLiteralMatchNeedsAWholeWord() {
        let library = [note("Other", tags: ["art"]), note("Third", tags: ["art"])]
        let target = note("Target", body: "We start at noon and depart after.")
        XCTAssertTrue(
            TagSuggestions.suggest(for: target, in: library).isEmpty,
            "`art` inside `start` is not the tag `art`"
        )
    }

    func testATagTheNoteAlreadyCarriesIsNeverSuggested() {
        let library = [note("Other", tags: ["swift"])]
        let target = note("Target", tags: ["swift"], body: "swift swift swift")
        XCTAssertTrue(TagSuggestions.suggest(for: target, in: library).isEmpty)
    }

    func testTrashedNotesDoNotContributeTags() {
        let library = [note("Gone", tags: ["swift"], trashed: true)]
        let target = note("Target", body: "all about swift")
        XCTAssertTrue(TagSuggestions.suggest(for: target, in: library).isEmpty)
    }

    // MARK: - Signal 2: recency is a booster, never a reason

    func testRecencyAloneNeverReachesTheThreshold() {
        let recent = (0..<5).map {
            note(
                "Recent\($0)",
                tags: ["fresh"],
                folder: "Elsewhere",
                modified: Date(timeIntervalSince1970: 9_000 + Double($0))
            )
        }
        let target = note("Target", body: "nothing in common", folder: "Alone")
        XCTAssertTrue(
            TagSuggestions.suggest(for: target, in: recent).isEmpty,
            "Used lately is not a reason the app can defend in three words"
        )
    }

    func testRecencyLiftsAFolderTagOverTheThreshold() {
        // Four notes in the folder, three carrying `#recipe`: a 0.75 share,
        // worth 0.675 — under the threshold on its own. Twenty-six other
        // notes, all touched later, fill the recency window and push `#recipe`
        // out of it.
        func kitchen(_ when: Double) -> [NoteSnapshot] {
            var notes = (0..<3).map {
                note("Cook\($0)", tags: ["recipe"], folder: "Kitchen", modified: Date(timeIntervalSince1970: when))
            }
            notes.append(note("Cook3", tags: ["other"], folder: "Kitchen", modified: Date(timeIntervalSince1970: when)))
            return notes
        }
        let others = (0..<26).map {
            note("Other\($0)", tags: ["elsewhere"], folder: "Filler", modified: Date(timeIntervalSince1970: 5_000))
        }
        let target = note("Target", folder: "Kitchen")

        XCTAssertTrue(
            TagSuggestions.suggest(for: target, in: kitchen(1_000) + others).isEmpty,
            "Three quarters of a folder is not enough on its own"
        )

        let lifted = TagSuggestions.suggest(for: target, in: kitchen(9_000) + others)
        XCTAssertEqual(tags(lifted), ["recipe"])
        XCTAssertEqual(lifted.first?.reason, .thisFolder, "Recency boosts; the folder explains")
    }

    // MARK: - Signal 3: the dominant tags of the note's own folder

    func testAUnanimousFolderTagIsSuggested() {
        let library = (0..<4).map { note("Recipe\($0)", tags: ["recipe"], folder: "Kitchen") }
        let target = note("Target", folder: "Kitchen")
        let result = TagSuggestions.suggest(for: target, in: library)
        XCTAssertEqual(tags(result), ["recipe"])
        XCTAssertEqual(result.first?.reason, .thisFolder)
    }

    func testAnotherFoldersTagIsNotSuggested() {
        let library = (0..<4).map { note("Recipe\($0)", tags: ["recipe"], folder: "Kitchen") }
        let target = note("Target", folder: "Garage")
        XCTAssertTrue(TagSuggestions.suggest(for: target, in: library).isEmpty)
    }

    func testATwoNoteFolderIsTooSmallToBeDominant() {
        let library = (0..<2).map { note("Recipe\($0)", tags: ["recipe"], folder: "Kitchen") }
        let target = note("Target", folder: "Kitchen")
        XCTAssertTrue(TagSuggestions.suggest(for: target, in: library).isEmpty)
    }

    // MARK: - Signal 4: co-occurrence, and its 30-note floor

    /// 30 notes, 6 of them carrying `#client`, and every one of those 6 also
    /// carrying `#invoice`.
    private func coOccurrenceLibrary() -> [NoteSnapshot] {
        let clients = (0..<6).map { note("Client\($0)", tags: ["client", "invoice"], folder: "Work") }
        return clients + filler(26)
    }

    func testCoOccurrenceSuggestsTheCompanionTagAndNamesIt() {
        let target = note("Target", tags: ["client"], folder: "Elsewhere")
        let result = TagSuggestions.suggest(for: target, in: coOccurrenceLibrary())
        XCTAssertEqual(tags(result), ["invoice"])
        XCTAssertEqual(result.first?.reason, .withTag("client"))
    }

    func testUnderThirtyNotesCoOccurrenceIsSilent() {
        let clients = (0..<6).map { note("Client\($0)", tags: ["client", "invoice"], folder: "Work") }
        let target = note("Target", tags: ["client"], folder: "Elsewhere")
        XCTAssertTrue(
            TagSuggestions.suggest(for: target, in: clients + filler(10)).isEmpty,
            "Six notes agreeing is a coincidence, not a habit"
        )
    }

    func testUnderThirtyNotesLiteralAndRecencyStillAnswer() {
        let clients = (0..<6).map { note("Client\($0)", tags: ["client", "invoice"], folder: "Work") }
        let target = note("Target", tags: ["client"], body: "The invoice is late.", folder: "Elsewhere")
        let result = TagSuggestions.suggest(for: target, in: clients + filler(10))
        XCTAssertEqual(tags(result), ["invoice"])
        XCTAssertEqual(result.first?.reason, .inText, "The fallback is literal + recency")
    }

    // MARK: - Saying nothing, and never padding

    func testAnEmptyLibraryYieldsNothing() {
        XCTAssertTrue(TagSuggestions.suggest(for: note("Target"), in: []).isEmpty)
    }

    func testALibraryWithNoRelationYieldsNothingRatherThanFiller() {
        // Twelve tags exist, each on its own note, none related to the target
        // in any way. The section must not exist.
        let library = (0..<12).map { note("Note\($0)", tags: ["tag\($0)"], folder: "F\($0)") }
        let target = note("Target", body: "Completely unrelated prose.", folder: "Alone")
        XCTAssertEqual(
            TagSuggestions.suggest(for: target, in: library), [],
            "A header over filler is the intrusion this design avoids"
        )
    }

    func testNothingBelowTheThresholdSurvives() {
        let library = (0..<4).map { note("Recipe\($0)", tags: ["recipe"], folder: "Kitchen") }
        let target = note("Target", folder: "Kitchen")
        for suggestion in TagSuggestions.suggest(for: target, in: library) {
            XCTAssertGreaterThanOrEqual(suggestion.score, TagSuggestions.threshold)
        }
    }

    // MARK: - The cap

    func testAtMostFiveSuggestions() {
        // Eight tags, each written in the body: eight candidates at 1.0.
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        let library = words.map { note("N-\($0)", tags: [$0]) }
        let target = note("Target", body: words.joined(separator: " "))
        let result = TagSuggestions.suggest(for: target, in: library)
        XCTAssertEqual(result.count, TagSuggestions.maximumCount)
        XCTAssertEqual(result.count, 5)
    }

    func testTheOrderDoesNotDependOnTheOrderOfTheLibrary() {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        let library = words.map { note("N-\($0)", tags: [$0]) }
        let target = note("Target", body: words.joined(separator: " "))
        let first = TagSuggestions.suggest(for: target, in: library)
        let second = TagSuggestions.suggest(for: target, in: library.reversed())
        XCTAssertEqual(first, second, "A dictionary order must never reach the popover")
        XCTAssertEqual(first.count, 5)
    }

    func testSuggestionIsPureAndRepeatable() {
        let library = coOccurrenceLibrary()
        let target = note("Target", tags: ["client"], body: "invoice")
        XCTAssertEqual(
            TagSuggestions.suggest(for: target, in: library),
            TagSuggestions.suggest(for: target, in: library)
        )
    }

    // MARK: - Hygiene

    func testCaseDuplicateIsOffered() {
        let offer = TagHygiene.nearDuplicate(of: "Projet", among: ["projet", "autre"])
        XCTAssertEqual(offer?.existing, "projet")
        XCTAssertEqual(offer?.kind, .caseOrAccents)
    }

    func testAccentDuplicateIsOffered() {
        let offer = TagHygiene.nearDuplicate(of: "ete", among: ["été"])
        XCTAssertEqual(offer?.existing, "été")
        XCTAssertEqual(offer?.kind, .caseOrAccents)
    }

    func testPluralDuplicateIsOffered() {
        XCTAssertEqual(TagHygiene.nearDuplicate(of: "projets", among: ["projet"])?.existing, "projet")
        XCTAssertEqual(TagHygiene.nearDuplicate(of: "projet", among: ["projets"])?.existing, "projets")
        XCTAssertEqual(TagHygiene.nearDuplicate(of: "notes", among: ["note"])?.existing, "note")
        XCTAssertEqual(TagHygiene.nearDuplicate(of: "cities", among: ["city"])?.existing, "city")
        XCTAssertEqual(TagHygiene.nearDuplicate(of: "boxes", among: ["box"])?.existing, "box")
        XCTAssertEqual(
            TagHygiene.nearDuplicate(of: "projets", among: ["projet"])?.kind,
            .singularOrPlural
        )
    }

    func testPluralAcrossCaseAndAccentsTogether() {
        XCTAssertEqual(TagHygiene.nearDuplicate(of: "Étés", among: ["ete"])?.existing, "ete")
    }

    func testTheExactSameTagIsNotADuplicate() {
        XCTAssertNil(TagHygiene.nearDuplicate(of: "projet", among: ["projet"]))
    }

    func testAnUnrelatedTagIsNotADuplicate() {
        XCTAssertNil(TagHygiene.nearDuplicate(of: "voiture", among: ["projet", "été"]))
    }

    func testEmptyInputOffersNothing() {
        XCTAssertNil(TagHygiene.nearDuplicate(of: "   ", among: ["projet"]))
    }

    func testCaseCollisionWinsOverPluralCollision() {
        let offer = TagHygiene.nearDuplicate(of: "Projet", among: ["projets", "projet"])
        XCTAssertEqual(offer?.existing, "projet")
        XCTAssertEqual(offer?.kind, .caseOrAccents)
    }

    func testTheHumansTagIsNeverRewritten() {
        let offer = TagHygiene.nearDuplicate(of: "Projets", among: ["projet"])
        XCTAssertEqual(offer?.typed, "Projets", "The engine returns an offer, not a replacement")
    }

    func testShortWordsAreNotStemmedIntoNothing() {
        XCTAssertNil(TagHygiene.nearDuplicate(of: "os", among: ["o"]))
    }
}

/// Per-tag counts are tested against a real folder — including under mutation,
/// since they are memoized beside the sidebar badges.
@MainActor
final class TagCountTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-tagcount-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, tags: [String]) throws -> URL {
        let url = root.appendingPathComponent(name + ".md")
        let list = tags.joined(separator: ", ")
        try "---\ntitle: \(name)\ntags: [\(list)]\n---\nBody.\n"
            .write(to: url, atomically: true, encoding: .utf8)
        store.rescan()
        return url
    }

    private func count(_ name: String) -> Int? {
        store.tagCounts().first { $0.name == name }?.count
    }

    func testCountsTheNotesCarryingEachTag() throws {
        try write("One", tags: ["alpha", "beta"])
        try write("Two", tags: ["alpha"])
        XCTAssertEqual(count("alpha"), 2)
        XCTAssertEqual(count("beta"), 1, "A tag at 1 states a fact; the app draws no conclusion")
    }

    func testTagsMatchesTagCountsNames() throws {
        try write("One", tags: ["zebra", "alpha"])
        try write("Two", tags: ["Mango"])
        XCTAssertEqual(store.tags(), store.tagCounts().map(\.name))
        XCTAssertEqual(store.tags(), ["alpha", "Mango", "zebra"], "Alphabetical")
    }

    func testCountFollowsTagging() throws {
        let url = try write("One", tags: ["alpha"])
        XCTAssertEqual(count("alpha"), 1)

        store.applyTag("alpha", add: false, to: [url])
        store.rescan()
        XCTAssertNil(count("alpha"), "A tag nobody carries leaves the list")

        store.applyTag("beta", add: true, to: [url])
        store.rescan()
        XCTAssertEqual(count("beta"), 1)
    }

    func testTheCacheIsInvalidatedByAWriteRatherThanByARead() throws {
        let url = try write("One", tags: ["alpha"])
        XCTAssertEqual(count("alpha"), 1)
        // Two reads in a row must agree, and the second must be the memoized
        // one rather than a second pass with a different answer.
        XCTAssertEqual(store.tagCounts(), store.tagCounts())

        store.applyTag("alpha", add: true, to: [try write("Two", tags: [])])
        store.rescan()
        XCTAssertEqual(count("alpha"), 2)
        _ = url
    }

    func testTrashedNotesDoNotCount() throws {
        let url = try write("One", tags: ["alpha"])
        try write("Two", tags: ["alpha"])
        XCTAssertEqual(count("alpha"), 2)

        try store.trash([url])
        store.rescan()
        XCTAssertEqual(count("alpha"), 1, "The count follows what clicking the tag shows")
    }
}
