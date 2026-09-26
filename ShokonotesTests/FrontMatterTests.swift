import XCTest
@testable import Shokonotes

final class FrontMatterTests: XCTestCase {
    func testQuotedTitleWithColonRoundTrips() {
        let matter = FrontMatter(title: "Meeting: Q3", tags: ["work"], created: "2026-09-09")
        let raw = FrontMatterCodec.write(frontMatter: matter, body: "Hello\n")
        XCTAssertTrue(raw.contains("title: \"Meeting: Q3\""))
        XCTAssertFalse(raw.contains("\n# "))
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertEqual(parsed.frontMatter?.title, "Meeting: Q3")
        XCTAssertEqual(parsed.frontMatter?.tags, ["work"])
        XCTAssertEqual(parsed.body, "Hello\n")
    }

    func testNewNoteBodyHasNoH1() {
        let body = NoteActions.newNoteBody(named: "Note: with colon")
        XCTAssertTrue(body.hasPrefix("---\n"))
        XCTAssertTrue(body.contains("title: \"Note: with colon\""))
        XCTAssertTrue(body.contains("tags: []"))
        XCTAssertFalse(body.contains("\n# "))
        let parsed = FrontMatterCodec.parse(body)
        XCTAssertEqual(parsed.frontMatter?.title, "Note: with colon")
        XCTAssertEqual(parsed.body, "\n")
    }

    func testNewNoteCopiesTypedBodyUnchanged() {
        let typed = "First line\nrest as typed"
        let raw = FrontMatterCodec.newNote(title: "First line", body: typed)
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertEqual(parsed.frontMatter?.title, "First line")
        XCTAssertEqual(parsed.frontMatter?.tags, [])
        XCTAssertEqual(parsed.body, typed)
        XCTAssertFalse(raw.contains("\n# "))
    }

    func testTitlePrefersFileNameWhenAsked() {
        let parsed = FrontMatterCodec.parse("# Heading\n\nBody\n")
        XCTAssertEqual(NoteExcerpt.title(from: parsed, fileName: "file", useFirstLine: true), "Heading")
        XCTAssertEqual(NoteExcerpt.title(from: parsed, fileName: "file", useFirstLine: false), "file")
    }

    func testDocumentWithoutYAMLStaysIntact() {
        let raw = "# Heading\n\nBody text\n"
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertNil(parsed.frontMatter)
        XCTAssertEqual(parsed.body, raw)
    }

    func testWithTagsInsertsFrontMatterWithoutTouchingBody() {
        let raw = "Keep this body\n"
        let rewritten = FrontMatterCodec.withTags(raw, tags: ["inbox", "later"])
        let parsed = FrontMatterCodec.parse(rewritten)
        XCTAssertEqual(parsed.frontMatter?.tags, ["inbox", "later"])
        XCTAssertEqual(parsed.body, "Keep this body\n")
    }

    func testThematicBreaksAreNotFrontMatter() {
        let raw = "---\n\nIntro paragraph\n\n---\nSecond section\n"
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertNil(parsed.frontMatter)
        XCTAssertEqual(parsed.body, raw)
        let tagged = FrontMatterCodec.withTags(raw, tags: ["keep"])
        XCTAssertTrue(tagged.contains("Intro paragraph"))
        XCTAssertTrue(tagged.contains("Second section"))
        let again = FrontMatterCodec.parse(tagged)
        XCTAssertEqual(again.frontMatter?.tags, ["keep"])
        XCTAssertTrue(again.body.contains("Intro paragraph"))
    }

    func testUnknownYAMLKeysSurviveTagging() {
        let raw = """
        ---
        title: "A"
        aliases: [old]
        tags: []
        created: 2026-01-01
        ---
        Body stays
        """
        let tagged = FrontMatterCodec.withTags(raw, tags: ["inbox"])
        XCTAssertTrue(tagged.contains("aliases: [old]"))
        XCTAssertTrue(tagged.contains("Body stays"))
        let parsed = FrontMatterCodec.parse(tagged)
        XCTAssertEqual(parsed.frontMatter?.tags, ["inbox"])
        XCTAssertEqual(parsed.body, "Body stays")
    }

    func testTaggingPreservesCRLFBody() {
        let crlf = "\u{000D}\u{000A}"
        let raw = ["---", "title: \"A\"", "tags: []", "created: 2026-01-01", "---", "Line one", "Line two", ""]
            .joined(separator: crlf)
        let split = FrontMatterCodec.splitFence(raw)
        XCTAssertEqual(split?.body, "Line one\(crlf)Line two\(crlf)")
        let tagged = FrontMatterCodec.withTags(raw, tags: ["x"])
        XCTAssertTrue(tagged.contains("Line one"))
        let parsed = FrontMatterCodec.parse(tagged)
        XCTAssertEqual(parsed.body, "Line one\(crlf)Line two\(crlf)")
        XCTAssertEqual(parsed.frontMatter?.tags, ["x"])
    }

    func testNestedYAMLKeysAreNotNoteMetadata() {
        let raw = """
        ---
        title: "A"
        image:
          title: caption
        tags: []
        created: 2026-01-01
        ---
        Body
        """
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertEqual(parsed.frontMatter?.title, "A")
        XCTAssertEqual(parsed.body, "Body")

        let tagged = FrontMatterCodec.withTags(raw, tags: ["inbox"])
        XCTAssertTrue(tagged.contains("  title: caption"))
        XCTAssertTrue(tagged.contains("Body"))
        let again = FrontMatterCodec.parse(tagged)
        XCTAssertEqual(again.frontMatter?.title, "A")
        XCTAssertEqual(again.frontMatter?.tags, ["inbox"])
        XCTAssertEqual(again.body, "Body")
    }

    func testSingleQuotedApostropheUnquotes() {
        XCTAssertEqual(FrontMatterCodec.unquote("'Jean''s notes'"), "Jean's notes")
        let raw = """
        ---
        title: 'Jean''s notes'
        tags: []
        created: 2026-01-01
        ---
        Body
        """
        XCTAssertEqual(FrontMatterCodec.parse(raw).frontMatter?.title, "Jean's notes")
    }

    func testOpeningFenceWithTrailingSpacesParses() {
        let raw = "--- \ntitle: \"A\"\ntags: []\ncreated: 2026-01-01\n---\nBody\n"
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertEqual(parsed.frontMatter?.title, "A")
        XCTAssertEqual(parsed.body, "Body\n")

        let tagged = FrontMatterCodec.withTags(raw, tags: ["inbox"])
        let taggedParsed = FrontMatterCodec.parse(tagged)
        XCTAssertEqual(taggedParsed.frontMatter?.tags, ["inbox"])
        XCTAssertEqual(taggedParsed.body, "Body\n")
        XCTAssertFalse(taggedParsed.body.contains("---"))

        let notAFence = "--- not a fence\ntitle: x\n---\nBody\n"
        XCTAssertNil(FrontMatterCodec.parse(notAFence).frontMatter)
        XCTAssertEqual(FrontMatterCodec.parse(notAFence).body, notAFence)

        let crlf = "\u{000D}\u{000A}"
        let crlfRaw = ["--- ", "title: \"A\"", "tags: []", "created: 2026-01-01", "---", "Body", ""]
            .joined(separator: crlf)
        let crlfParsed = FrontMatterCodec.parse(crlfRaw)
        XCTAssertEqual(crlfParsed.frontMatter?.title, "A")
        XCTAssertEqual(crlfParsed.body, "Body\(crlf)")
    }

    func testSingleQuotedFlowTagsKeepCommasInsideQuotes() {
        let raw = """
        ---
        title: "A"
        tags: ['hello, world', 'c']
        created: 2026-01-01
        ---
        Body
        """
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertEqual(parsed.frontMatter?.tags, ["hello, world", "c"])

        let rewritten = FrontMatterCodec.withTags(raw, tags: parsed.frontMatter?.tags ?? [])
        let again = FrontMatterCodec.parse(rewritten)
        XCTAssertEqual(again.frontMatter?.tags, ["hello, world", "c"])
        XCTAssertEqual(again.body, "Body")
    }

    func testDoubleQuotedFlowTagsKeepCommasInsideQuotes() {
        let raw = """
        ---
        title: "A"
        tags: ["hello, world", "c"]
        created: 2026-01-01
        ---
        Body
        """
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertEqual(parsed.frontMatter?.tags, ["hello, world", "c"])
        let rewritten = FrontMatterCodec.withTags(raw, tags: ["hello, world", "c"])
        XCTAssertEqual(FrontMatterCodec.parse(rewritten).frontMatter?.tags, ["hello, world", "c"])
    }

    func testSingleQuotedTagApostropheDoesNotEndTheQuote() {
        let raw = """
        ---
        title: "A"
        tags: ['Jean''s notes', 'c']
        created: 2026-01-01
        ---
        Body
        """
        XCTAssertEqual(FrontMatterCodec.parse(raw).frontMatter?.tags, ["Jean's notes", "c"])
    }

    func testInlineCommentAfterQuotedScalarIsNotPartOfTheValue() {
        let raw = """
        ---
        title: "Hello" # keep
        tags: ["a", "b"] # keep
        created: "2026-01-01" # keep
        ---
        Body
        """
        let parsed = FrontMatterCodec.parse(raw)
        XCTAssertEqual(parsed.frontMatter?.title, "Hello")
        XCTAssertEqual(parsed.frontMatter?.tags, ["a", "b"])
        XCTAssertEqual(parsed.frontMatter?.created, "2026-01-01")
        XCTAssertEqual(parsed.body, "Body")

        let tagged = FrontMatterCodec.withTags(raw, tags: ["x"])
        let taggedParsed = FrontMatterCodec.parse(tagged)
        XCTAssertEqual(taggedParsed.frontMatter?.title, "Hello")
        XCTAssertEqual(taggedParsed.frontMatter?.tags, ["x"])
        XCTAssertEqual(taggedParsed.body, "Body")
        XCTAssertFalse(tagged.contains("\\\"Hello\\\""))
        XCTAssertTrue(tagged.contains("title: \"Hello\""))

        let titled = FrontMatterCodec.withTitle(raw, title: "Hello")
        XCTAssertEqual(FrontMatterCodec.parse(titled).frontMatter?.title, "Hello")
        XCTAssertFalse(titled.contains("\\\"Hello\\\""))
    }

    func testHashInsideQuotedTitleStays() {
        let raw = """
        ---
        title: "Hello # keep"
        tags: []
        created: 2026-01-01
        ---
        Body
        """
        XCTAssertEqual(FrontMatterCodec.parse(raw).frontMatter?.title, "Hello # keep")
        let tagged = FrontMatterCodec.withTags(raw, tags: ["x"])
        XCTAssertEqual(FrontMatterCodec.parse(tagged).frontMatter?.title, "Hello # keep")
    }
}
