import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

#if os(iOS)
/// Keyboard column. Mac defines this in `LibraryKeyboard`.
enum LibraryPane: Hashable {
    case sidebar
    case notes
    case preview
}
#endif

@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    enum SidebarItem: Hashable {
        case all
        case inbox
        case untagged
        case trash
        case project(URL)
        /// Row identity for the sidebar outline. Never a live `sidebarSelection` after restore.
        case tag(String)
        /// Row identity for a favourite note. Never a live `sidebarSelection` after restore.
        case note(URL)

        var isTag: Bool {
            if case .tag = self { return true }
            return false
        }
    }

    let settings: AppSettings
    let store: LibraryStore
    let scopedRoot = ScopedRoot()
    /// Tests inject a failing factory; production writes a security-scoped bookmark.
    var bookmarkFactory: (URL) throws -> Data = { try BookmarkStore.makeBookmark(for: $0) }
    /// Tests replace this so a refused open does not run a modal alert.
    /// iOS UI replaces the no-op with its own presentation.
    var errorPresenter: (Error) -> Void = { error in
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.runModal()
        #else
        _ = error
        #endif
    }
    /// Tests replace this so they can force `fr` or `en`. Production follows
    /// `AppleLanguages` / `Locale.preferredLanguages`, not the bundle's
    /// intersection with `.lproj` folders — a String Catalog can lag behind.
    var preferredLocalization: () -> String = {
        if let tagged = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           let first = tagged.first, !first.isEmpty {
            return first
        }
        return Locale.preferredLanguages.first
            ?? Bundle.main.preferredLocalizations.first
            ?? "en"
    }
    /// Tests replace this with the on-disk fixture. `locale` is `en` or `fr`.
    var sampleLibrarySourceURL: (String) -> URL? = { locale in
        Bundle.main.url(forResource: locale, withExtension: nil, subdirectory: "SampleLibrary")
            ?? Bundle.main.url(forResource: locale, withExtension: nil)
    }
    /// Tests replace this so they never write into Application Support.
    var sampleLibraryDestinationURL: (String) -> URL = { locale in
        SampleLibrary.defaultDestinationURL(locale: locale)
    }

    @Published var sidebarSelection: SidebarItem = .all {
        didSet {
            if sidebarSelection == .untagged, !selectedTags.isEmpty {
                let was = suppressingReload
                suppressingReload = true
                selectedTags = []
                suppressingReload = was
            }
            if !suppressingReload { reloadNotes() }
            persistSession()
        }
    }
    /// Additive AND filter on the current collection. Empty means no tag filter.
    @Published var selectedTags: Set<String> = [] {
        didSet {
            guard selectedTags != oldValue else { return }
            if sidebarSelection == .untagged, !selectedTags.isEmpty {
                let was = suppressingReload
                suppressingReload = true
                sidebarSelection = .all
                suppressingReload = was
            }
            if !suppressingReload { reloadNotes() }
            persistSession()
        }
    }
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            // Clearing the field is a cancel gesture: it must land at once.
            if searchText.isEmpty {
                cancelSearchDebounce()
                reloadNotes()
            } else {
                debounceSearch()
            }
        }
    }
    @Published private(set) var folders: [FolderSnapshot] = []
    @Published private(set) var tags: [String] = []
    /// The same tags with the number of notes carrying each. Published beside
    /// `tags` and from the same pass, so the two never disagree.
    @Published private(set) var tagCounts: [LibraryStore.TagCount] = []
    /// Folder, note and tag shortcuts, already in display order (alpha or rank).
    @Published private(set) var favourites: [Favourite] = []
    @Published private(set) var notes: [NoteSnapshot] = []
    @Published var selectedNoteIDs: Set<URL> = [] {
        didSet { persistSession() }
    }
    @Published var expandedFolders: Set<URL> = [] {
        didSet { persistSession() }
    }
    @Published var sidebarVisible = true

    /// Which column the keyboard is in. Mirrored from `LibraryView`'s focus
    /// state so AppKit — the menu, the toolbar — can route on it.
    @Published var focusedPane: LibraryPane?
    /// Bumped to ask `LibraryView` to move the focus. A request rather than a
    /// value: focus is SwiftUI's to own, this only nudges it.
    @Published var focusRequest: LibraryPane?

    /// Find within the shown note, which is separate from the global search.
    @Published var previewFindVisible = false
    @Published var previewFindQuery = ""
    /// Bumped to put the caret back in the find field.
    @Published var previewFindFocus = 0

    @Published private(set) var rootURL: URL?

    /// How many times the list has been recomputed. Not published and never
    /// read by the app: the debounce tests need to see a reload that publishes
    /// nothing, which an equality-guarded `notes` no longer shows them.
    private(set) var reloadCount = 0

    private var suppressingPersist = false
    /// Set while restoring a session, so the launch path filters and sorts the
    /// list once instead of three times.
    private var suppressingReload = false

    private var watcher: FileWatcher?
    private var refreshWorkItem: DispatchWorkItem?
    private let externalEditorOpener: ([URL], String) -> Void

    #if os(macOS)
    private static let defaultExternalEditorOpener: ([URL], String) -> Void = NoteActions.openExternally
    #else
    private static let defaultExternalEditorOpener: ([URL], String) -> Void = { _, _ in }
    #endif

    init(
        settings: AppSettings? = nil,
        store: LibraryStore? = nil,
        externalEditorOpener: @escaping ([URL], String) -> Void = LibraryModel.defaultExternalEditorOpener
    ) {
        self.settings = settings ?? .shared
        self.store = store ?? LibraryStore()
        self.externalEditorOpener = externalEditorOpener
    }

    var selectedNotes: [NoteSnapshot] {
        notes.filter { selectedNoteIDs.contains($0.url) }
    }

    var focusedNote: NoteSnapshot? {
        guard selectedNoteIDs.count == 1 else { return nil }
        return selectedNotes.first
    }

    var isViewingTrash: Bool { sidebarSelection == .trash }

    // The three badges come from one memoized pass over `records`, instead of
    // three `Array(records.values)` allocations per read.
    var trashCount: Int { store.counts().trashed }

    var inboxCount: Int {
        guard rootURL != nil else { return 0 }
        return store.counts().inbox
    }

    var untaggedCount: Int { store.counts().untagged }

    /// Tags this note might want, strongest first, at most five — and empty
    /// when counting has nothing to say. Called only when the human has
    /// already opened the tag editor: nothing here publishes, badges or
    /// notifies. The work is `TagSuggestions.suggest`, a pure function; this
    /// only hands it the library.
    func tagSuggestions(for note: NoteSnapshot) -> [TagSuggestion] {
        TagSuggestions.suggest(for: note, in: store.snapshots())
    }

    /// The existing tag that `typed` nearly duplicates (case, accents,
    /// singular / plural), or nil. An offer for the UI to show under the
    /// field — the human's own tag is never rewritten.
    func tagDuplicateOffer(for typed: String) -> TagDuplicateOffer? {
        TagHygiene.nearDuplicate(of: typed, among: tags)
    }

    var sortBy: SortKey {
        get { settings.sortKey }
        set { settings.sortKey = newValue; reloadNotes() }
    }

    var sortAscending: Bool {
        get { settings.sortAscending }
        set { settings.sortAscending = newValue; reloadNotes() }
    }

    #if os(macOS)
    var externalEditorBundle: String {
        get { settings.externalEditorBundle }
        set { settings.externalEditorBundle = newValue; objectWillChange.send() }
    }
    #endif

    func openRoot(_ url: URL, bookmark: Data? = nil, skipActivate: Bool = false) {
        let standardized = url.standardizedFileURL
        var bookmarkToStore = bookmark
        if bookmark == nil {
            do {
                bookmarkToStore = try bookmarkFactory(url)
            } catch {
                // `activate` returning false is normal for unscopeable URLs and
                // must not abort. Switching away from a remembered library
                // without a new bookmark would restore the old folder next launch.
                if !skipActivate, settings.storageBookmark != nil {
                    present(LibraryError.cannotRememberFolder)
                    return
                }
                bookmarkToStore = nil
            }
        }
        if !skipActivate {
            _ = scopedRoot.activate(url)
        }
        if let bookmarkToStore {
            settings.storageBookmark = bookmarkToStore
        }
        rootURL = standardized
        store.conflictResolutionEnabled = settings.resolveICloudConflicts
        store.useFirstLineAsTitle = settings.useFirstLineAsTitle
        store.attachmentFolderPatterns = settings.attachmentFolderPatterns
        store.setRoot(standardized)
        if skipActivate {
            startWatcher()
            // `restoreSession` ends with the single filter + sort pass.
            folders = store.folders()
            tagCounts = store.tagCounts()
            tags = tagCounts.map(\.name)
            publishFavourites()
            restoreSession()
        } else {
            suppressingPersist = true
            sidebarSelection = .all
            selectedTags = []
            selectedNoteIDs = []
            expandedFolders = []
            searchText = ""
            suppressingPersist = false
            settings.lastSidebarToken = "all"
            settings.lastSelectedTags = []
            settings.lastNoteRelativePath = nil
            settings.expandedFolderPaths = []
            startWatcher()
            reloadEverything()
        }
    }

    @discardableResult
    func restoreSavedRoot() -> Bool {
        guard let data = settings.storageBookmark else { return false }
        do {
            let resolved = try BookmarkStore.resolve(data)
            guard scopedRoot.activate(resolved.url) else { return false }
            if resolved.stale, let fresh = try? BookmarkStore.makeBookmark(for: resolved.url) {
                settings.storageBookmark = fresh
            }
            openRoot(resolved.url, bookmark: settings.storageBookmark, skipActivate: true)
            return true
        } catch {
            return false
        }
    }

    #if os(macOS)
    func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.message = NSLocalizedString("Choose the folder that holds your Markdown notes.", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openRoot(url)
    }
    #endif

    /// Copies the bundled sample tree into Application Support if that copy
    /// has no notes yet, then opens it through `openRoot` like any other folder.
    func openSampleLibrary() {
        let locale = SampleLibrary.localeCode(from: preferredLocalization())
        let destination = sampleLibraryDestinationURL(locale).standardizedFileURL
        if SampleLibrary.containsNotes(at: destination) {
            openRoot(destination)
            return
        }
        guard let source = sampleLibrarySourceURL(locale) ?? sampleLibrarySourceURL("en") else {
            present(LibraryError.sampleLibraryMissing)
            return
        }
        do {
            try SampleLibrary.copy(from: source, to: destination)
        } catch {
            present(LibraryError.sampleLibraryCopyFailed)
            return
        }
        openRoot(destination)
    }

    /// How long coalesced FSEvents wait before one reload. Production keeps
    /// 0.4 s; tests shorten it so they exercise the real timer path.
    var refreshDebounce: TimeInterval = 0.4

    /// Recomputing the list on every keystroke is the expensive part of
    /// typing; the field itself stays instant. Injectable so tests exercise
    /// the real timer.
    var searchDebounce: TimeInterval = 0.15
    private var searchWorkItem: DispatchWorkItem?

    /// Escape and the clear button: cancel and recompute now.
    func clearSearch() {
        cancelSearchDebounce()
        if searchText.isEmpty {
            reloadNotes()
        } else {
            searchText = ""  // didSet reloads immediately for an empty query.
        }
    }

    private func cancelSearchDebounce() {
        searchWorkItem?.cancel()
        searchWorkItem = nil
    }

    private func debounceSearch() {
        cancelSearchDebounce()
        let work = DispatchWorkItem { [weak self] in
            self?.searchWorkItem = nil
            self?.reloadNotes()
        }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounce, execute: work)
    }

    func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadFromDisk()
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDebounce, execute: work)
    }

    func reloadFromDisk() {
        store.conflictResolutionEnabled = settings.resolveICloudConflicts
        store.useFirstLineAsTitle = settings.useFirstLineAsTitle
        store.attachmentFolderPatterns = settings.attachmentFolderPatterns
        store.rescan()
        // A disk change should not start reading a note when none was selected.
        // Nonempty selections still reconcile against removed or moved files.
        reloadEverything(preservingSelection: selectedNoteIDs.isEmpty)
    }

    /// `@Published` fires on assignment, not on change. Every reload below
    /// recomputes its value from the store and would republish it even when it
    /// came back identical — and an FSEvents echo lands one of those on a note
    /// list that is still animating a row move, which is what left a blank row
    /// behind after an unpin. Recompute freely; publish only a difference.
    func reloadEverything(preservingSelection: Bool = false) {
        let newFolders = store.folders()
        if newFolders != folders { folders = newFolders }
        let newCounts = store.tagCounts()
        if newCounts != tagCounts {
            tagCounts = newCounts
            // Published from the same pass, so the two never disagree.
            tags = newCounts.map(\.name)
        }
        pruneSelectedTags(keeping: Set(newCounts.map(\.name)))
        store.pruneFavourites()
        publishFavourites()
        reloadNotes(preservingSelection: preservingSelection)
    }

    func applyAttachmentFolderPatterns() {
        store.attachmentFolderPatterns = settings.attachmentFolderPatterns
        let newFolders = store.folders()
        if newFolders != folders { folders = newFolders }
        if case .project(let url) = sidebarSelection,
           LibraryPaths.isAttachmentFolderName(url.lastPathComponent, patterns: store.attachmentFolderPatterns) {
            sidebarSelection = .all
        }
    }

    func reloadNotes(preservingSelection: Bool = false) {
        var result = store.snapshots()
        result = result.filter { $0.isTrashed == isViewingTrash }

        switch sidebarSelection {
        case .all, .trash, .note:
            break
        case .inbox:
            if let rootURL {
                result = result.filter { $0.folderURL.standardizedFileURL == rootURL }
            }
        case .untagged:
            result = result.filter { $0.tags.isEmpty }
        case .project(let url):
            let folder = url.standardizedFileURL
            if settings.includeFolderDescendants {
                // Directory boundary (`path/`), so Work2 is never a child of Work.
                result = result.filter { LibraryPaths.isInside($0.folderURL, folder: folder) }
            } else {
                result = result.filter { $0.folderURL.standardizedFileURL == folder }
            }
        case .tag(let name):
            // Shipping sidebar still assigns `.tag` as the selection. Keep
            // filtering that one tag until the UI writes `selectedTags` instead.
            result = result.filter { $0.tags.contains(name) }
        }

        if !selectedTags.isEmpty {
            result = result.filter { note in
                selectedTags.allSatisfy { note.tags.contains($0) }
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            // Folded once here, not once per note per term.
            let terms = query.split(whereSeparator: { $0.isWhitespace })
                .map { NoteSnapshot.fold(String($0)) }
            result = result.filter { $0.matches(foldedTerms: terms) }
        }

        let sorted = sort(result)
        if sorted != notes { notes = sorted }
        reloadCount += 1
        if preservingSelection {
            #if os(macOS)
            DockBadge.refresh()
            #endif
            return
        }
        let visible = Set(notes.map(\.url))
        // A selection that survives the filter is the common case, and
        // republishing it re-enters the list's `List(selection:)` binding for
        // nothing. Only a selection that actually lost a note is published.
        let reduced = selectedNoteIDs.intersection(visible)
        if reduced != selectedNoteIDs { selectedNoteIDs = reduced }
        if selectedNoteIDs.isEmpty, let first = notes.first {
            selectedNoteIDs = [first.url]
        }
        #if os(macOS)
        DockBadge.refresh()
        #endif
    }

    var collectionTitle: String {
        let base: String
        switch sidebarSelection {
        case .all, .tag, .note:
            base = NSLocalizedString("All Notes", comment: "")
        case .inbox:
            base = NSLocalizedString("Inbox", comment: "")
        case .untagged:
            base = NSLocalizedString("Untagged", comment: "")
        case .trash:
            base = NSLocalizedString("Trash", comment: "")
        case .project(let url):
            base = url.lastPathComponent
        }
        if selectedTags.isEmpty { return base }
        let names = selectedTags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: ", ")
        return "\(base) · \(names)"
    }

    var showsFolderOnRows: Bool {
        switch sidebarSelection {
        case .all, .untagged, .tag, .note, .trash: return true
        case .inbox: return false
        case .project: return settings.includeFolderDescendants
        }
    }

    private func persistSession() {
        guard !suppressingPersist, let rootURL else { return }
        var tagsToStore = selectedTags
        switch sidebarSelection {
        case .tag(let name):
            settings.lastSidebarToken = "all"
            if !name.isEmpty { tagsToStore.insert(name) }
        case .note:
            settings.lastSidebarToken = "all"
        default:
            settings.lastSidebarToken = sidebarSelection.token(relativeTo: rootURL)
        }
        settings.lastSelectedTags = tagsToStore.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if let note = focusedNote {
            settings.lastNoteRelativePath = LibraryPaths.relativePath(of: note.url, to: rootURL)
        }
        settings.expandedFolderPaths = expandedFolders.map {
            LibraryPaths.relativePath(of: $0, to: rootURL)
        }
    }

    private func restoreSession() {
        guard let rootURL else { return }
        suppressingPersist = true
        suppressingReload = true
        expandedFolders = Set(
            settings.expandedFolderPaths.map { rootURL.appendingPathComponent($0, isDirectory: true) }
        )
        let restored = Self.restoredCollection(
            token: settings.lastSidebarToken,
            storedTags: settings.lastSelectedTags,
            root: rootURL
        )
        sidebarSelection = restored.collection
        selectedTags = restored.tags
        if sidebarSelection == .untagged, !selectedTags.isEmpty {
            sidebarSelection = .all
        }
        pruneSelectedTags(keeping: Set(tags))
        suppressingReload = false
        reloadNotes()
        if let path = settings.lastNoteRelativePath {
            let url = rootURL.appendingPathComponent(path)
            if notes.contains(where: { $0.url == url }) {
                selectedNoteIDs = [url]
            }
        }
        if selectedNoteIDs.isEmpty, let first = notes.first {
            selectedNoteIDs = [first.url]
        }
        suppressingPersist = false
    }

    /// Old sessions stored `tag:Name` as the collection. That token becomes All Notes plus the tag.
    private static func restoredCollection(
        token: String,
        storedTags: [String],
        root: URL
    ) -> (collection: SidebarItem, tags: Set<String>) {
        var tags = Set(storedTags)
        if token.hasPrefix("tag:") {
            let name = String(token.dropFirst("tag:".count))
            if !name.isEmpty { tags.insert(name) }
            return (.all, tags)
        }
        return (SidebarItem.from(token: token, root: root), tags)
    }

    private func pruneSelectedTags(keeping known: Set<String>) {
        guard !selectedTags.isEmpty else { return }
        let pruned = selectedTags.intersection(known)
        guard pruned != selectedTags else { return }
        let was = suppressingReload
        suppressingReload = true
        selectedTags = pruned
        suppressingReload = was
    }

    private func sort(_ notes: [NoteSnapshot]) -> [NoteSnapshot] {
        let ascending = settings.sortAscending
        let key = settings.sortKey
        return notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            let comparison: ComparisonResult
            switch key {
            case .modified:
                comparison = lhs.modifiedAt.compare(rhs.modifiedAt)
            case .created:
                comparison = lhs.createdAt.compare(rhs.createdAt)
            case .title:
                comparison = lhs.title.localizedStandardCompare(rhs.title)
            }
            if comparison == .orderedSame {
                return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
            }
            if ascending {
                return comparison == .orderedAscending
            }
            return comparison == .orderedDescending
        }
    }

    func createNote() {
        createNote(in: creationFolder())
    }

    /// Global hotkey: always the Inbox (storage root), not the current sidebar folder.
    /// Always opens the editor — that is the point of the shortcut.
    func createQuickNote() {
        createNote(in: rootURL, openEditor: true, preserveContext: true)
    }

    /// iOS capture: one write into Inbox (library root). Empty or whitespace
    /// creates nothing. The typed text is the body; YAML `title` is the first
    /// non-empty line, else the start of the text, else Untitled. Never opens
    /// an editor, never revises a body afterwards.
    @discardableResult
    func captureInboxNote(text: String) -> URL? {
        guard let rootURL else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let title = Self.captureTitle(from: text)
        let body = FrontMatterCodec.newNote(title: title, body: text)
        do {
            let record = try store.createNote(
                named: title,
                in: rootURL,
                extension: settings.noteExtension,
                body: body
            )
            #if os(iOS)
            // Stay on the current list. Capture writes Inbox; it does not
            // open the note or retarget search / tags / sidebar.
            reloadEverything()
            #else
            searchText = ""
            if !selectedTags.isEmpty { selectedTags = [] }
            sidebarSelection = .inbox
            reloadEverything()
            selectedNoteIDs = [record.url]
            #endif
            return record.url
        } catch {
            present(error)
            return nil
        }
    }

    /// First non-empty line, else the start of the text, else Untitled.
    static func captureTitle(from text: String) -> String {
        InboxCapture.captureTitle(from: text)
    }

    private func createNote(in folder: URL?, openEditor: Bool? = nil, preserveContext: Bool = false) {
        guard let rootURL else { return }
        let folder = folder ?? rootURL
        let name = untitledName(in: folder)
        let body = FrontMatterCodec.newNote(title: name)
        do {
            let record = try store.createNote(
                named: name,
                in: folder,
                extension: settings.noteExtension,
                body: body
            )
            if !preserveContext, !selectedTags.isEmpty {
                for tag in selectedTags.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    store.applyTag(tag, add: true, to: [record.url])
                }
            }
            #if os(macOS)
            if openEditor ?? settings.openEditorOnCreate {
                openInExternalEditor(urls: [record.url])
            }
            #else
            _ = openEditor
            #endif
            if preserveContext {
                reloadEverything(preservingSelection: true)
                return
            }
            searchText = ""
            if folder.standardizedFileURL == rootURL {
                sidebarSelection = .inbox
            } else {
                sidebarSelection = .project(folder)
            }
            reloadEverything()
            selectedNoteIDs = [record.url]
        } catch {
            present(error)
        }
    }

    /// New notes land in the selected folder, not always Inbox.
    func creationFolder() -> URL? {
        guard let rootURL else { return nil }
        switch sidebarSelection {
        case .project(let url):
            return url
        case .trash:
            return rootURL
        default:
            return rootURL
        }
    }

    private func untitledName(in folder: URL) -> String {
        let base = NSLocalizedString("Untitled Note", comment: "")
        return FilenameSanitizer.uniqueName(base: base, ext: settings.noteExtension, in: folder)
    }

    @discardableResult
    func rename(_ note: NoteSnapshot, to newName: String) -> String? {
        do {
            let updated = try store.rename(note.url, to: newName, updateYAMLTitle: true)
            reloadEverything()
            selectedNoteIDs = [updated.url]
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setTitle(_ note: NoteSnapshot, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.title else { return }
        do {
            try store.writeTitle(note.url, title: trimmed)
            reloadEverything()
            selectedNoteIDs = [note.url]
        } catch {
            present(error)
        }
    }

    func selectAllVisibleNotes() {
        let all = Set(notes.map(\.url))
        if all != selectedNoteIDs { selectedNoteIDs = all }
    }

    /// Renames the file to the display title. Does not rewrite YAML.
    @discardableResult
    func matchFilenameToTitle(_ note: NoteSnapshot) -> String? {
        matchFilenameToTitle([note])
    }

    /// Renames each selected file to its display title. Does not rewrite YAML.
    @discardableResult
    func matchFilenameToTitle(_ notes: [NoteSnapshot]) -> String? {
        let targets = notes.filter(\.fileStemDiffersFromTitle)
        guard !targets.isEmpty else { return nil }
        var newSelection = Set(notes.map(\.url))
        var lastError: String?
        for note in targets {
            newSelection.remove(note.url)
            do {
                let updated = try store.rename(note.url, to: note.title, updateYAMLTitle: false)
                newSelection.insert(updated.url)
            } catch {
                newSelection.insert(note.url)
                lastError = error.localizedDescription
                present(error)
            }
        }
        reloadEverything()
        let visible = Set(self.notes.map(\.url))
        let kept = newSelection.intersection(visible)
        if kept != selectedNoteIDs { selectedNoteIDs = kept }
        return lastError
    }

    func move(_ notes: [NoteSnapshot], to folder: URL) {
        do {
            try store.move(notes.map(\.url), to: folder)
            reloadEverything()
        } catch {
            present(error)
        }
    }

    func togglePin(_ notes: [NoteSnapshot]) {
        do {
            try store.togglePins(notes.map(\.url))
        } catch {
            present(error)
        }
        reloadNotes()
    }

    /// Empty string (after trim) is nil: the default `folder` glyph.
    func setFolderSymbol(_ url: URL, _ name: String?) {
        store.setFolderSymbol(url, name)
        let newFolders = store.folders()
        if newFolders != folders { folders = newFolders }
    }

    func addFavourite(_ item: Favourite) {
        do {
            try store.addFavourite(item)
            publishFavourites()
        } catch {
            present(error)
        }
    }

    func removeFavourite(_ item: Favourite) {
        do {
            try store.removeFavourite(item)
            publishFavourites()
        } catch {
            present(error)
        }
    }

    /// `toOffset` matches SwiftUI `onMove`. First use locks the current alpha as rank.
    func reorderFavourites(fromOffsets source: IndexSet, toOffset destination: Int) {
        do {
            try store.reorderFavourites(fromOffsets: source, toOffset: destination)
            publishFavourites()
        } catch {
            present(error)
        }
    }

    func isFavourite(_ item: Favourite) -> Bool {
        store.isFavourite(item)
    }

    /// Jump to a favourite note's collection and select it. Never writes
    /// `sidebarSelection = .note` — that case is row identity only.
    func revealFavouriteNote(_ item: Favourite) {
        guard case .note(let path) = item else { return }
        guard let note = store.snapshot(relativePath: path) else { return }

        let collection: SidebarItem
        if note.isTrashed {
            collection = .trash
        } else if let rootURL, note.folderURL.standardizedFileURL == rootURL.standardizedFileURL {
            collection = .inbox
        } else {
            collection = .project(note.folderURL)
        }

        let was = suppressingReload
        suppressingReload = true
        sidebarSelection = collection
        selectedTags = []
        selectedNoteIDs = [note.url]
        suppressingReload = was
        reloadNotes()
        if notes.contains(where: { $0.url == note.url }), selectedNoteIDs != [note.url] {
            selectedNoteIDs = [note.url]
        }
    }

    /// Snapshot for a library-relative note path, trash included. Nil when missing.
    func note(relativePath: String) -> NoteSnapshot? {
        store.snapshot(relativePath: relativePath)
    }

    private func publishFavourites() {
        let next = store.favourites()
        if next != favourites { favourites = next }
    }

    func delete(_ notes: [NoteSnapshot]) {
        do {
            try store.trash(notes.map(\.url))
            reloadEverything()
        } catch {
            present(error)
        }
    }

    func deletePermanently(_ notes: [NoteSnapshot]) {
        do {
            try store.removeForever(notes.map(\.url))
            reloadEverything()
        } catch {
            present(error)
        }
    }

    func restore(_ notes: [NoteSnapshot]) {
        guard let rootURL else { return }
        do {
            try store.restore(notes.map(\.url), fallback: rootURL)
            reloadEverything()
        } catch {
            present(error)
        }
    }

    func emptyTrash(completion: @escaping () -> Void = {}) {
        do {
            try store.emptyTrash()
            reloadEverything()
            completion()
        } catch {
            present(error)
            completion()
        }
    }

    func applyTag(_ tag: String, add: Bool, to notes: [NoteSnapshot]) {
        store.applyTag(tag, add: add, to: notes.map(\.url))
        reloadEverything()
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    /// Leaves the search field for the results it just filtered, selecting the
    /// first note so the arrow keys have somewhere to start.
    func focusNotesList() {
        if selectedNoteIDs.isEmpty, let first = notes.first {
            selectedNoteIDs = [first.url]
        }
        focusRequest = .notes
    }

    /// ⌘F in the preview. It opens on whatever the library search was looking
    /// for, so stepping through the matches in the note continues that search
    /// rather than starting a new one.
    func showPreviewFind() {
        if previewFindQuery.isEmpty {
            previewFindQuery = searchText
        }
        previewFindVisible = true
        previewFindFocus += 1
    }

    func hidePreviewFind() {
        previewFindVisible = false
        previewFindQuery = ""
    }

    @discardableResult
    func createFolder(named rawName: String) -> URL? {
        guard let parent = creationFolder() ?? rootURL else { return nil }
        do {
            let url = try store.createFolder(named: rawName, parent: parent)
            reloadEverything()
            sidebarVisible = true
            sidebarSelection = .project(url)
            return url
        } catch {
            present(error)
            return nil
        }
    }

    func renameFolder(_ folder: FolderSnapshot, to newName: String) -> String? {
        do {
            let url = try store.renameFolder(folder.url, to: newName)
            reloadEverything()
            sidebarSelection = .project(url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Drop target entry point for folder drag and drop. `destination` is the
    /// folder under the cursor, or `rootURL` for the library root. Returns nil
    /// on success, or the typed refusal for the UI to localize and present.
    /// Sorting stays alphabetical; no display order is persisted.
    @discardableResult
    func moveFolder(_ folder: FolderSnapshot, into destination: URL) -> FolderMoveError? {
        let source = folder.url.standardizedFileURL
        do {
            let target = try store.moveFolder(source, into: destination)
            reconcile(movedFolder: source, to: target)
            return nil
        } catch let error as FolderMoveError {
            return error
        } catch {
            present(error)
            return nil
        }
    }

    /// The open note, the sidebar selection and the disclosure state all keep
    /// pointing at the same items after their URLs changed.
    private func reconcile(movedFolder source: URL, to target: URL) {
        let remap: (URL) -> URL = { LibraryPaths.retargeted($0, from: source, to: target) ?? $0 }
        let selection = Set(selectedNoteIDs.map(remap))
        var expanded = Set(expandedFolders.map(remap))
        let newParent = target.deletingLastPathComponent().standardizedFileURL
        if newParent != rootURL?.standardizedFileURL { expanded.insert(newParent) }

        suppressingPersist = true
        if expanded != expandedFolders { expandedFolders = expanded }
        if case .project(let url) = sidebarSelection {
            let moved = remap(url)
            if moved != url.standardizedFileURL { sidebarSelection = .project(moved) }
        }
        if selection != selectedNoteIDs { selectedNoteIDs = selection }
        suppressingPersist = false

        reloadEverything(preservingSelection: true)
        persistSession()
    }

    func deleteFolder(_ folder: FolderSnapshot) {
        do {
            try store.deleteFolder(folder.url)
            sidebarSelection = .all
            reloadEverything()
        } catch {
            present(error)
        }
    }

    func openInExternalEditor(_ notes: [NoteSnapshot]) {
        openInExternalEditor(urls: notes.map(\.url))
    }

    func openInExternalEditor(urls: [URL]) {
        #if os(macOS)
        externalEditorOpener(urls, settings.externalEditorBundle)
        #else
        externalEditorOpener(urls, "")
        #endif
    }

    #if os(macOS)
    func revealInFinder(_ notes: [NoteSnapshot]) {
        revealInFinder(urls: notes.map(\.url))
    }

    func revealFolderInFinder(_ url: URL) {
        revealInFinder(urls: [url])
    }

    func revealSidebarSelectionInFinder() {
        guard let rootURL else { return }
        switch sidebarSelection {
        case .project(let url):
            revealFolderInFinder(url)
        case .trash:
            revealFolderInFinder(LibraryPaths.trashURL(root: rootURL))
        default:
            revealFolderInFinder(rootURL)
        }
    }

    func revealInFinder(urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func printNote(_ note: NoteSnapshot) {
        NotePrinter.print(note)
    }
    #endif

    func note(with id: URL) -> NoteSnapshot? {
        notes.first { $0.url == id } ?? store.snapshot(for: id)
    }

    func folder(with url: URL) -> FolderSnapshot? {
        func search(_ items: [FolderSnapshot]) -> FolderSnapshot? {
            for item in items {
                if item.url == url { return item }
                if let children = item.children, let found = search(children) {
                    return found
                }
            }
            return nil
        }
        return search(folders)
    }

    func allFoldersFlat() -> [FolderSnapshot] {
        var result: [FolderSnapshot] = []
        func walk(_ items: [FolderSnapshot], prefix: String) {
            for item in items {
                let label = prefix.isEmpty ? item.name : prefix + " / " + item.name
                result.append(FolderSnapshot(
                    url: item.url,
                    name: label,
                    parentURL: item.parentURL,
                    children: nil,
                    symbol: item.symbol
                ))
                if let children = item.children {
                    walk(children, prefix: label)
                }
            }
        }
        walk(folders, prefix: "")
        return result
    }

    private func startWatcher() {
        watcher?.stop()
        guard let rootURL else { return }
        let watcher = FileWatcher { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
        watcher.start(paths: [rootURL.path])
        self.watcher = watcher
    }

    private func present(_ error: Error) {
        errorPresenter(error)
    }
}

extension LibraryModel.SidebarItem {
    func token(relativeTo root: URL) -> String {
        switch self {
        case .all: return "all"
        case .inbox: return "inbox"
        case .untagged: return "untagged"
        case .trash: return "trash"
        case .project(let url):
            return "project:" + LibraryPaths.relativePath(of: url, to: root)
        case .tag(let name):
            return "tag:" + name
        case .note:
            return "all"
        }
    }

    static func from(token: String, root: URL) -> Self {
        switch token {
        case "all": return .all
        case "inbox": return .inbox
        case "untagged": return .untagged
        case "trash": return .trash
        default:
            if token.hasPrefix("project:") {
                let relative = String(token.dropFirst("project:".count))
                return .project(root.appendingPathComponent(relative, isDirectory: true))
            }
            if token.hasPrefix("tag:") {
                return .tag(String(token.dropFirst("tag:".count)))
            }
            if token.hasPrefix("note:") {
                return .all
            }
            return .all
        }
    }
}
