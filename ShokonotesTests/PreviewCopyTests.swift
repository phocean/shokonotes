import XCTest
import AppKit
import WebKit
@testable import Shokonotes

@MainActor
final class PreviewCopyTests: XCTestCase {

    func testCopySelectionScriptReadsTheDOMSelection() {
        XCTAssertTrue(PreviewCopy.selectionScript.contains("getSelection()"))
        XCTAssertTrue(PreviewCopy.selectionScript.contains("toString()"))
    }

    /// ⌘C must evaluate the named script, not an inline magic string.
    func testHostCopyEvaluatesTheNamedSelectionScript() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shokonotes/Preview/NotePreviewView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("PreviewCopy.selectionScript"))
        XCTAssertFalse(source.contains("getSelection"), "the host must not inline the DOM read")
    }

    func testLiveScriptCopiesInnerTextWithExecCommand() {
        let source = PreviewCopy.userScript(copy: "Copy", copied: "Copied")
        XCTAssertTrue(source.contains("innerText"))
        XCTAssertTrue(source.contains("execCommand"))
        XCTAssertTrue(source.contains("@media print"))
        XCTAssertTrue(source.contains(PreviewCopy.buttonClass))
        XCTAssertFalse(PreviewCodeTheme.highlightScript().contains(PreviewCopy.buttonClass))
    }

    /// The live user script, without highlight.js, plants one button per
    /// fenced `pre` and the same JS function the button clicks writes the
    /// source onto the general pasteboard.
    func testLiveScriptPlantsOneButtonPerPreAndCopies() async throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }

        let html = "<pre><code>let value = 42</code></pre>"
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: PreviewCopy.userScript(copy: "Copy", copied: "Copied"),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        )
        let done = expectation(description: "page loaded")
        let waiter = LoadWaiter { done.fulfill() }
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [done], timeout: 30)

        let count = try await evaluate(
            "document.querySelectorAll('.\(PreviewCopy.buttonClass)').length",
            in: webView
        ) as? Int
        XCTAssertEqual(count, 1, "expected one Copy button per pre")

        let label = try await evaluate(
            "document.querySelector('.\(PreviewCopy.buttonClass)').textContent",
            in: webView
        ) as? String
        XCTAssertEqual(label, "Copy")

        let expected = try await evaluate(
            "document.querySelector('pre code').innerText",
            in: webView
        ) as? String
        pasteboard.clearContents()
        let copied = try await evaluate(
            "\(PreviewCopy.copyBlockFunction)(document.querySelector('pre'))",
            in: webView
        ) as? String
        XCTAssertEqual(copied, expected)
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(_ onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
