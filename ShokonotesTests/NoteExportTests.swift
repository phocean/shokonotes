import XCTest
import WebKit
@testable import Shokonotes

@MainActor
final class NoteExportTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private var outbox: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-export-\(UUID().uuidString)", isDirectory: true)
        outbox = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-export-out-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outbox, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: outbox)
    }

    private func makeNote(paragraphs: Int) throws -> NoteSnapshot {
        var body = """
        ---
        title: "Quarterly: report"
        tags: [work]
        created: 2026-01-02
        ---

        # Quarterly report

        ```swift
        let answer = 42
        ```

        """
        for index in 1...paragraphs {
            body += "Paragraph number \(index), long enough to take a line or two of the page box it is laid out in.\n\n"
        }
        let record = try store.createNote(named: "Quarterly report", in: root, extension: "md", body: body)
        return try XCTUnwrap(store.snapshot(for: record.url))
    }

    private func export(_ note: NoteSnapshot, named name: String) async throws -> URL {
        let destination = outbox.appendingPathComponent(name)
        let done = expectation(description: "pdf written")
        var outcome: Result<URL, Error>?
        NoteExport.writePDF(note, to: destination) { result in
            outcome = result
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        switch try XCTUnwrap(outcome) {
        case .success(let url):
            return url
        case .failure(let error):
            throw error
        }
    }

    /// The export is a real, paginated PDF — not one endless sheet.
    func testExportWritesAPaginatedPDF() async throws {
        let note = try makeNote(paragraphs: 120)
        let url = try await export(note, named: "long.pdf")

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))

        let provider = try XCTUnwrap(CGDataProvider(url: url as CFURL))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertGreaterThan(document.numberOfPages, 1, "a long note must paginate")
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertGreaterThan(box.height, 100)
        XCTAssertLessThan(box.height, 2000, "one page, not the whole scroll height")
        XCTAssertGreaterThan(box.width, 100)
    }

    /// The first rule of the product: an export writes a new file and leaves
    /// the note exactly as it was, bytes and modification date included.
    func testExportNeverRewritesTheNote() async throws {
        let note = try makeNote(paragraphs: 4)
        let before = try Data(contentsOf: note.url)
        let modifiedBefore = try fm.attributesOfItem(atPath: note.url.path)[.modificationDate] as? Date

        _ = try await export(note, named: "short.pdf")

        XCTAssertEqual(try Data(contentsOf: note.url), before)
        let modifiedAfter = try fm.attributesOfItem(atPath: note.url.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter)
        XCTAssertEqual(store.snapshot(for: note.url)?.rawBody, note.rawBody)
    }

    /// The panel opens on the note's title, sanitized like any other file name.
    func testSuggestedFileNameIsTheSanitizedTitle() throws {
        let note = try makeNote(paragraphs: 1)
        XCTAssertEqual(
            NoteExport.suggestedFileName(for: note, extension: "pdf"),
            "Quarterly- report.pdf"
        )
    }
}
