import SwiftUI
import UIKit
import WebKit

/// Duplicated from the Mac preview host: that file is AppKit and is not
/// compiled for iOS. `window.find` wrap-arounds, so an unchanged SwiftUI
/// refresh must not search again.
enum PreviewFindPolicy {
    static func shouldSearchOnShow(documentChanged: Bool, queryChanged: Bool) -> Bool {
        !documentChanged && queryChanged
    }
}

struct NoteReaderView: View {
    let url: URL
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var showTags = false
    @State private var showMove = false
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findMissing = false
    @State private var findStep: UInt = 0
    @State private var findBackwards = false
    @FocusState private var findFocused: Bool
    @State private var findDidFocus = false
    @StateObject private var dictation = DictationController()

    var body: some View {
        Group {
            if let note {
                VStack(alignment: .leading, spacing: 0) {
                    if !note.tags.isEmpty {
                        chipRow(note)
                    }
                    NotePreviewWebView(
                        note: note,
                        style: settings.previewStyle,
                        findQuery: findVisible ? findQuery : "",
                        findStep: findStep,
                        findBackwards: findBackwards,
                        onFindResult: { found in
                            let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            findMissing = !found && !query.isEmpty
                        },
                        bottomContentInset: IOSBottomBarMetrics.barHeight
                    )
                    // The compose button floats: the text keeps scrolling
                    // behind it instead of stopping at the top of a band.
                    // Reaching under the bar is only half of it — the web
                    // view is told the same height as a scroll inset just
                    // above, so the last line of the note can be scrolled
                    // clear of the pencil and read.
                    .ignoresSafeArea(.container, edges: .bottom)
                }
                .background(Color(uiColor: .systemBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .navigationTitle(note.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    readerToolbar(note)
                }
                .sheet(isPresented: $showTags) {
                    IOSTagsSheet(url: note.url, library: library)
                }
                .sheet(isPresented: $showMove) {
                    IOSMoveSheet(url: note.url, library: library, onRelocated: {
                        session.popNoteIfTop(url)
                    })
                }
            } else {
                ContentUnavailableView("No notes", systemImage: "note.text")
            }
        }
    }

    private var note: NoteSnapshot? {
        library.note(with: url)
    }

    @ViewBuilder
    private func chipRow(_ note: NoteSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(note.tags, id: \.self) { tag in
                    Button {
                        showTags = true
                    } label: {
                        IOSTagChip(
                            name: tag,
                            isActive: IOSTagChip.isActive(tag, filters: library.selectedTags)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// One trailing item per control so iOS 26 cannot overflow icon-only
    /// actions into an empty "…" row. Labels travel with the overflow menu.
    @ToolbarContentBuilder
    private func readerToolbar(_ note: NoteSnapshot) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ShareLink(item: note.url, preview: SharePreview(note.title)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                library.togglePin([note])
            } label: {
                Label(
                    note.isPinned ? "Unpin" : "Pin",
                    systemImage: note.isPinned ? "pin.fill" : "pin"
                )
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showTags = true
            } label: {
                Label("Tags", systemImage: "tag")
            }
        }
        if note.isTrashed {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    relocateThen { library.restore([$0]) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMove = true
                } label: {
                    Label("Move", systemImage: "folder")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    relocateThen { library.delete([$0]) }
                } label: {
                    Label("Trash", systemImage: "trash")
                }
            }
        }
    }

    /// The reader's bottom bar: same `IOSBottomBar` as the list. At rest,
    /// Find and Compose, trailing-aligned.
    private var bottomBar: some View {
        IOSBottomBar {
            if findVisible {
                findControls
            } else {
                Spacer()
                IOSBottomBarCircleButton(systemImage: "magnifyingglass") {
                    openFind()
                }
                .accessibilityLabel("Find in Note")
                IOSBottomBarComposeButton(session: session)
            }
        }
        .onChange(of: findFocused) { _, focused in
            if focused {
                findDidFocus = true
                return
            }
            guard findVisible, findDidFocus, findQueryIsEmpty else { return }
            closeFind()
        }
    }

    /// Open, Find takes **the lists' capsule** — same height, same margins,
    /// same leading glyph, same dictation mic inside it. What it does not
    /// share is what a note needs and a list does not: previous, next, and a
    /// way out. Those three ride beside the capsule, as round controls of the
    /// same diameter; nothing here invents a second scale.
    @ViewBuilder
    private var findControls: some View {
        IOSSearchCapsule(
            text: findBinding,
            placeholder: String(localized: "Find in Note"),
            focus: $findFocused,
            onSubmit: { stepFind(backwards: false) }
        ) {
            if findMissing, !findQueryIsEmpty {
                Text("No results")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            IOSDictationMicButton(dictation: dictation) { transcript in
                findQuery = transcript
            }
        }
        IOSBottomBarCircleButton(systemImage: "chevron.up") {
            stepFind(backwards: true)
        }
        .accessibilityLabel("Find Previous")
        .disabled(findQueryIsEmpty)
        IOSBottomBarCircleButton(systemImage: "chevron.down") {
            stepFind(backwards: false)
        }
        .accessibilityLabel("Find Next")
        .disabled(findQueryIsEmpty)
        IOSBottomBarDoneButton {
            closeFind()
        }
    }

    private var findQueryIsEmpty: Bool {
        findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Typing clears "No results"; dictation writes `findQuery` directly and
    /// is stopped here only by a genuine keystroke, as on the lists.
    private var findBinding: Binding<String> {
        Binding(
            get: { findQuery },
            set: { typed in
                if dictation.isRecording { dictation.stop() }
                findQuery = typed
                if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    findMissing = false
                }
            }
        )
    }

    private func openFind() {
        if findQuery.isEmpty {
            findQuery = library.searchText
        }
        findVisible = true
        Task { @MainActor in
            findFocused = true
        }
    }

    private func closeFind() {
        findVisible = false
        findQuery = ""
        findMissing = false
        findFocused = false
        findDidFocus = false
    }

    private func stepFind(backwards: Bool) {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            findMissing = false
            return
        }
        findBackwards = backwards
        findStep += 1
    }

    /// Move, trash and restore change the file URL. Leave the reader first.
    private func relocateThen(_ action: (NoteSnapshot) -> Void) {
        guard let note else { return }
        session.popNoteIfTop(note.url)
        action(note)
    }
}

/// WKWebView has no SwiftUI equivalent. Host waits for a real size; a view
/// created at `.zero` never paints.
struct NotePreviewWebView: UIViewRepresentable {
    let note: NoteSnapshot
    var style: PreviewStyle
    var findQuery: String
    var findStep: UInt
    var findBackwards: Bool
    var onFindResult: ((Bool) -> Void)?
    /// Height of the floating bottom bar this view scrolls under.
    var bottomContentInset: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewHostView {
        let host = PreviewHostView()
        host.style = style
        host.isDark = context.environment.colorScheme == .dark
        host.bottomContentInset = bottomContentInset
        return host
    }

    func updateUIView(_ host: PreviewHostView, context: Context) {
        host.style = style
        host.isDark = context.environment.colorScheme == .dark
        host.bottomContentInset = bottomContentInset
        host.findQuery = findQuery
        host.onFindResult = onFindResult
        host.show(note)
        if context.coordinator.lastStep == nil {
            context.coordinator.lastStep = findStep
        } else if findStep != context.coordinator.lastStep {
            context.coordinator.lastStep = findStep
            host.find(backwards: findBackwards)
        }
    }

    final class Coordinator {
        var lastStep: UInt?
    }
}

final class PreviewHostView: UIView, WKNavigationDelegate {
    var style = PreviewStyle.default
    var isDark = false
    var findQuery = ""
    var onFindResult: ((Bool) -> Void)?
    /// The floating bottom bar's height. This view reaches the bottom of the
    /// screen so the text scrolls behind the button; without this inset the
    /// end of the note would stop under it and could not be read. It *adds*
    /// to the home-indicator inset, which `.automatic` already contributes.
    var bottomContentInset: CGFloat = 0 {
        didSet {
            guard bottomContentInset != oldValue else { return }
            applyScrollInsets()
        }
    }
    private var webView: WKWebView?
    private var shownNote: NoteSnapshot?
    private var shownURL: URL?
    private var shownModified: Date?
    private var shownTheme: String?
    private var pending: NoteSnapshot?
    private var renditionGeneration = 0
    private var currentNavigation: WKNavigation?
    /// The query last handed to in-page find. A SwiftUI refresh with the
    /// same string must not search again; a different string must.
    private var appliedFindQuery: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        clipsToBounds = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PreviewHostView, _) in
            view.applyColorScheme()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let pending, hasUsableBounds {
            attach(pending)
        }
        webView?.frame = bounds
    }

    private func applyColorScheme() {
        let dark = traitCollection.userInterfaceStyle == .dark
        guard dark != isDark else { return }
        isDark = dark
        shownTheme = nil
        if let shownNote {
            show(shownNote)
        }
    }

    func show(_ note: NoteSnapshot) {
        shownNote = note
        let themeKey = "\(style.cacheKey)-\(isDark)"
        if let webView {
            let documentChanged = shownURL != note.url
                || note.modifiedAt != shownModified
                || shownTheme != themeKey
            if documentChanged {
                shownURL = note.url
                shownModified = note.modifiedAt
                shownTheme = themeKey
                load(note, into: webView)
            }
            if PreviewFindPolicy.shouldSearchOnShow(
                documentChanged: documentChanged || currentNavigation != nil,
                queryChanged: findQuery != appliedFindQuery
            ) {
                applyFind()
            }
            return
        }
        if hasUsableBounds {
            attach(note)
        } else {
            pending = note
        }
    }

    private var hasUsableBounds: Bool {
        bounds.width > 8 && bounds.height > 8
    }

    private func attach(_ note: NoteSnapshot) {
        pending = nil
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        currentNavigation = nil
        appliedFindQuery = nil

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let script = PreviewCodeTheme.highlightScript()
        if !script.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }

        let view = WKWebView(frame: bounds, configuration: configuration)
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        view.scrollView.alwaysBounceVertical = true
        addSubview(view)
        webView = view
        applyScrollInsets()
        shownURL = note.url
        shownModified = note.modifiedAt
        shownTheme = "\(style.cacheKey)-\(isDark)"
        load(note, into: view)
    }

    private func load(_ note: NoteSnapshot, into view: WKWebView?) {
        guard let view else { return }
        applyHostChrome()
        let html = MarkdownRenderer.html(
            from: note.rawBody,
            title: note.title,
            themeCSS: style.theme.syntaxCSS(isDark: isDark) + "\n" + Self.phoneCSS,
            style: style
        )
        let resolution = MarkdownRenderer.resolve(html, base: note.folderURL, target: .screen)
        renditionGeneration &+= 1
        currentNavigation = view.loadHTMLString(resolution.html, baseURL: note.folderURL)
        buildRenditions(resolution.deferred, for: view, generation: renditionGeneration)
    }

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

    /// Bottom only. The top inset stays `.automatic`'s.
    private func applyScrollInsets() {
        guard let scrollView = webView?.scrollView else { return }
        scrollView.contentInset.bottom = bottomContentInset
        scrollView.verticalScrollIndicatorInsets.bottom = bottomContentInset
    }

    func applyFind() {
        find(backwards: false)
    }

    func find(backwards: Bool = false, found: ((Bool) -> Void)? = nil) {
        appliedFindQuery = findQuery
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let webView, currentNavigation == nil else {
            return
        }
        if query.isEmpty {
            reportFindResult(true, to: found)
            return
        }
        // `WKWebView.find` highlights without scrolling. `window.find` once,
        // then `scrollIntoView` — a second find wrap-arounds and skips the hit.
        webView.evaluateJavaScript(Self.findScript(query: query, backwards: backwards)) { [weak self] result, _ in
            self?.reportFindResult((result as? Bool) ?? false, to: found)
        }
    }

    private func reportFindResult(_ hit: Bool, to found: ((Bool) -> Void)?) {
        found?(hit)
        onFindResult?(hit)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        guard currentNavigation == nil || navigation === currentNavigation else { return }
        currentNavigation = nil
        applyFind()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func applyHostChrome() {
        if let hex = PreviewThemeCSS.palette(style.theme, isDark: isDark)?.bg,
           let color = UIColor(shokoHex: hex) {
            backgroundColor = color
            webView?.isOpaque = true
            webView?.backgroundColor = color
            webView?.scrollView.backgroundColor = color
        } else {
            backgroundColor = .systemBackground
            webView?.isOpaque = false
            webView?.backgroundColor = .clear
            webView?.scrollView.backgroundColor = .clear
        }
    }

    private static let phoneCSS = """
    @media (max-width: 700px) {
      body { padding: 1.1rem 1.05rem 2.5rem; }
    }
    """

    private static func findScript(query: String, backwards: Bool) -> String {
        """
        (function(q, backwards) {
          var found = window.find(q, false, backwards, true, false, false, false);
          if (found) {
            var sel = window.getSelection();
            if (sel && sel.rangeCount) {
              var node = sel.getRangeAt(0).commonAncestorContainer;
              var el = node.nodeType === 1 ? node : node.parentElement;
              if (el && el.scrollIntoView) el.scrollIntoView({ block: "center", inline: "nearest" });
            }
          }
          return found;
        })(\(jsString(query)), \(backwards ? "true" : "false"))
        """
    }

    private static func swapScript(id: String, uri: String) -> String {
        let attribute = MarkdownRenderer.deferredImageAttribute
        return """
        (function(){var e=document.querySelector('[\(attribute)=' + \(jsString(id)) + ']');\
        if(e){e.setAttribute('src', \(jsString(uri)));e.removeAttribute('\(attribute)');}})();
        """
    }

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
}

private extension UIColor {
    convenience init?(shokoHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
