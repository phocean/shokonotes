import AppKit
import WebKit

/// Loads a note into an off-screen web view at a real page box and hands the
/// view back once the document has laid out. Printing and PDF export share it,
/// so there is one rendering path: what the preview shows, what the printer
/// puts on paper and what the exported file contains are the same document.
@MainActor
final class PreviewPageRenderer: NSObject, WKNavigationDelegate {
    /// US Letter at 96 dpi. Never `.zero` — a web view without a page box
    /// never paints, and an empty page is what that mistake produces.
    static let pageBox = NSRect(x: 0, y: 0, width: 800, height: 1100)

    enum Failure: LocalizedError {
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let reason):
                return reason
            }
        }
    }

    /// Renderers in flight. A load is not attached to any window, so nothing
    /// else keeps one alive between `load` and its callback.
    private static var live: [PreviewPageRenderer] = []

    private var webView: WKWebView?
    private var completion: ((Result<WKWebView, Error>) -> Void)?

    /// Renders `note` the way the preview renders it — same HTML, same theme,
    /// same syntax highlighting — and calls back once the page is ready.
    /// The note is read from the snapshot already in memory; the file on disk
    /// is never opened, and never written.
    static func load(
        _ note: NoteSnapshot,
        completion: @escaping (Result<WKWebView, Error>) -> Void
    ) {
        let style = AppSettings.shared.previewStyle
        let html = MarkdownRenderer.html(
            from: note.rawBody,
            title: note.title,
            themeCSS: style.theme.syntaxCSS(isDark: AppearanceProbe.isDark),
            style: style
        )
        // The wide rendition, not the screen one: a full-page photo prints
        // from more pixels than the pane ever needed.
        let first = MarkdownRenderer.resolve(html, base: note.folderURL, target: .print)
        guard !first.deferred.isEmpty else {
            begin(html: first.html, baseURL: note.folderURL, completion: completion)
            return
        }
        // Unlike the preview there is nothing on screen to swap into, and an
        // export must not hand back a page whose images are still arriving. So
        // the payloads are built first — off the main thread, which is the
        // whole point — and substituted straight into the document that
        // reported them, with no marker and no second paint.
        //
        // They are substituted, not re-resolved: a second `resolve` would look
        // the payloads up in `PreviewImageCache`, an `NSCache` free to evict
        // between the build and the read, and an evicted entry would be
        // written to paper or PDF as a dead `file://` src with no error. The
        // values are already in hand here; the cache is an optimization, never
        // the record.
        DispatchQueue.global(qos: .userInitiated).async {
            let built = MarkdownRenderer.buildDeferredImages(first.deferred)
            let warm = MarkdownRenderer.substituteDeferredImages(in: first.html, with: built)
            DispatchQueue.main.async {
                begin(html: warm, baseURL: note.folderURL, completion: completion)
            }
        }
    }

    private static func begin(
        html: String,
        baseURL: URL,
        completion: @escaping (Result<WKWebView, Error>) -> Void
    ) {
        let renderer = PreviewPageRenderer()
        live.append(renderer)
        renderer.start(html: html, baseURL: baseURL, completion: completion)
    }

    private func start(
        html: String,
        baseURL: URL,
        completion: @escaping (Result<WKWebView, Error>) -> Void
    ) {
        self.completion = completion

        let configuration = WKWebViewConfiguration()
        // The document comes from cmark with `CMARK_OPT_UNSAFE` never set, so
        // no script of the note's own reaches the page. JavaScript is on for
        // one reason: the highlighter the preview injects, so exported code
        // blocks carry the same colours as the ones on screen.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let script = PreviewCodeTheme.highlightScript()
        if !script.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }

        let view = WKWebView(frame: Self.pageBox, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.loadHTMLString(html, baseURL: baseURL)
    }

    private func finish(_ result: Result<WKWebView, Error>) {
        guard let completion else { return }
        self.completion = nil
        // The caller owns the web view from here: whatever it captures keeps
        // the view alive for as long as it needs it.
        completion(result)
        webView?.navigationDelegate = nil
        webView = nil
        Self.live.removeAll { $0 === self }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // One turn of the run loop, so the highlighter that ran at document
        // end has laid out before anything draws from the page.
        DispatchQueue.main.async { [weak self] in
            self?.finish(.success(webView))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }
}
