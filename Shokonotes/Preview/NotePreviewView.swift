import SwiftUI
import AppKit
import WebKit

struct NotePreviewView: NSViewRepresentable {
    let note: NoteSnapshot?
    var style: PreviewStyle = .default
    var findQuery: String = ""

    func makeNSView(context: Context) -> PreviewHostView {
        PreviewHostView()
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.style = style
        nsView.findQuery = findQuery
        nsView.show(note)
        PreviewBridge.shared.host = nsView
    }
}

/// Whether `show` should run in-page find. `window.find` wrap-arounds from
/// the current selection, so a SwiftUI refresh of the same document hops
/// the highlight unless the query itself changed. A new document waits
/// for `didFinish`, which searches the loaded page once.
enum PreviewFindPolicy {
    static func shouldSearchOnShow(documentChanged: Bool, queryChanged: Bool) -> Bool {
        !documentChanged && queryChanged
    }
}

@MainActor
final class PreviewBridge {
    static let shared = PreviewBridge()
    weak var host: PreviewHostView?

    func scroll(deltaY: CGFloat) { host?.scroll(by: deltaY) }
    func page(down: Bool) { host?.page(down: down) }
    func findNext() { host?.find(backwards: false) }
    func findPrevious() { host?.find(backwards: true) }

    /// Runs the find without waiting for SwiftUI to push the query down, and
    /// reports whether anything matched.
    func find(_ query: String, backwards: Bool, found: ((Bool) -> Void)? = nil) {
        host?.findQuery = query
        host?.find(backwards: backwards, found: found)
    }

    /// The find bar listens here for "No results" so a keystroke does not
    /// have to run `window.find` a second time — that wrap-around would
    /// skip the hit the host just landed on.
    var onFindResult: ((Bool) -> Void)?

    func becomeFirstResponder() { host?.window?.makeFirstResponder(host) }

    /// The library window is closing. The app stays alive for the two global
    /// shortcuts, so nothing else is released — but the `WKWebView` behind this
    /// bridge costs three WebKit helper processes for a document nobody can
    /// see, and those go. `detach()` is `private` to the host; this is the door
    /// AppKit already uses into the preview, so it is the door this takes.
    func suspend() { host?.suspend() }

    /// The window is back. Re-attaches through the host's own `pending` +
    /// `layout()` path, which is what keeps the web view from being created
    /// before the view has a real size.
    func resume() { host?.resume() }
}

/// Hosts the WebKit preview and waits until it has a real size before creating
/// the web view. WKWebView created at `.zero` never paints.
final class PreviewHostView: NSView, WKNavigationDelegate {
    var style = PreviewStyle.default
    var findQuery = ""
    /// The appearance is read from the view, not handed down from SwiftUI. A
    /// SwiftUI body is only re-evaluated when something it observes publishes,
    /// and the system's light / dark switch publishes nothing: the appearance
    /// arrived as an ordinary `Bool`, so the page kept the theme it was built
    /// with. AppKit does notify — `viewDidChangeEffectiveAppearance` — and the
    /// view that owns the document is the right place to hear it.
    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    private var webView: WKWebView?
    /// The note on screen, kept so the document can be rebuilt for a new theme
    /// without SwiftUI having to push it again.
    private var shownNote: NoteSnapshot?
    private var shownURL: URL?
    private var shownModified: Date?
    private var shownTheme: String?
    private var pending: NoteSnapshot?
    private var pendingFind = ""
    /// The query last handed to `window.find`. A SwiftUI refresh with the
    /// same string must not search again; a different string must.
    private var appliedFindQuery: String?
    /// The navigation the currently shown note started. The web view outlives a
    /// note change now, so a load fired for note A can finish after B has been
    /// asked for; anything that is not this navigation is stale and ignored.
    private var currentNavigation: WKNavigation?
    /// Bumped on every `load`. A rendition that finishes building after the
    /// document it belongs to has been replaced is dropped rather than painted
    /// into somebody else's page.
    private var renditionGeneration = 0
    /// True from the moment the window starts closing until it comes back.
    /// While it is set, nothing re-creates the web view — otherwise the very
    /// next layout pass would rebuild what the close just released.
    private(set) var suspended = false
    /// Whether a web view — and therefore a set of WebKit helper processes —
    /// currently exists behind this host.
    var isAttached: Bool { webView != nil }
    /// Set while the scroll offset is being read out of a document that is
    /// about to be thrown away. Guards a teardown that must happen exactly
    /// once, whether the read answers or the deadline does.
    private var suspending = false
    /// Where the reader was, carried across a teardown and re-applied when the
    /// rebuilt document finishes loading. The note's URL travels with it: if a
    /// different note is showing by the time the window comes back, the offset
    /// belongs to a document that is no longer on screen and is dropped.
    private var restoreScroll: (url: URL, y: Double)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizesSubviews = true
        PreviewBridge.shared.host = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if let pending, hasUsableBounds, !suspended {
            attach(pending)
        }
    }

    /// The system switched between light and dark, or the window's appearance
    /// changed. The web view is kept — the page is rebuilt in it, which is the
    /// same work a theme change in Settings does.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
        guard let shownNote, webView != nil else { return }
        // `show` compares the theme key and reloads when it differs, so the
        // appearance change goes through exactly one path.
        show(shownNote)
    }

    func show(_ note: NoteSnapshot?) {
        PreviewBridge.shared.host = self
        guard let note else {
            pending = nil
            shownNote = nil
            shownURL = nil
            shownModified = nil
            detach()
            return
        }
        shownNote = note

        applyChrome()
        let themeKey = "\(style.cacheKey)-\(isDark)"
        // A note change is a new document in the same web view, not a new web
        // view: `loadHTMLString` replaces the document, which is what drops the
        // previous note's scroll position, text selection and find state. The
        // 683 KiB highlighter lives in the configuration and survives, instead
        // of being handed to JavaScriptCore again on every click in the list.
        if let webView {
            let documentChanged =
                shownURL != note.url || note.modifiedAt != shownModified || shownTheme != themeKey
            if documentChanged {
                shownURL = note.url
                shownModified = note.modifiedAt
                shownTheme = themeKey
                load(note, into: webView)
            }
            // Same document: search only when the query changed. The previous
            // `else { applyFind() }` ran `window.find` on every SwiftUI
            // refresh and hopped the highlight. A load still in flight is a
            // document change: `didFinish` searches once against the new page.
            if PreviewFindPolicy.shouldSearchOnShow(
                documentChanged: documentChanged || currentNavigation != nil,
                queryChanged: findQuery != appliedFindQuery
            ) {
                applyFind()
            }
            return
        }

        // A note selected while the window is closed is remembered, not built:
        // `resume()` asks for the layout pass that turns `pending` into a
        // document, once the view is on screen at a real size again.
        if hasUsableBounds, !suspended {
            attach(note)
        } else {
            pending = note
        }
    }

    /// Releases the web view — and with it the WebKit helper processes — while
    /// keeping everything the window needs to come back looking the same: the
    /// shown note, the find query, and the reading position.
    ///
    /// The scroll offset has to be read out of the live document before it
    /// goes, and `evaluateJavaScript` answers asynchronously while the window
    /// is already closing. So the teardown is what the answer triggers, with a
    /// deadline behind it: if the web process does not reply, the view is
    /// released anyway and only the reading position is lost. Releasing it is
    /// the point; the position is the refinement.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        suspending = true
        guard let webView, let url = shownURL else {
            finishSuspend()
            return
        }
        webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            guard let self, self.suspending else { return }
            if let y = (value as? NSNumber)?.doubleValue, y > 0 {
                self.restoreScroll = (url, y)
            }
            self.finishSuspend()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.finishSuspend()
        }
    }

    private func finishSuspend() {
        guard suspending else { return }
        suspending = false
        // `detach()` nils the web view and the theme key but leaves `shownNote`
        // set, and `show()` is only re-entered when SwiftUI re-evaluates — which
        // a window reopen does not promise. `pending` is what `layout()` reads,
        // so the note is put back there by hand.
        detach()
        pending = shownNote
    }

    /// The window is on screen again. Asks for a layout pass rather than
    /// attaching here: `attach()` is gated on `hasUsableBounds`, and that gate
    /// is the rule that keeps a `WKWebView` from ever being created at `.zero`.
    func resume() {
        guard suspended else { return }
        suspended = false
        suspending = false
        guard webView == nil else { return }
        if pending == nil { pending = shownNote }
        if pending != nil { needsLayout = true }
    }

    func scroll(by deltaY: CGFloat) {
        webView?.evaluateJavaScript("window.scrollBy(0, \(Int(deltaY)));", completionHandler: nil)
    }

    func page(down: Bool) {
        webView?.evaluateJavaScript(
            "window.scrollBy(0, window.innerHeight * \(down ? 0.9 : -0.9));",
            completionHandler: nil
        )
    }

    func find(backwards: Bool = false, found: ((Bool) -> Void)? = nil) {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        appliedFindQuery = findQuery
        guard let webView, !query.isEmpty else {
            reportFindResult(true, to: found)
            return
        }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // The last argument is wrap-around, which is what makes the search
        // circular; the search starts from the current selection.
        webView.evaluateJavaScript(
            "window.find(\"\(escaped)\", false, \(backwards), true);"
        ) { result, _ in
            self.reportFindResult((result as? Bool) ?? false, to: found)
        }
    }

    private func reportFindResult(_ hit: Bool, to found: ((Bool) -> Void)?) {
        found?(hit)
        PreviewBridge.shared.onFindResult?(hit)
    }

    func applyFind() {
        find(backwards: false)
    }

    /// The web view declines first responder so the host can keep the arrow
    /// keys. Edit ▸ Copy still lands here; the DOM selection is read out by
    /// script, which works even though the web view is not first responder.
    @objc func copy(_ sender: Any?) {
        webView?.evaluateJavaScript(PreviewCopy.selectionScript) { value, _ in
            PreviewCopy.write(value as? String ?? "")
        }
    }

    private var hasUsableBounds: Bool {
        bounds.width > 8 && bounds.height > 8
    }

    private func attach(_ note: NoteSnapshot) {
        pending = nil
        detach()

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let script = PreviewCodeTheme.highlightScript()
        if !script.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        // Live preview only. Print and PDF share the highlighter, not the
        // fenced-block Copy button.
        configuration.userContentController.addUserScript(PreviewCopy.liveUserScript())

        let view = PreviewWebView(frame: bounds, configuration: configuration)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        addSubview(view)
        webView = view
        shownURL = note.url
        shownModified = note.modifiedAt
        shownTheme = "\(style.cacheKey)-\(isDark)"
        applyChrome()
        load(note, into: view)
    }

    private func applyChrome() {
        wantsLayer = true
        if let color = style.theme.hostBackground(isDark: isDark) {
            layer?.backgroundColor = color.cgColor
            webView?.setValue(true, forKey: "drawsBackground")
            webView?.underPageBackgroundColor = color
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            webView?.setValue(false, forKey: "drawsBackground")
            webView?.underPageBackgroundColor = .clear
        }
    }

    private func load(_ note: NoteSnapshot, into view: WKWebView?) {
        guard let view else { return }
        pendingFind = findQuery
        // The body comes from the snapshot, front matter already removed: the
        // note was read from disk when it was indexed, and reading it again
        // here would block the main thread on every click in the list.
        let html = MarkdownRenderer.html(
            from: note.rawBody,
            title: note.title,
            themeCSS: style.theme.syntaxCSS(isDark: isDark),
            style: style
        )
        // Cache hits are inlined here; anything that would have to be read or
        // encoded keeps its `file://` URL and a marker, and lands later.
        let resolution = MarkdownRenderer.resolve(html, base: note.folderURL, target: .screen)
        renditionGeneration &+= 1
        currentNavigation = view.loadHTMLString(resolution.html, baseURL: note.folderURL)
        buildRenditions(resolution.deferred, for: view, generation: renditionGeneration)
    }

    /// Builds the missing image payloads off the main thread and swaps each
    /// `src` into the **live** document as it lands. Deliberately not a
    /// reload: `loadHTMLString` is what drops scroll position, text selection
    /// and find state, and a note whose images arrive a moment later must not
    /// pay that. A document that has been replaced since — another note,
    /// another theme — bumps the generation, and its stragglers are dropped.
    private func buildRenditions(
        _ deferred: [MarkdownRenderer.DeferredImage],
        for view: WKWebView,
        generation: Int
    ) {
        guard !deferred.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
            for item in deferred {
                guard let uri = PreviewImageRendition.payload(for: item.descriptor) else { continue }
                DispatchQueue.main.async {
                    guard let self, let view, self.webView === view,
                          self.renditionGeneration == generation else { return }
                    view.evaluateJavaScript(
                        Self.swapScript(id: item.id, uri: uri),
                        completionHandler: nil
                    )
                }
            }
        }
    }

    /// Finds the one element the marker names and replaces its source. The
    /// marker is removed with it, so a second swap cannot hit the same node.
    private static func swapScript(id: String, uri: String) -> String {
        let attribute = MarkdownRenderer.deferredImageAttribute
        return """
        (function(){var e=document.querySelector('[\(attribute)=' + \(jsString(id)) + ']');\
        if(e){e.setAttribute('src', \(jsString(uri)));e.removeAttribute('\(attribute)');}})();
        """
    }

    /// A JavaScript string literal. A base64 `data:` URI carries none of these
    /// characters, but the payload is built from whatever is on disk and this
    /// is the one place where it becomes code.
    private static func jsString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 8)
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\u{2028}": escaped += "\\u2028"
            case "\u{2029}": escaped += "\\u2029"
            case "<": escaped += "\\u003C"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private func detach() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        currentNavigation = nil
        shownTheme = nil
    }

    /// Puts the reader back where the window closed on them. Consumed whether
    /// or not it applies: an offset is only ever good for the one document it
    /// was read from, so it never survives to a second load.
    ///
    /// It runs before `applyFind()`, which gets the last word — a find that is
    /// still open re-highlights its match and scrolls to it, which is what a
    /// find bar is for.
    private func restorePendingScroll(in webView: WKWebView) {
        guard let restore = restoreScroll else { return }
        restoreScroll = nil
        guard restore.url == shownURL else { return }
        webView.evaluateJavaScript("window.scrollTo(0, \(Int(restore.y)));", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A load that finished after its note stopped being the shown one has
        // nothing left to say: applying the find would search the wrong page.
        guard webView === self.webView else { return }
        guard currentNavigation == nil || navigation === currentNavigation else { return }
        currentNavigation = nil
        restorePendingScroll(in: webView)
        applyFind()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 126: scroll(by: flags.contains(.option) ? -240 : -48)
        case 125: scroll(by: flags.contains(.option) ? 240 : 48)
        case 49: page(down: !flags.contains(.shift))
        case 123:
            NotificationCenter.default.post(name: LibraryWindowController.previewWantsNotesFocus, object: nil)
        default:
            super.keyDown(with: event)
        }
    }
}

private final class PreviewWebView: WKWebView {
    /// Declined so the host view keeps the arrow keys it scrolls with.
    override var acceptsFirstResponder: Bool { false }

    /// Which is why the click has to move the keyboard by hand — and say so, so
    /// that ⌘F knows it is now the note that is being searched.
    override func mouseDown(with event: NSEvent) {
        if let host = superview as? PreviewHostView {
            window?.makeFirstResponder(host)
            NotificationCenter.default.post(name: LibraryWindowController.previewTookFocus, object: nil)
        }
        super.mouseDown(with: event)
    }
}
