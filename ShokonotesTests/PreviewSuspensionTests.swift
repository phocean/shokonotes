import XCTest
import AppKit
import WebKit
@testable import Shokonotes

/// What closing the library window does to the preview, and what reopening it
/// has to give back.
///
/// The app stays alive with the window closed — the global shortcuts need it —
/// so nothing releases itself on its own. The `WKWebView` is released by hand,
/// and these tests hold the two halves of that bargain: the web view really
/// goes, and the note really comes back where the reader left it.
@MainActor
final class PreviewSuspensionTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("shokonotes-suspend-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore()
        store.setRoot(root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Harness

    /// A note tall enough that there is somewhere to scroll to.
    private func makeLongNote() throws -> NoteSnapshot {
        let body = (1...400)
            .map { "Paragraph \($0) of a note deliberately taller than its window." }
            .joined(separator: "\n\n")
        let record = try store.createNote(named: "Long", in: root, extension: "md", body: body)
        return try XCTUnwrap(store.snapshot(for: record.url))
    }

    /// Spins the main run loop until `condition` holds, so AppKit gets its
    /// layout passes and WebKit gets to answer.
    private func wait(
        _ timeout: TimeInterval = 20,
        until condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return condition()
    }

    private func innerWebView(of host: PreviewHostView) -> WKWebView? {
        host.subviews.compactMap { $0 as? WKWebView }.first
    }

    private func evaluate(_ script: String, in host: PreviewHostView) async -> Double? {
        guard let view = innerWebView(of: host) else { return nil }
        return await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: (value as? NSNumber)?.doubleValue)
            }
        }
    }

    /// Waits for a scrollable document to exist in the host's current web view.
    private func waitForScrollableDocument(in host: PreviewHostView) async -> Bool {
        for _ in 0..<200 {
            if host.isAttached,
               let height = await evaluate("document.body.scrollHeight", in: host),
               height > 800 {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    // MARK: - The .zero rule survives

    /// A host with no usable bounds must not build a web view. That rule is
    /// what the reopen path routes *around* — through `pending` and `layout()`
    /// — rather than through, and neither suspending nor resuming may weaken it.
    func testSuspendAndResumeNeverBuildAWebViewWithoutBounds() throws {
        let host = PreviewHostView(frame: .zero)
        let note = try makeLongNote()

        host.show(note)
        XCTAssertFalse(host.isAttached, "a WKWebView was created at .zero")

        host.suspend()
        XCTAssertTrue(host.suspended)
        XCTAssertFalse(host.isAttached)

        host.resume()
        XCTAssertFalse(host.suspended)
        XCTAssertFalse(
            host.isAttached,
            "resume built a web view at .zero instead of waiting for a real size"
        )
    }

    /// While suspended, a note arriving from the list is remembered rather than
    /// rendered: no window is on screen to render it into.
    func testANoteChosenWhileSuspendedIsHeldRatherThanRendered() throws {
        let host = PreviewHostView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let note = try makeLongNote()

        host.suspend()
        host.show(note)
        XCTAssertFalse(host.isAttached, "a suspended host built a web view for a note nobody can see")

        host.resume()
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.isAttached, "the held note was never built after the window came back")
    }

    // MARK: - The web view is really released, and really comes back

    /// Closing the window releases the web view; reopening rebuilds it on the
    /// same note, with the reader where they were.
    func testSuspendReleasesTheWebViewAndResumeRestoresTheScrollPosition() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = PreviewHostView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView = host
        defer { window.contentView = nil }

        let note = try makeLongNote()
        host.show(note)
        XCTAssertTrue(host.isAttached, "a host with real bounds should attach immediately")

        let ready = await waitForScrollableDocument(in: host)
        XCTAssertTrue(ready, "the preview document never became scrollable")

        _ = await evaluate("(window.scrollTo(0, 300), window.scrollY)", in: host)
        let offset = await evaluate("window.scrollY", in: host)
        XCTAssertEqual(offset ?? 0, 300, accuracy: 2, "the document never scrolled")

        // The window closes.
        host.suspend()
        let released = await wait { !host.isAttached }
        XCTAssertTrue(released, "the web view outlived the window that showed it")
        XCTAssertTrue(host.suspended)

        // The window comes back. The rebuild goes through a layout pass, which
        // AppKit issues for a window on screen; the test asks for it directly
        // rather than depending on a window it never ordered front.
        host.resume()
        XCTAssertFalse(host.suspended)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.isAttached, "the preview never came back after the window reopened")

        let rebuilt = await waitForScrollableDocument(in: host)
        XCTAssertTrue(rebuilt, "the rebuilt document never became scrollable")

        var back: Double?
        for _ in 0..<60 {
            back = await evaluate("window.scrollY", in: host)
            if let back, abs(back - 300) < 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(
            back ?? 0, 300, accuracy: 2,
            "the reading position was lost across a close and a reopen"
        )
    }
}
