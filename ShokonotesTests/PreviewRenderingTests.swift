import XCTest
import AppKit
import WebKit
@testable import Shokonotes

/// What the preview actually *paints*, measured in a real web view rather than
/// asserted on the HTML we hand it. Both of the defects this file covers —
/// syntax highlighting that never ran, local images that never loaded — emit
/// perfectly plausible markup and fail at load time, so a string assertion
/// would have passed while the page stayed grey and the image stayed broken.
@MainActor
final class PreviewRenderingTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-preview-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Harness

    private func makeNote(named name: String, body: String, in folder: URL? = nil) throws -> NoteSnapshot {
        let record = try store.createNote(
            named: name,
            in: folder ?? root,
            extension: "md",
            body: body
        )
        return try XCTUnwrap(store.snapshot(for: record.url))
    }

    /// Renders the note through the shared preview path and hands back the
    /// loaded web view. Held by the caller for as long as it evaluates in it.
    private func render(_ note: NoteSnapshot) async throws -> WKWebView {
        let done = expectation(description: "page loaded")
        var outcome: Result<WKWebView, Error>?
        PreviewPageRenderer.load(note) { result in
            outcome = result
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        switch try XCTUnwrap(outcome) {
        case .success(let view): return view
        case .failure(let error): throw error
        }
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }

    /// A real PNG on disk, next to a real note.
    @discardableResult
    private func writePNG(named name: String, in folder: URL, side: Int = 24) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let context = NSGraphicsContext(bitmapImageRep: try XCTUnwrap(rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Syntax highlighting

    /// The Code Theme setting is only real if the highlighter runs. It never
    /// did: the bundled library is highlight.js v9.13.1, which has no
    /// `highlightAll`, so the call appended to it threw into its own catch and
    /// the page kept bare `<code class="language-swift">` with zero spans.
    func testFencedCodeIsHighlighted() async throws {
        let note = try makeNote(named: "Code", body: """
        ---
        title: Code
        ---

        ```swift
        struct Answer {
            let value = 42
        }
        ```
        """)

        let webView = try await render(note)

        let spans = try await evaluate(
            "document.querySelectorAll('pre code span[class^=\"hljs-\"]').length",
            in: webView
        ) as? Int
        XCTAssertGreaterThan(spans ?? 0, 0, "the highlighter produced no spans: it did not run")

        let classes = try await evaluate(
            """
            Array.from(document.querySelectorAll('pre code span'))
                 .map(function(s){ return s.className; })
                 .filter(function(c){ return c.indexOf('hljs-') === 0; })
                 .join(' ')
            """,
            in: webView
        ) as? String
        let joined = classes ?? ""
        XCTAssertTrue(joined.contains("hljs-keyword"), "expected Swift keywords to be classed, got: \(joined)")

        // v9 marks the block itself; v10+ does too. Either way the stylesheet
        // needs the hook, or the spans are coloured by nothing.
        let marked = try await evaluate(
            "document.querySelectorAll('pre code.hljs').length",
            in: webView
        ) as? Int
        XCTAssertGreaterThan(marked ?? 0, 0, "the code block was not marked for the theme stylesheet")
    }

    /// Copy buttons are a live-preview injection. Print and PDF go through
    /// this renderer and must not grow a control that has nowhere to click.
    func testPrintPathHasNoCopyButtons() async throws {
        let note = try makeNote(named: "Code", body: """
        ---
        title: Code
        ---

        ```swift
        struct Answer {
            let value = 42
        }
        ```
        """)

        let webView = try await render(note)
        let buttons = try await evaluate(
            "document.querySelectorAll('.\(PreviewCopy.buttonClass)').length",
            in: webView
        ) as? Int
        XCTAssertEqual(buttons, 0, "print/PDF renderer planted copy buttons")
    }

    /// Whatever library is bundled tomorrow, the injected script must find its
    /// entry point. This one pins the contract rather than the current build.
    func testHighlightScriptHandlesBothLibraryGenerations() {
        PreviewAssetCache.shared.removeAll()
        let script = PreviewCodeTheme.highlightScript()
        XCTAssertTrue(script.contains("highlightElement"), "modern entry point missing")
        XCTAssertTrue(script.contains("highlightBlock"), "v9 entry point missing")
        XCTAssertTrue(script.contains("pre code"), "nothing selects the blocks to highlight")
    }

    // MARK: - Local images

    /// A note's own images are part of reading it. `![](square.png)` next to
    /// the note must paint, in the preview and in everything that shares its
    /// renderer (print, PDF export).
    func testLocalImageLoads() async throws {
        try writePNG(named: "square.png", in: root)
        let note = try makeNote(named: "Illustrated", body: """
        ---
        title: Illustrated
        ---

        ![](square.png)
        """)

        let webView = try await render(note)

        let count = try await evaluate("document.images.length", in: webView) as? Int
        XCTAssertEqual(count, 1, "the image element itself is missing")

        let width = try await evaluate("document.images[0].naturalWidth", in: webView) as? Int
        XCTAssertEqual(width, 24, "the image did not load: broken-image placeholder")
        let complete = try await evaluate("document.images[0].complete", in: webView) as? Bool
        XCTAssertEqual(complete, true)
    }

    /// The same, for a note in a subfolder with a percent-escaped name, which
    /// is where a naive path join stops agreeing with a URL resolve.
    func testLocalImageLoadsFromSubfolderWithSpaces() async throws {
        let folder = root.appendingPathComponent("Trip notes", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try writePNG(named: "beach view.png", in: folder, side: 16)
        let note = try makeNote(named: "Trip", body: """
        ---
        title: Trip
        ---

        ![](beach%20view.png)
        """, in: folder)

        let webView = try await render(note)
        let width = try await evaluate("document.images[0].naturalWidth", in: webView) as? Int
        XCTAssertEqual(width, 16, "the image in a folder with a space did not load")
    }

    /// A remote image must not be rewritten into a local one, and a missing
    /// local file must not take the renderer down with it.
    func testRemoteAndMissingImagesAreLeftAlone() async throws {
        let note = try makeNote(named: "Mixed", body: """
        ---
        title: Mixed
        ---

        ![](https://example.com/remote.png)

        ![](nothing-here.png)
        """)

        let webView = try await render(note)
        let sources = try await evaluate(
            "Array.from(document.images).map(function(i){ return i.getAttribute('src'); }).join('|')",
            in: webView
        ) as? String
        XCTAssertTrue(sources?.contains("https://example.com/remote.png") == true,
                      "a remote source was rewritten: \(sources ?? "nil")")
    }

    // MARK: - What gets inlined

    /// The document once every deferred payload has landed — the same two
    /// passes the export path makes: resolve, build off the main thread,
    /// resolve again against a warm cache.
    private func resolved(_ src: String, target: PreviewImageRendition.Target = .screen) -> String {
        let html = "<img src=\"\(src)\">"
        let first = MarkdownRenderer.resolve(html, base: root, target: target)
        guard !first.deferred.isEmpty else { return first.html }
        _ = MarkdownRenderer.buildDeferredImages(first.deferred)
        return MarkdownRenderer.resolve(html, base: root, target: target).html
    }

    /// The base64 payload of a `data:` URI in a resolved document.
    private func payload(of resolvedHTML: String) throws -> Data {
        let marker = "base64,"
        let start = try XCTUnwrap(resolvedHTML.range(of: marker)).upperBound
        let end = try XCTUnwrap(resolvedHTML.range(of: "\"", range: start..<resolvedHTML.endIndex)).lowerBound
        return try XCTUnwrap(Data(base64Encoded: String(resolvedHTML[start..<end])))
    }

    /// An uncompressed TIFF, so the file on disk really is over the cap and
    /// ImageIO really can decode it. A solid-colour PNG compresses to nothing.
    @discardableResult
    private func writeBigTIFF(named name: String, width: Int, height: Int) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(rep.representation(
            using: .tiff,
            properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.none.rawValue]
        ))
        XCTAssertGreaterThan(data.count, MarkdownRenderer.inlineImageByteLimit,
                             "the fixture is not over the cap")
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeImage(
        named name: String,
        type: NSBitmapImageRep.FileType,
        side: Int
    ) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()

        let url = root.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: type, properties: [:])).write(to: url)
        return url
    }

    func testPNGIsInlined() throws {
        try writePNG(named: "square.png", in: root)
        XCTAssertTrue(resolved("square.png").contains("data:image/png;base64,"))
    }

    /// TIFF and HEIC are ordinary on macOS. The hand-written table called them
    /// `application/octet-stream`, which paid the whole read for a payload no
    /// engine decodes — and lost the `file://` fallback on the way.
    func testTIFFIsInlinedWithItsRealType() throws {
        _ = try writeImage(named: "scan.tiff", type: .tiff, side: 8)
        XCTAssertTrue(resolved("scan.tiff").contains("data:image/tiff;base64,"),
                      "TIFF was not given its own type")
    }

    /// A type the system does not know, and a type that is not an image, both
    /// stay as URLs rather than becoming an undecodable `data:` payload.
    func testNonImageAndUnknownTypesAreNotInlined() throws {
        try Data("nope".utf8).write(to: root.appendingPathComponent("blob.zzqq"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("data.json"))

        let unknown = resolved("blob.zzqq")
        XCTAssertFalse(unknown.contains("data:"), "an unknown type was inlined: \(unknown)")
        XCTAssertTrue(unknown.hasPrefix("<img src=\"file://"))

        let json = resolved("data.json")
        XCTAssertFalse(json.contains("data:"), "a non-image was inlined: \(json)")
    }

    func testMissingFileStaysAFileURL() {
        let value = resolved("absent.png")
        XCTAssertFalse(value.contains("data:"))
        XCTAssertTrue(value.contains("file://"))
        XCTAssertTrue(value.contains("absent.png"))
    }

    // MARK: - Renditions above the cap

    /// Under the cap the original travels byte for byte: a screenshot in the
    /// preview is pixel for pixel what it is on disk.
    func testUnderCapImageIsInlinedByteForByte() throws {
        PreviewImageCache.shared.removeAll()
        let url = try writePNG(named: "square.png", in: root, side: 24)
        let onDisk = try Data(contentsOf: url)

        let value = resolved("square.png")
        XCTAssertTrue(value.contains("data:image/png;base64,"))
        XCTAssertEqual(try payload(of: value), onDisk, "the original was re-encoded")
    }

    /// Past the cap the image is no longer given up on: it comes back as a
    /// downscaled JPEG rendition, and the URL is never left as `file://`.
    func testOversizeImageBecomesAJPEGRendition() throws {
        PreviewImageCache.shared.removeAll()
        let url = try writeBigTIFF(named: "scan.tiff", width: 3200, height: 800)
        let onDisk = try Data(contentsOf: url).count

        let value = resolved("scan.tiff")
        XCTAssertTrue(value.contains("data:image/jpeg;base64,"),
                      "an image past the cap did not produce a rendition: \(value.prefix(120))")
        XCTAssertFalse(value.contains("file://"), "the broken-image fallback is still there")
        let rendition = try payload(of: value)
        XCTAssertLessThan(rendition.count, onDisk / 4, "the rendition is not actually smaller")

        let image = try XCTUnwrap(NSBitmapImageRep(data: rendition))
        XCTAssertEqual(image.pixelsWide, PreviewImageRendition.Target.screen.maxPixelSize,
                       "the screen rendition was not capped at its target size")
    }

    /// Print and export ask for a wider rendition than the screen needs — same
    /// call, another number — and the two must not collide in the cache.
    func testPrintRenditionIsWiderThanTheScreenOne() throws {
        PreviewImageCache.shared.removeAll()
        try writeBigTIFF(named: "wide.tiff", width: 3200, height: 800)

        let screen = try XCTUnwrap(NSBitmapImageRep(data: try payload(of: resolved("wide.tiff"))))
        let printed = try XCTUnwrap(NSBitmapImageRep(
            data: try payload(of: resolved("wide.tiff", target: .print))
        ))
        XCTAssertEqual(screen.pixelsWide, PreviewImageRendition.Target.screen.maxPixelSize)
        XCTAssertEqual(printed.pixelsWide, PreviewImageRendition.Target.print.maxPixelSize)
        XCTAssertGreaterThan(printed.pixelsWide, screen.pixelsWide)
    }

    /// The target size is part of the key, so the screen rendition can never
    /// be served where the wide one was asked for. Under the cap the payload
    /// does not depend on the target, and one entry serves both.
    func testCacheKeyDistinguishesTheTwoTargetSizes() throws {
        let big = try writeBigTIFF(named: "keyed.tiff", width: 3200, height: 800)
        let screenKey = try XCTUnwrap(PreviewImageRendition.descriptor(for: big, target: .screen)).cacheKey
        let printKey = try XCTUnwrap(PreviewImageRendition.descriptor(for: big, target: .print)).cacheKey
        XCTAssertNotEqual(screenKey, printKey)

        let small = try writePNG(named: "small.png", in: root, side: 24)
        let smallScreen = try XCTUnwrap(PreviewImageRendition.descriptor(for: small, target: .screen))
        let smallPrint = try XCTUnwrap(PreviewImageRendition.descriptor(for: small, target: .print))
        XCTAssertEqual(smallScreen.cacheKey, smallPrint.cacheKey)
        XCTAssertFalse(smallScreen.isRendition)
    }

    // MARK: - Nothing is read on the calling thread

    /// The first pass reads no bytes at any size: the element keeps its
    /// `file://` URL and a marker, and the payload is reported as deferred.
    func testFirstPassDefersEveryImageInsteadOfReadingIt() throws {
        PreviewImageCache.shared.removeAll()
        try writePNG(named: "square.png", in: root, side: 24)
        try writeBigTIFF(named: "scan.tiff", width: 3200, height: 800)

        let html = "<img src=\"square.png\"><img src=\"scan.tiff\">"
        let first = MarkdownRenderer.resolve(html, base: root, target: .screen)
        XCTAssertEqual(first.deferred.count, 2)
        XCTAssertFalse(first.html.contains("data:"), "an image was read during the first pass")
        XCTAssertTrue(first.html.contains(MarkdownRenderer.deferredImageAttribute))
        XCTAssertEqual(Set(first.deferred.map(\.id)).count, 2, "the markers are not unique")

        let built = MarkdownRenderer.buildDeferredImages(first.deferred)
        XCTAssertEqual(built.count, 2)

        let warm = MarkdownRenderer.resolve(html, base: root, target: .screen)
        XCTAssertTrue(warm.deferred.isEmpty, "a warm cache still deferred")
        XCTAssertFalse(warm.html.contains(MarkdownRenderer.deferredImageAttribute))
        XCTAssertTrue(warm.html.contains("data:image/png;base64,"))
        XCTAssertTrue(warm.html.contains("data:image/jpeg;base64,"))
    }

    /// A missing file, a non-image and a type ImageIO cannot decode are never
    /// deferred: there is nothing to build, and they fall back as they did.
    func testUndecodableAndAbsentFilesAreNotDeferred() throws {
        PreviewImageCache.shared.removeAll()
        try Data(count: MarkdownRenderer.inlineImageByteLimit + 1024)
            .write(to: root.appendingPathComponent("bogus.png"))

        let html = "<img src=\"absent.png\"><img src=\"data.json\">"
        try Data("{}".utf8).write(to: root.appendingPathComponent("data.json"))
        let first = MarkdownRenderer.resolve(html, base: root, target: .screen)
        XCTAssertTrue(first.deferred.isEmpty, "a file with no payload was deferred")
        XCTAssertFalse(first.html.contains(MarkdownRenderer.deferredImageAttribute))

        // Over the cap, right extension, not an image: the rendition fails and
        // the element keeps the URL it already carries rather than going blank.
        let bogus = resolved("bogus.png")
        XCTAssertFalse(bogus.contains("data:"), "an undecodable payload was inlined")
        XCTAssertTrue(bogus.contains("file://"))
    }

    /// Memoized, but keyed on what the file is now: an image edited on disk
    /// must not stay frozen at the version the preview first saw.
    func testInliningIsMemoizedAndInvalidatedByAnEdit() throws {
        PreviewImageCache.shared.removeAll()
        try writePNG(named: "square.png", in: root, side: 24)

        let first = resolved("square.png")
        let second = resolved("square.png")
        XCTAssertEqual(first, second, "the same file rendered two different payloads")
        XCTAssertTrue(first.contains("data:image/png;base64,"))

        // A different image at the same path: different bytes, different size.
        try writePNG(named: "square.png", in: root, side: 40)
        let third = resolved("square.png")
        XCTAssertTrue(third.contains("data:image/png;base64,"))
        XCTAssertNotEqual(third, first, "the edited image came back from the cache")
    }

    // MARK: - An export cannot lose an image to an eviction

    /// The regression: the export path used to build the payloads and then
    /// throw them away, recovering each one from `PreviewImageCache` on a
    /// second `resolve`. That cache is an `NSCache` with a 64 MiB ceiling, so
    /// a photo-heavy note — or any note under memory pressure — could have its
    /// entries evicted between the build and the read, and the PDF was written
    /// with a dead `file://` src and no error at all. Here the eviction is
    /// forced; the document must still carry every payload.
    func testExportKeepsItsImagesWhenTheCacheEvictsAfterTheBuild() throws {
        PreviewImageCache.shared.removeAll()
        try writePNG(named: "square.png", in: root, side: 24)
        try writeBigTIFF(named: "scan.tiff", width: 3200, height: 800)

        let html = "<img src=\"square.png\"><img src=\"scan.tiff\">"
        let first = MarkdownRenderer.resolve(html, base: root, target: .print)
        XCTAssertEqual(first.deferred.count, 2)

        let built = MarkdownRenderer.buildDeferredImages(first.deferred)
        XCTAssertEqual(built.count, 2)

        // Everything the background pass just built, gone.
        PreviewImageCache.shared.removeAll()

        // What the export path does now: the payloads it holds, substituted
        // into the document that reported them. A second `resolve` here — the
        // shipped shape this test was written against — leaves both images as
        // `file://` with an inert marker.
        let page = MarkdownRenderer.substituteDeferredImages(in: first.html, with: built)

        XCTAssertFalse(page.contains(MarkdownRenderer.deferredImageAttribute),
                       "the exported page still carries a marker nothing will swap")
        XCTAssertFalse(page.contains("file://"),
                       "an image was exported as a file:// URL after an eviction")
        XCTAssertTrue(page.contains("data:image/png;base64,"))
        XCTAssertTrue(page.contains("data:image/jpeg;base64,"))
    }
}
