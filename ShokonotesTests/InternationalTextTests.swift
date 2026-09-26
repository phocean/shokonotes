import XCTest
@testable import Shokonotes

/// The two engine defects that surface as soon as a note is written in
/// Japanese, Chinese or Korean: a file name capped in characters instead of
/// UTF-8 bytes, and a search fold that ignored character width.
@MainActor
final class InternationalTextTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-intl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Defect 1: the byte cap

    func testJapaneseTitleStaysUnderTheFileSystemByteLimit() throws {
        // 150 ideograms is 450 UTF-8 bytes: over the 255-byte APFS component
        // limit, so the old character-only cap produced a name that could not
        // be written.
        let title = String(repeating: "書", count: 150)
        XCTAssertEqual(title.utf8.count, 450)

        let name = FilenameSanitizer.sanitize(title)
        XCTAssertLessThanOrEqual(name.utf8.count, FilenameSanitizer.maxUTF8Bytes)
        XCTAssertFalse(name.isEmpty)

        // The whole component that lands on disk — stem, uniqueness suffix and
        // extension — has to fit too.
        let unique = FilenameSanitizer.uniqueName(base: name, ext: "md", in: root)
        let component = unique + ".md"
        XCTAssertLessThan(component.utf8.count, 255)
    }

    func testJapaneseTitleActuallyCreatesTheFile() throws {
        let title = String(repeating: "書", count: 150)
        let record = try store.createNote(
            named: title,
            in: root,
            extension: "md",
            body: FrontMatterCodec.newNote(title: title, body: "本文\n")
        )
        XCTAssertTrue(fm.fileExists(atPath: record.url.path))
        XCTAssertLessThan(record.url.lastPathComponent.utf8.count, 255)
    }

    func testASecondJapaneseNoteOfTheSameTitleStillFits() throws {
        // The uniqueness suffix is what the byte budget reserves room for.
        let title = String(repeating: "書", count: 150)
        let body = FrontMatterCodec.newNote(title: title, body: "本文\n")
        let first = try store.createNote(named: title, in: root, extension: "md", body: body)
        let second = try store.createNote(named: title, in: root, extension: "md", body: body)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(fm.fileExists(atPath: second.url.path))
        XCTAssertLessThan(second.url.lastPathComponent.utf8.count, 255)
    }

    func testTruncationNeverSplitsAComposedEmoji() throws {
        // A family emoji is one grapheme cluster of 25 UTF-8 bytes; a flag is
        // one cluster of 8. Repeating them crosses the byte cap mid-cluster,
        // which is exactly where a naive byte cut would corrupt the string.
        for glyph in ["👨‍👩‍👧‍👦", "🇯🇵"] {
            let title = String(repeating: glyph, count: 60)
            let name = FilenameSanitizer.sanitize(title)
            XCTAssertLessThanOrEqual(name.utf8.count, FilenameSanitizer.maxUTF8Bytes)
            // Whole clusters only: the result is a run of the same glyph, and
            // its byte count is an exact multiple of one glyph.
            XCTAssertEqual(name.utf8.count % glyph.utf8.count, 0, "cut inside a grapheme cluster")
            XCTAssertEqual(name, String(repeating: glyph, count: name.count))
            XCTAssertTrue(name.unicodeScalars.allSatisfy { $0.value != 0xFFFD })
            // And it round-trips through UTF-8 unchanged.
            XCTAssertEqual(String(decoding: Array(name.utf8), as: UTF8.self), name)
        }
    }

    func testEmojiTitleCreatesTheFile() throws {
        let title = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        let record = try store.createNote(
            named: title,
            in: root,
            extension: "md",
            body: FrontMatterCodec.newNote(title: title, body: "family\n")
        )
        XCTAssertTrue(fm.fileExists(atPath: record.url.path))
        XCTAssertLessThan(record.url.lastPathComponent.utf8.count, 255)
    }

    func testASCIITitleKeepsTheCharacterCap() throws {
        let title = String(repeating: "a", count: 300)
        let name = FilenameSanitizer.sanitize(title)
        XCTAssertEqual(name.count, 150, "ASCII behaviour must not change")
        XCTAssertEqual(name, String(repeating: "a", count: 150))
    }

    func testTheOtherSanitizeRulesAreUntouched() throws {
        XCTAssertEqual(FilenameSanitizer.sanitize("a/b:c"), "a-b-c")
        XCTAssertEqual(FilenameSanitizer.sanitize("..hidden"), "hidden")
        XCTAssertEqual(FilenameSanitizer.sanitize("   "), "Untitled Note")
        XCTAssertEqual(FilenameSanitizer.sanitize(""), "Untitled Note")
        XCTAssertEqual(FilenameSanitizer.sanitize("a\0b"), "ab")
    }

    // MARK: - Defect 2: width-insensitive search

    private func snapshot(_ name: String, _ text: String) throws -> NoteSnapshot {
        let url = root.appendingPathComponent(name + ".md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        store.rescan()
        return try XCTUnwrap(store.snapshot(for: url))
    }

    func testHalfWidthKatakanaFindsFullWidth() throws {
        let note = try snapshot("Fruit", "---\ntitle: 果物\n---\nバナナを買う\n")
        XCTAssertTrue(note.matches(terms: ["ﾊﾞﾅﾅ"]), "half-width query must find full-width text")
        XCTAssertTrue(note.matches(terms: ["バナナ"]))
        XCTAssertFalse(note.matches(terms: ["ﾘﾝｺﾞ"]))
    }

    func testFullWidthKatakanaFindsHalfWidth() throws {
        let note = try snapshot("Fruit2", "---\ntitle: 果物\n---\nﾊﾞﾅﾅを買う\n")
        XCTAssertTrue(note.matches(terms: ["バナナ"]), "full-width query must find half-width text")
    }

    func testFullWidthLatinFindsASCII() throws {
        let note = try snapshot("Codes", "---\ntitle: ABC\n---\nreference ABC-1\n")
        XCTAssertTrue(note.matches(terms: ["ＡＢＣ"]))
        let wide = try snapshot("Codes2", "---\ntitle: ＡＢＣ\n---\nreference\n")
        XCTAssertTrue(wide.matches(terms: ["abc"]))
    }

    func testAccentAndCaseSearchStillWorks() throws {
        let note = try snapshot("Recette", "---\ntitle: Crêpes\ntags: [Été]\n---\nDu café déjà PRÊT.\n")
        XCTAssertTrue(note.matches(terms: ["crepes"]))
        XCTAssertTrue(note.matches(terms: ["CRÊPES"]))
        XCTAssertTrue(note.matches(terms: ["cafe"]))
        XCTAssertTrue(note.matches(terms: ["ete"]))
        XCTAssertFalse(note.matches(terms: ["gaufres"]))
    }

    func testFoldingIsTheSameOnBothSides() throws {
        for (a, b) in [("ﾊﾞﾅﾅ", "バナナ"), ("ＡＢＣ", "ABC"), ("ｶﾞｷﾞ", "ガギ"), ("ﾊﾟ", "パ")] {
            XCTAssertEqual(NoteSnapshot.fold(a), NoteSnapshot.fold(b), "\(a) must fold like \(b)")
        }
        // Voicing is not a diacritic to strip: バ must not collapse into ハ.
        XCTAssertNotEqual(NoteSnapshot.fold("バナナ"), NoteSnapshot.fold("ハナナ"))
    }

    func testSubstringMatchingSurvivesForLanguagesWithoutSpaces() throws {
        let note = try snapshot("Journal", "---\ntitle: 東京旅行\n---\n京都にも行った\n")
        XCTAssertTrue(note.matches(terms: ["東京"]))
        XCTAssertTrue(note.matches(terms: ["京都"]))
    }
}
