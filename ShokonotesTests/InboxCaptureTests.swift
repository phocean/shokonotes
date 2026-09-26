import XCTest
@testable import Shokonotes

final class InboxCaptureTests: XCTestCase {
    private var inbox: URL!

    override func setUp() async throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("shokonotes-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: inbox)
    }

    func testEmptyTextCreatesNothing() throws {
        XCTAssertNil(try InboxCapture.write(text: "", into: inbox))
        XCTAssertNil(try InboxCapture.write(text: "   \n\t  ", into: inbox))
        XCTAssertEqual(markdownFiles().count, 0)
    }

    func testOneLineWritesYAMLTitleAndExactBody() throws {
        let text = "Hello from the field"
        let url = try XCTUnwrap(try InboxCapture.write(text: text, into: inbox))

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, inbox.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "md")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let parsed = FrontMatterCodec.parse(onDisk)
        XCTAssertEqual(parsed.frontMatter?.title, text)
        XCTAssertEqual(parsed.frontMatter?.tags, [])
        XCTAssertNotNil(parsed.frontMatter?.created)
        XCTAssertEqual(parsed.body, text)
        XCTAssertFalse(onDisk.contains("\n# "))
    }

    func testTitleIsFirstLineBodyIsFullTypedText() throws {
        let text = "First line\n\nThe rest stays as typed.\n"
        let url = try XCTUnwrap(try InboxCapture.write(text: text, into: inbox))
        let parsed = FrontMatterCodec.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.frontMatter?.title, "First line")
        XCTAssertEqual(parsed.body, text)
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "First line")
    }

    func testLeadingBlankLineUsesNextNonEmptyLine() throws {
        let text = "\n  Title from the second line  \nbody"
        XCTAssertEqual(InboxCapture.captureTitle(from: text), "Title from the second line")
        let url = try XCTUnwrap(try InboxCapture.write(text: text, into: inbox))
        let parsed = FrontMatterCodec.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.frontMatter?.title, "Title from the second line")
        XCTAssertEqual(parsed.body, text)
    }

    func testQuotesColonInTitle() throws {
        let text = "Agenda: Monday"
        let url = try XCTUnwrap(try InboxCapture.write(text: text, into: inbox))
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("title: \"Agenda: Monday\""))
        XCTAssertEqual(FrontMatterCodec.parse(onDisk).body, text)
    }

    func testUniqueFilenames() throws {
        let first = try XCTUnwrap(try InboxCapture.write(text: "Same title", into: inbox))
        let second = try XCTUnwrap(try InboxCapture.write(text: "Same title", into: inbox))
        XCTAssertEqual(first.deletingPathExtension().lastPathComponent, "Same title")
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent, "Same title 2")
        XCTAssertEqual(markdownFiles().count, 2)
    }

    func testComposeTextOnlyURLOnlyAndBoth() {
        let page = URL(string: "https://example.com/page")!
        XCTAssertEqual(InboxCapture.compose(text: "hello", url: nil), "hello")
        XCTAssertEqual(InboxCapture.compose(text: nil, url: page), "https://example.com/page")
        XCTAssertEqual(
            InboxCapture.compose(text: "Page Title", url: page),
            "Page Title\n\nhttps://example.com/page"
        )
        XCTAssertEqual(InboxCapture.compose(text: "  \n", url: page), "https://example.com/page")
        XCTAssertEqual(InboxCapture.compose(text: nil, url: nil), "")
        XCTAssertEqual(InboxCapture.compose(text: "   ", url: nil), "")
    }

    func testComposeThenWriteUsesPageTitle() throws {
        let page = URL(string: "https://example.com/notes")!
        let payload = InboxCapture.compose(text: "Shared page", url: page)
        let url = try XCTUnwrap(try InboxCapture.write(text: payload, into: inbox))
        let parsed = FrontMatterCodec.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.frontMatter?.title, "Shared page")
        XCTAssertEqual(parsed.body, "Shared page\n\nhttps://example.com/notes")
    }

    func testEmptyComposeWritesNothing() throws {
        XCTAssertNil(try InboxCapture.write(text: InboxCapture.compose(text: nil, url: nil), into: inbox))
        XCTAssertEqual(markdownFiles().count, 0)
    }

    func testBadBookmarkThrowsCannotOpenFolder() {
        XCTAssertThrowsError(
            try InboxCapture.write(text: "Hello", bookmark: Data("not a bookmark".utf8))
        ) { error in
            XCTAssertEqual(error as? LibraryError, .cannotOpenFolder)
        }
        XCTAssertEqual(markdownFiles().count, 0)
    }

    func testEmptyTextWithBadBookmarkStillCreatesNothing() throws {
        XCTAssertNil(try InboxCapture.write(text: "  ", bookmark: Data("not a bookmark".utf8)))
        XCTAssertEqual(markdownFiles().count, 0)
    }

    func testWriteViaBookmarkRoundTripsATemporaryFolder() throws {
        let bookmark = try BookmarkStore.makeBookmark(for: inbox)
        let text = "From a bookmark"
        let url = try XCTUnwrap(try InboxCapture.write(text: text, bookmark: bookmark))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, inbox.standardizedFileURL)
        let parsed = FrontMatterCodec.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.frontMatter?.title, text)
        XCTAssertEqual(parsed.body, text)
    }

    func testHonoursFileExtension() throws {
        let url = try XCTUnwrap(try InboxCapture.write(text: "Extended", into: inbox, fileExtension: "markdown"))
        XCTAssertEqual(url.pathExtension, "markdown")
    }

    // MARK: - Title bound

    /// A shared paragraph has no newline: the whole payload used to land in
    /// `title:`. The body stays exactly what was shared.
    func testLongSingleLineTitleIsBoundedButBodyIsNot() throws {
        let sentence = String(repeating: "mot ", count: 400)
        let title = InboxCapture.captureTitle(from: sentence)
        XCTAssertLessThanOrEqual(title.count, InboxCapture.maxTitleLength)
        XCTAssertFalse(title.hasSuffix(" "))

        let url = try XCTUnwrap(try InboxCapture.write(text: sentence, into: inbox))
        let parsed = FrontMatterCodec.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.frontMatter?.title, title)
        XCTAssertEqual(parsed.body, sentence)
    }

    func testOneUnbrokenWordIsCutAtTheBound() {
        let word = String(repeating: "a", count: 500)
        XCTAssertEqual(InboxCapture.captureTitle(from: word).count, InboxCapture.maxTitleLength)
    }

    func testShortTitlesAreUntouched() {
        XCTAssertEqual(InboxCapture.captureTitle(from: "Short one"), "Short one")
    }

    // MARK: - Handoff coding

    /// `%` is a member of `urlQueryAllowed`, so it used to travel raw in
    /// `percentEncodedQuery` and corrupt the shared text.
    func testPercentSurvivesTheRoundTrip() throws {
        let text = "-20% de remise"
        let url = try XCTUnwrap(InboxHandoffCodec.openURL(body: text))
        XCTAssertEqual(InboxHandoffCodec.body(from: url), text)
    }

    func testAmpersandAndHashSurviveTheRoundTrip() throws {
        for text in ["Fish & chips", "Tag #urgent", "a=b&c=d?e#f 100%", "50 % + 50 %"] {
            let url = try XCTUnwrap(InboxHandoffCodec.openURL(body: text))
            XCTAssertEqual(InboxHandoffCodec.body(from: url), text, "round trip of \(text)")
        }
    }

    func testAccentsAndNewlinesSurviveTheRoundTrip() throws {
        let text = "Réunion à 9h\n\nNotes — suite\n"
        let url = try XCTUnwrap(InboxHandoffCodec.openURL(body: text))
        XCTAssertEqual(InboxHandoffCodec.body(from: url), text)
    }

    func testEmptyBodyDecodesToNil() throws {
        let url = try XCTUnwrap(InboxHandoffCodec.openURL(body: "   \n  "))
        XCTAssertNil(InboxHandoffCodec.body(from: url))
        let bare = try XCTUnwrap(URL(string: "shokonotes://inbox"))
        XCTAssertNil(InboxHandoffCodec.body(from: bare))
    }

    func testForeignURLIsNotAnInboxURL() throws {
        let other = try XCTUnwrap(URL(string: "https://example.com/inbox?body=hello"))
        XCTAssertFalse(InboxHandoffCodec.isInboxURL(other))
        XCTAssertNil(InboxHandoffCodec.body(from: other))
    }

    func testTruncationNeverSplitsASurrogatePair() {
        let emoji = String(repeating: "👍", count: InboxHandoffCodec.maxUTF16Length)
        let cut = InboxHandoffCodec.truncated(emoji)
        XCTAssertLessThanOrEqual(cut.utf16.count, InboxHandoffCodec.maxUTF16Length)
        XCTAssertEqual(cut.utf16.count % 2, 0)
        XCTAssertEqual(cut.unicodeScalars.allSatisfy { $0 == "👍" }, true)

        // An odd offset puts the bound in the middle of a pair: the emoji must
        // be dropped whole, never left as a lone lead unit.
        let offset = "x" + String(repeating: "👍", count: InboxHandoffCodec.maxUTF16Length)
        let odd = InboxHandoffCodec.truncated(offset)
        XCTAssertEqual(odd.utf16.count, InboxHandoffCodec.maxUTF16Length - 1)
        XCTAssertTrue(odd.hasPrefix("x"))
        XCTAssertTrue(odd.hasSuffix("👍"))
        XCTAssertEqual(odd.unicodeScalars.filter { $0 == "\u{FFFD}" }.count, 0)
    }

    func testShortTextIsNotTruncated() {
        XCTAssertEqual(InboxHandoffCodec.truncated("hello"), "hello")
    }

    func testMarkerRoundTrip() {
        XCTAssertEqual(InboxHandoffCodec.unmarked(InboxHandoffCodec.marked("draft")), "draft")
        XCTAssertNil(InboxHandoffCodec.unmarked("something he copied himself"))
        XCTAssertNil(InboxHandoffCodec.unmarked(nil))
    }

    func testMarkedQueueRoundTripsOneDraft() {
        let drafts = ["-20% de remise"]
        XCTAssertEqual(
            InboxHandoffCodec.queue(from: InboxHandoffCodec.marked(drafts)),
            drafts
        )
    }

    func testMarkedQueueRoundTripsTwoDrafts() {
        let drafts = ["First share", "Fish & chips\n#urgent"]
        XCTAssertEqual(
            InboxHandoffCodec.queue(from: InboxHandoffCodec.marked(drafts)),
            drafts
        )
    }

    func testOldSingleBodyStillDecodesAsOneElementQueue() {
        let old = InboxHandoffCodec.marked("draft from yesterday")
        XCTAssertEqual(InboxHandoffCodec.queue(from: old), ["draft from yesterday"])
        XCTAssertEqual(InboxHandoffCodec.queue(from: nil), [])
        XCTAssertEqual(InboxHandoffCodec.queue(from: "something he copied himself"), [])
    }

    private func markdownFiles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
    }
}
