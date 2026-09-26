import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class IOSSession: ObservableObject {
    enum Sheet: Identifiable, Equatable {
        case capture
        case settings

        var id: String {
            switch self {
            case .capture: return "capture"
            case .settings: return "settings"
            }
        }
    }

    let library: LibraryModel
    @Published var path: [LibraryRoute] = [] {
        didSet { applyVisibleCollection() }
    }
    @Published var sheet: Sheet?
    @Published var isPickingFolder = false
    @Published var alertMessage: String?
    /// Bookmark exists but `restoreSavedRoot` has not run. Scene-create
    /// cannot afford that scan: iOS kills the process after 20s (`0x8BADF00D`).
    @Published var needsRestore: Bool

    init() {
        let library = LibraryModel.shared
        self.library = library
        needsRestore = library.settings.storageBookmark != nil
        library.errorPresenter = { [weak self] error in
            self?.alertMessage = error.localizedDescription
        }
        InboxBadge.applyLaunchDefault()
    }

    /// Share drafts waiting for restore or a folder. A list: two Publier
    /// before the library is open must not clobber each other.
    private var pendingInboxTexts: [String] = []
    /// `onOpenURL` can fire twice for one open; do not write two notes.
    private var lastInboxText: String?
    private var lastInboxAt: Date?

    /// After the first frame. A dead bookmark leaves `rootURL` nil (onboarding).
    func restoreIfNeeded() async {
        guard needsRestore else {
            finishRestore()
            return
        }
        await Task.yield()
        guard needsRestore else {
            finishRestore()
            return
        }
        _ = library.restoreSavedRoot()
        needsRestore = false
        finishRestore()
    }

    func handleOpenURL(_ url: URL) {
        guard InboxHandoff.isInboxURL(url) else { return }
        ingestPendingShares(urlBody: InboxHandoff.body(from: url))
    }

    private func enqueueInbox(_ text: String?, collapsingRecentDuplicate: Bool = true) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if collapsingRecentDuplicate,
           let last = lastInboxText, last == text,
           let at = lastInboxAt, Date().timeIntervalSince(at) < 2 {
            return
        }
        lastInboxText = text
        lastInboxAt = Date()
        if needsRestore {
            pendingInboxTexts.append(text)
            return
        }
        ingestInbox(text)
    }

    private func flushPendingInbox() {
        let pending = pendingInboxTexts
        pendingInboxTexts.removeAll()
        for text in pending {
            ingestInbox(text)
        }
    }

    /// Durable queue first (every item), then the marked pasteboard list,
    /// then a rescan so a file the extension already wrote appears even when
    /// both drains are empty. Cold launch: he posts, then taps the icon;
    /// `onOpenURL` often never fires.
    private func finishRestore() {
        flushPendingInbox()
        ingestPendingShares()
        InboxBadge.refresh()
    }

    /// Queue, pasteboard list and an optional `?body=` are fallbacks of the
    /// same shares — take the highest count per text, then skip copies the
    /// extension already wrote at Inbox (same `rawBody`, not trashed).
    private func ingestPendingShares(urlBody: String? = nil) {
        if library.rootURL != nil {
            library.reloadFromDisk()
        }
        var onDisk: [String: Int] = [:]
        let inboxFolder = library.store.root?.standardizedFileURL
        for record in library.store.notes where !record.isTrashed {
            guard let inboxFolder,
                  record.folderURL.standardizedFileURL == inboxFolder else { continue }
            onDisk[record.rawBody, default: 0] += 1
        }

        let queued = InboxShareQueue(defaults: AppGroup.defaults ?? .standard).drain()
        let pasted = InboxHandoff.takeQueue()
        var incoming: [String: Int] = [:]
        for item in queued { incoming[item, default: 0] += 1 }
        var pasteCounts: [String: Int] = [:]
        for item in pasted { pasteCounts[item, default: 0] += 1 }
        for (text, count) in pasteCounts {
            incoming[text] = max(incoming[text, default: 0], count)
        }
        if let urlBody, !urlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            incoming[urlBody] = max(incoming[urlBody, default: 0], 1)
        }

        var emitted: [String: Int] = [:]
        func emit(_ text: String) {
            let want = incoming[text, default: 0]
            guard emitted[text, default: 0] < want else { return }
            emitted[text, default: 0] += 1
            if onDisk[text, default: 0] > 0 {
                onDisk[text, default: 0] -= 1
                return
            }
            enqueueInbox(text, collapsingRecentDuplicate: false)
        }
        for item in queued { emit(item) }
        for item in pasted { emit(item) }
        if let urlBody { emit(urlBody) }

        guard library.rootURL != nil else { return }
        library.reloadFromDisk()
        InboxBadge.refresh()
    }

    /// Writes Inbox. Does not push the note or retarget `path`.
    /// With no library yet, the text is kept — not dropped: the pasteboard has
    /// already been consumed upstream, so returning here used to destroy what
    /// he shared. `openPickedFolder` replays it.
    private func ingestInbox(_ text: String) {
        guard library.rootURL != nil else {
            pendingInboxTexts.append(text)
            alertMessage = NSLocalizedString(
                "Choose the iCloud Drive folder that holds your notes. What you shared is kept until then.",
                comment: ""
            )
            return
        }
        _ = library.captureInboxNote(text: text)
        InboxBadge.refresh()
    }

    func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { break }
            openPickedFolder(url)
        case .failure(let error):
            alertMessage = error.localizedDescription
        }
        isPickingFolder = false
    }

    func openPickedFolder(_ url: URL) {
        // iOS bookmarks have no `.withSecurityScope`. Access must be live
        // before `bookmarkData`. Do not stop here: ScopedRoot owns the
        // session access, and a matching stop on this URL drops the library.
        _ = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try BookmarkStore.makeBookmark(for: url)
            library.openRoot(url, bookmark: bookmark)
        } catch {
            library.openRoot(url)
        }
        path = []
        // Shares that arrived before any folder existed waited in
        // `pendingInboxTexts`. This is the first moment they can be written.
        flushPendingInbox()
        InboxBadge.refresh()
    }

    /// Share-to-inbox: drain the durable queue and the pasteboard list, then
    /// rescan. A no-op if `onOpenURL` / restore already consumed them.
    func reloadIfActive() {
        ingestPendingShares()
    }

    /// Done and empty/cancel both leave `path` alone. Capture writes Inbox on
    /// disk; `captureInboxNote` also points the model at Inbox, so the visible
    /// collection is applied again from `path` (a no-op on the sources list).
    func dismissCapture() {
        sheet = nil
        applyVisibleCollection()
    }

    func popNoteIfTop(_ url: URL) {
        guard case .note(let top) = path.last else { return }
        guard top.standardizedFileURL == url.standardizedFileURL else { return }
        path.removeLast()
    }

    var selectedNoteURL: URL? {
        if case .note(let url) = path.last { return url.standardizedFileURL }
        return nil
    }

    func selectNote(_ url: URL) {
        let standardized = url.standardizedFileURL
        var next = path
        if case .note = next.last {
            next.removeLast()
        }
        next.append(.note(standardized))
        if next != path { path = next }
    }

    /// Sidebar `NavigationStack` in the split layout. A selected note stays
    /// in `path` so the detail pane does not pop when the list goes back.
    func replaceCollections(_ collections: [LibraryRoute]) {
        let current = path.filter(\.isCollection)
        guard collections != current else { return }
        let note = selectedNoteURL.map { LibraryRoute.note($0) }
        if collections.count < current.count {
            path = collections + (note.map { [$0] } ?? [])
        } else {
            path = collections
        }
    }

    /// Sources search lists the whole library. A collection keeps its route
    /// so cancelling the query cannot jump to All Notes.
    func setLibrarySearch(_ newValue: String) {
        let isEmpty = newValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let onSources = path.filter(\.isCollection).isEmpty
        if isEmpty, let route = path.last(where: { $0.isCollection }) {
            route.apply(to: library)
        }
        library.searchText = newValue
        if !isEmpty, onSources {
            activateAllNotesSearch()
        }
    }

    func applyVisibleCollection() {
        if let route = path.last(where: { $0.isCollection }) {
            route.apply(to: library)
            return
        }
        let query = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        activateAllNotesSearch()
    }

    private func activateAllNotesSearch() {
        if !library.selectedTags.isEmpty { library.selectedTags = [] }
        if library.sidebarSelection != .all { library.sidebarSelection = .all }
    }
}

extension View {
    func shokoFolderImporter(session: IOSSession) -> some View {
        fileImporter(
            isPresented: Binding(
                get: { session.isPickingFolder },
                set: { session.isPickingFolder = $0 }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: session.handleFolderImport
        )
    }
}

@main
@MainActor
struct ShokonotesIOSApp: App {
    @StateObject private var session = IOSSession()

    var body: some Scene {
        WindowGroup {
            IOSRootView(session: session, library: session.library)
        }
    }
}
