import SwiftUI

struct LibraryListView: View {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Regular width, wherever it occurs — iPad, and an iPhone Max/Plus held
    /// in landscape. Compact height (keyboard, landscape iPhone) must not swap
    /// the root from `NavigationStack` to a split — that tears the stack down
    /// mid-push and freezes the window.
    private var usesSplit: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesSplit {
                LibrarySplitView(session: session, library: library)
            } else {
                LibraryStackView(session: session, library: library)
            }
        }
    }
}

/// iPhone: sources → collection → full-screen reader. Landscape stays a stack.
private struct LibraryStackView: View {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel

    var body: some View {
        NavigationStack(path: $session.path) {
            LibrarySourcesView(
                session: session,
                library: library,
                presentsReaderInPlace: false
            )
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .note(let url):
                    NoteReaderView(url: url, session: session, library: library)
                default:
                    LibraryNotesView(
                        route: route,
                        session: session,
                        library: library,
                        presentsReaderInPlace: false
                    )
                }
            }
        }
    }
}

/// Regular width: list stays visible. Tapping a note updates the reader.
private struct LibrarySplitView: View {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel

    var body: some View {
        NavigationSplitView {
            leadingColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var leadingColumn: some View {
        NavigationStack(
            path: Binding(
                get: { session.path.filter(\.isCollection) },
                set: { session.replaceCollections($0) }
            )
        ) {
            LibrarySourcesView(
                session: session,
                library: library,
                presentsReaderInPlace: true
            )
            .navigationDestination(for: LibraryRoute.self) { route in
                if route.isCollection {
                    LibraryNotesView(
                        route: route,
                        session: session,
                        library: library,
                        presentsReaderInPlace: true
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let url = session.selectedNoteURL {
            NavigationStack {
                NoteReaderView(url: url, session: session, library: library)
            }
        } else {
            NavigationStack {
                ContentUnavailableView {
                    Label("Select a note", systemImage: "doc.text")
                }
            }
        }
    }
}

struct LibrarySourcesView: View {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    var presentsReaderInPlace: Bool
    @State private var filing: IOSFilingSheet?
    @State private var permanentDelete: NoteSnapshot?
    @State private var namingFolder = false
    @State private var newFolderName = ""

    private var isSearching: Bool {
        !library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                searchResults
            } else {
                sourcesList
            }
        }
        .navigationTitle(rootTitle)
        .navigationBarTitleDisplayMode(.large)
        .modifier(
            IOSChromeToolbar(
                session: session,
                library: library,
                showsSettings: true,
                onNewFolder: {
                    newFolderName = ""
                    namingFolder = true
                }
            )
        )
        .alert("New Folder", isPresented: $namingFolder) {
            TextField("Name", text: $newFolderName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") { createFolder() }
        } message: {
            Text("Created in your notes folder.")
        }
        .sheet(item: $filing) { item in
            switch item {
            case .tags(let url):
                IOSTagsSheet(url: url, library: library)
            case .move(let url):
                IOSMoveSheet(url: url, library: library)
            }
        }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(
                get: { permanentDelete != nil },
                set: { if !$0 { permanentDelete = nil } }
            ),
            presenting: permanentDelete
        ) { note in
            Button("Delete Permanently", role: .destructive) {
                library.deletePermanently([note])
                permanentDelete = nil
            }
            Button("Cancel", role: .cancel) { permanentDelete = nil }
        } message: { _ in
            Text("\(1) note(s) will be removed from disk. This cannot be undone.")
        }
        .onAppear { session.applyVisibleCollection() }
    }

    /// Create the folder at the library root, and leave the model where this
    /// screen says it is.
    ///
    /// `LibraryModel.createFolder` is written for the Mac sidebar: it creates
    /// inside `creationFolder()` — which reads `sidebarSelection` — and then
    /// writes `sidebarSelection = .project(new)` and `sidebarVisible = true`.
    /// On iOS the truth of navigation is `session.path`, and this screen is
    /// the root: it shows no collection at all. Left alone, the model would
    /// keep pointing at a folder no screen is showing, and the *next* folder
    /// would be created nested inside this one.
    ///
    /// So the selection is stated on both sides of the call, through
    /// `LibraryRoute` (the one writer of `sidebarSelection` on iOS): `.all`
    /// before, so the parent is the library root, and the visible route
    /// after — which on the root screen is `.all` again, the same state the
    /// root already uses while searching. The new folder is not pushed: he
    /// stays on the sources list and sees it appear under Folders, as Notes
    /// does. A duplicate name is refused by the engine, which presents its
    /// own `LibraryError` through `errorPresenter`.
    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        LibraryRoute.all.apply(to: library)
        _ = library.createFolder(named: name)
        LibraryRoute.all.apply(to: library)
        session.applyVisibleCollection()
    }

    /// The library folder's own name, or the app's when no folder is picked.
    private var rootTitle: String {
        let name = library.rootURL?.lastPathComponent ?? ""
        return name.isEmpty ? String(localized: "Shokonotes") : name
    }

    private var sourcesList: some View {
        List {
            Section {
                NavigationLink(value: LibraryRoute.inbox) {
                    Label("Inbox", systemImage: "tray")
                }
                .badge(library.inboxCount)

                NavigationLink(value: LibraryRoute.all) {
                    Label("All Notes", systemImage: "tray.full")
                }

                NavigationLink(value: LibraryRoute.untagged) {
                    Label("Untagged", systemImage: "tag.slash")
                }
            }

            if !library.favourites.isEmpty {
                Section {
                    ForEach(library.favourites, id: \.self) { item in
                        favouriteLink(item)
                    }
                } header: {
                    Text("Favourites")
                }
            }

            if !library.folders.isEmpty {
                Section {
                    OutlineGroup(library.folders, children: \.children) { folder in
                        NavigationLink(value: LibraryRoute.folder(folder.url)) {
                            Label(folder.name, systemImage: folderSystemImage(folder.symbol))
                        }
                    }
                } header: {
                    Text("Folders")
                }
            }

            if !library.tagCounts.isEmpty {
                Section {
                    ForEach(library.tagCounts) { item in
                        NavigationLink(value: LibraryRoute.tag(item.name)) {
                            Label(item.name, systemImage: "tag")
                        }
                        .badge(item.count)
                    }
                } header: {
                    Text("Tags")
                }
            }

            Section {
                NavigationLink(value: LibraryRoute.trash) {
                    Label("Trash", systemImage: "trash")
                }
                .badge(library.trashCount)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var searchResults: some View {
        List {
            Section {
                ForEach(library.notes) { note in
                    IOSNoteNavigationRow(
                        note: note,
                        session: session,
                        library: library,
                        presentsReaderInPlace: presentsReaderInPlace,
                        onTags: { filing = .tags(note.url) },
                        onMove: { filing = .move(note.url) },
                        onDeleteForever: { permanentDelete = note }
                    )
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.notes.isEmpty {
                ContentUnavailableView.search(text: library.searchText)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func favouriteLink(_ item: Favourite) -> some View {
        switch item {
        case .folder(let path):
            let url = favouriteFolderURL(path)
            let folder = library.folder(with: url)
            NavigationLink(value: LibraryRoute.folder(folder?.url ?? url)) {
                Label(
                    folder?.name ?? item.displayName,
                    systemImage: folderSystemImage(folder?.symbol)
                )
            }
        case .tag(let name):
            NavigationLink(value: LibraryRoute.tag(name)) {
                Label(name, systemImage: "tag")
            }
        case .note(let path):
            if let note = library.note(relativePath: path) {
                if presentsReaderInPlace {
                    Button {
                        session.selectNote(note.url)
                    } label: {
                        Label(note.title, systemImage: "note.text")
                    }
                    .tint(.primary)
                } else {
                    NavigationLink(value: LibraryRoute.note(note.url)) {
                        Label(note.title, systemImage: "note.text")
                    }
                }
            } else {
                Label(item.displayName, systemImage: "note.text")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func favouriteFolderURL(_ path: String) -> URL {
        guard let root = library.rootURL else {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private func folderSystemImage(_ symbol: String?) -> String {
        let name = symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "folder" : name
    }
}

struct LibraryNotesView: View {
    let route: LibraryRoute
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    var presentsReaderInPlace: Bool
    @State private var filing: IOSFilingSheet?
    @State private var emptyingTrash = false
    @State private var permanentDelete: NoteSnapshot?

    var body: some View {
        List {
            Section {
                if !library.notes.isEmpty {
                    countLine
                }
                ForEach(library.notes) { note in
                    IOSNoteNavigationRow(
                        note: note,
                        session: session,
                        library: library,
                        presentsReaderInPlace: presentsReaderInPlace,
                        onTags: { filing = .tags(note.url) },
                        onMove: { filing = .move(note.url) },
                        onDeleteForever: { permanentDelete = note }
                    )
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.notes.isEmpty {
                emptyContent
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(library.collectionTitle)
        .navigationBarTitleDisplayMode(.large)
        .modifier(IOSChromeToolbar(session: session, library: library, showsSettings: false))
        .toolbar {
            if route == .trash {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Empty Trash", role: .destructive) {
                        emptyingTrash = true
                    }
                    .disabled(library.trashCount == 0)
                }
            }
        }
        .sheet(item: $filing) { item in
            switch item {
            case .tags(let url):
                IOSTagsSheet(url: url, library: library)
            case .move(let url):
                IOSMoveSheet(url: url, library: library)
            }
        }
        .confirmationDialog("Empty the Trash?", isPresented: $emptyingTrash) {
            Button("Empty Trash", role: .destructive) { library.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(library.trashCount) note(s) will be removed from disk. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(
                get: { permanentDelete != nil },
                set: { if !$0 { permanentDelete = nil } }
            ),
            presenting: permanentDelete
        ) { note in
            Button("Delete Permanently", role: .destructive) {
                library.deletePermanently([note])
                permanentDelete = nil
            }
            Button("Cancel", role: .cancel) { permanentDelete = nil }
        } message: { _ in
            Text("\(1) note(s) will be removed from disk. This cannot be undone.")
        }
        .onAppear { route.apply(to: library) }
        .onChange(of: route) { _, new in new.apply(to: library) }
        .onChange(of: library.searchText) { _, text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                route.apply(to: library)
            }
        }
    }

    /// Notes' count under the collection title. `navigationSubtitle` is iOS 26
    /// and the target is 17, so it rides at the head of the list instead and
    /// scrolls away with the large title, which is where Notes puts it.
    private var countLine: some View {
        Text("\(library.notes.count) notes")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
    }

    @ViewBuilder
    private var emptyContent: some View {
        let query = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            ContentUnavailableView {
                Label("No notes", systemImage: "note.text")
            } description: {
                Text("Create a note or pick another folder.")
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }
}

/// List chrome: settings (sources only, top-leading), new folder (sources
/// only, top-trailing, its own item), and an always-visible bottom bar
/// holding search + compose. The reader inserts the same `IOSBottomBar`
/// without the capsule.
///
/// The bar is a `safeAreaInset`, not a `ToolbarItemGroup`: a bar-button item
/// sizes its hosted view on the intrinsic size, so `.frame(maxWidth: .infinity)`
/// never reached the search field and the capsule collapsed to nothing.
/// The inset gives it the screen width, and the list scrolls under it.
private struct IOSChromeToolbar: ViewModifier {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    var showsSettings: Bool
    /// Sources screen only, trailing, isolated. Creating a folder is the
    /// whole of folder filing on the phone — no rename, no move, no delete.
    var onNewFolder: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if showsSettings {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            session.sheet = .settings
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                // Isolated trailing item. Grouping it with the gear on the
                // leading edge was the opposite of the request: new folder
                // sits on the right, alone. If iOS 26 still moves it, leave
                // it trailing — do not regroup on the left.
                if let onNewFolder {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onNewFolder) {
                            Image(systemName: "folder.badge.plus")
                        }
                        .accessibilityLabel("New Folder")
                        .disabled(library.rootURL == nil)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                IOSBottomSearchAndComposeBar(session: session, library: library)
            }
    }
}

/// The one scale the bottom bar is built from. Same device, same numbers —
/// on the list and on the reader.
///
/// These are UIKit's own numbers, measured rather than chosen, because the
/// reader used to get them for free from a real toolbar and the list did not:
/// `UIToolbar.sizeThatFits` answers **44 pt**, and the symbol a bar button
/// item draws is the body text style at `.large` image scale — a 27 pt box
/// for `square.and.pencil`, the very image
/// `UIImage.SymbolConfiguration(pointSize: 22)` produces. Body at the default
/// scale, which this bar used to draw, is only a 21 pt box: that was the gap.
/// The bar is drawn by hand (a bar-button item proposes no width, so the
/// search capsule collapsed inside a toolbar), so the numbers are restated
/// here instead of inherited.
enum IOSBottomBarMetrics {
    /// Search capsule height, and the hit target around the glass buttons.
    /// `UIToolbar`'s own height. The glass itself is toolbar-calibre, not
    /// a disc of this diameter.
    static let controlHeight: CGFloat = 44
    /// Side margin of the bar.
    static let margin: CGFloat = 16
    /// Capsule ↔ compose button, the capsule's inner inset, and the bar's
    /// own vertical padding.
    static let gap: CGFloat = 10
    /// What the bar occupies above the home indicator: one control plus its
    /// padding. `safeAreaInset` measures this by itself for a SwiftUI scroll
    /// view; the reader's `WKWebView` has to be told, so the number is named.
    static var barHeight: CGFloat { controlHeight + 2 * gap }
    /// A bar button item's symbol: body text style at `.large` scale. Stated
    /// as a text style, not a point size, so Dynamic Type moves this glyph
    /// exactly as it moves a toolbar's.
    static let glyphFont: Font = .body
    static let glyphScale: Image.Scale = .large
}

/// A bottom-bar glyph at toolbar calibre. Every symbol in this bar goes
/// through here: no control keeps an implicit `.font(.body)`.
struct IOSBottomBarGlyph: View {
    let systemImage: String
    var tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(IOSBottomBarMetrics.glyphFont)
            .imageScale(IOSBottomBarMetrics.glyphScale)
            .foregroundStyle(tint)
    }
}

/// A round bottom-bar action: compose, Find, and the find chevrons.
///
/// Glyphs are `.primary` (black in light, white in dark), never accent —
/// the same ink as the system nav-bar items. Disabled is `.secondary`.
/// The pin mark (`IOSPalette.pinForeground`) does not live in this bar.
///
/// Fill is one layer on the control: Liquid Glass on iOS 26 (toolbar
/// calibre, not a 44 pt disc), `regularMaterial` on 17–18. The 44 pt
/// frame is the hit target; it is not painted.
struct IOSBottomBarCircleButton: View {
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            IOSBottomBarGlyph(
                systemImage: systemImage,
                tint: isEnabled ? Color.primary : Color.secondary
            )
        }
        .modifier(IOSGlassIconButtonChrome())
        .tint(.primary)
        .frame(
            minWidth: IOSBottomBarMetrics.controlHeight,
            minHeight: IOSBottomBarMetrics.controlHeight
        )
        .contentShape(Rectangle())
    }
}

/// Done, sitting beside Find: the same glass/material language as the
/// round controls, in a capsule, primary ink.
struct IOSBottomBarDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(IOSBottomBarMetrics.glyphFont)
                .foregroundStyle(.primary)
        }
        .modifier(IOSGlassTextButtonChrome())
        .tint(.primary)
        .frame(minHeight: IOSBottomBarMetrics.controlHeight)
        .contentShape(Rectangle())
    }
}

/// iOS 26: system glass button, the same treatment as a nav-bar item.
/// 17–18: material in a circle around the glyph. Never an opaque gray.
private struct IOSGlassIconButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content
                .buttonStyle(.plain)
                .padding(8)
                .background(.regularMaterial, in: Circle())
        }
    }
}

/// Same split as the icon chrome, for the Done label: glass button, or
/// a material capsule.
private struct IOSGlassTextButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content
                .buttonStyle(.plain)
                .padding(.horizontal, IOSBottomBarMetrics.gap)
                .frame(height: IOSBottomBarMetrics.controlHeight)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

/// Compose, the same control on the list and in the reader: same place, same
/// calibre, same circle.
struct IOSBottomBarComposeButton: View {
    @ObservedObject var session: IOSSession

    var body: some View {
        IOSBottomBarCircleButton(systemImage: "square.and.pencil") {
            session.sheet = .capture
        }
        .accessibilityLabel("New Note")
    }
}

/// The bar itself: margins and whatever the screen puts in it, over nothing.
///
/// **It paints no background.** On Notes the same controls float over the
/// content — the list keeps scrolling behind them. What makes a glyph
/// legible is the control's own fill: glass (iOS 26) or material (17–18)
/// on the button or capsule, one layer. A strip behind the bar would be a
/// second layer under the same pixels, and a
/// gradient fade would have to guess the colour behind it — in the reader
/// that colour is the preview theme's, not `systemBackground`.
///
/// **Reachability is `safeAreaInset`'s job, not an overlay's.** Both hosts
/// insert this bar with `safeAreaInset(edge: .bottom)`, which reserves the
/// room *and* lets a `List` scroll its rows under it: the last row can be
/// scrolled clear of the controls and tapped. `overlay` plus
/// `contentMargins` reaches the same picture but states the reservation
/// twice — once for the scroll content, once again for the keyboard — and
/// says nothing to the reader's `WKWebView`, which is not a SwiftUI scroll
/// view at all. So: inset here, and the reader hands `barHeight` to its web
/// view's own scroll insets.
struct IOSBottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: IOSBottomBarMetrics.gap) {
            content
        }
        .padding(.horizontal, IOSBottomBarMetrics.margin)
        .padding(.vertical, IOSBottomBarMetrics.gap)
    }
}

/// Notes-style bottom bar: a search field (magnifying glass, placeholder,
/// on-device dictation mic) plus a separate compose button, always visible.
/// One instance per list screen — each owns its own `DictationController`,
/// so leaving the screen tears the recognizer down.
private struct IOSBottomSearchAndComposeBar: View {
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    @StateObject private var dictation = DictationController()
    @FocusState private var searchFocused: Bool

    var body: some View {
        IOSBottomBar {
            IOSSearchCapsule(
                text: searchBinding,
                placeholder: String(localized: "Search"),
                focus: $searchFocused,
                onSubmit: { searchFocused = false }
            ) {
                IOSDictationMicButton(dictation: dictation) {
                    session.setLibrarySearch($0)
                }
            }
            IOSBottomBarComposeButton(session: session)
        }
    }

    /// The setter is the user-edit hook the `UISearchBar` delegate used to
    /// be: SwiftUI writes through a `TextField` binding only for a genuine
    /// keystroke, never for a programmatic change, so a transcript landing
    /// in `library.searchText` does not stop the recognizer that produced it.
    private var searchBinding: Binding<String> {
        Binding(
            get: { library.searchText },
            set: { typed in
                if dictation.isRecording { dictation.stop() }
                session.setLibrarySearch(typed)
            }
        )
    }
}

/// The dictation mic, inside the capsule at its trailing edge. Draws no
/// background of its own: the capsule is the layer.
struct IOSDictationMicButton: View {
    @ObservedObject var dictation: DictationController
    let onTranscript: (String) -> Void

    var body: some View {
        if dictation.isAvailable {
            Button {
                dictation.toggle(into: onTranscript)
            } label: {
                IOSBottomBarGlyph(
                    systemImage: dictation.isRecording ? "mic.fill" : "mic",
                    tint: dictation.isRecording ? Color.accentColor : Color.secondary
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dictate Search")
        }
    }
}

/// Stack: pushes the reader. Split: selects it for the detail pane.
private struct IOSNoteNavigationRow: View {
    let note: NoteSnapshot
    @ObservedObject var session: IOSSession
    @ObservedObject var library: LibraryModel
    var presentsReaderInPlace: Bool
    var onTags: () -> Void
    var onMove: () -> Void
    var onDeleteForever: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if presentsReaderInPlace {
                Button {
                    session.selectNote(note.url)
                } label: {
                    rowContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tint(.primary)
            } else {
                NavigationLink(value: LibraryRoute.note(note.url)) {
                    rowContent
                }
            }
        }
        .listRowBackground(selectionBackground)
        .iosNoteRowActions(
            note: note,
            library: library,
            onTags: onTags,
            onMove: onMove,
            onDeleteForever: onDeleteForever
        )
    }

    private var rowContent: some View {
        IOSNoteRow(
            note: note,
            showFolder: library.showsFolderOnRows,
            showExcerpt: settings.showExcerpt,
            showDate: settings.showDate,
            showTags: settings.showTagsInList,
            activeTags: library.selectedTags
        )
    }

    private var selectionBackground: Color? {
        guard presentsReaderInPlace,
              session.selectedNoteURL == note.url.standardizedFileURL else { return nil }
        return Color(uiColor: .tertiarySystemFill)
    }
}

struct IOSNoteRow: View {
    let note: NoteSnapshot
    var showFolder: Bool
    var showExcerpt: Bool
    var showDate: Bool
    var showTags: Bool
    var activeTags: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(IOSPalette.pinForeground)
                }
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let excerpt = visibleExcerpt {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if showDate {
                    Text(note.modifiedAt, style: .relative)
                }
                if showFolder, let folder = note.folderPathLabel, !folder.isEmpty {
                    Text(folder)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if showTags, !note.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.tags.prefix(6), id: \.self) { tag in
                        IOSTagChip(
                            name: tag,
                            isActive: IOSTagChip.isActive(tag, filters: activeTags)
                        )
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var visibleExcerpt: String? {
        guard showExcerpt, !note.excerpt.isEmpty else { return nil }
        if note.excerpt.caseInsensitiveCompare(note.title) == .orderedSame { return nil }
        return note.excerpt
    }
}
