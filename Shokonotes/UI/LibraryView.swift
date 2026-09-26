import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var renameTarget: NoteSnapshot?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var folderRenameTarget: FolderSnapshot?
    @State private var folderRenameText = ""
    @State private var folderRenameError: String?
    @State private var permanentDeleteTarget: [NoteSnapshot]?
    @State private var folderDeleteTarget: FolderSnapshot?
    @State private var emptyingTrash = false
    /// The note whose row the tag popover hangs off, and the notes it edits.
    ///
    /// One state for the three row entry points — the left swipe, the context
    /// menu and ⌃⌘T — because they open the **same** editor and there is no
    /// second code path. The header chips are a fourth door and present the
    /// same `TagPopover` on the metadata bar (`headerTagEditorPresented`);
    /// opening either dismisses the other so only one editor is on screen.
    /// The row anchor is a row in `model.notes` rather than an arbitrary
    /// selected note: a popover needs a view to point at, and only the rows the
    /// list has built are there to be pointed at.
    @State private var tagEditorAnchor: URL?
    @State private var tagEditorNotes: [URL] = []
    @State private var headerTagEditorPresented = false
    @State private var folderDropRefusal: String?
    /// Bumped when a swipe action commits, so SwiftUI drops the presented swipe
    /// on that row only. The `ForEach` identity stays the note URL.
    @State private var swipeGenerations: [URL: Int] = [:]
    @FocusState private var pane: LibraryPane?
    /// So the preview-header chips can sit in the pane without becoming its
    /// default focus. Right-arrow from the note list must still land on the
    /// preview, not on a chip; Tab from the title field still reaches them.
    @Namespace private var previewFocus
    /// Bumped to move the keyboard into the folder column. The column is an
    /// `NSOutlineView` and its focus belongs to AppKit: `pane` is never
    /// `.sidebar`, and this token is the only door. See `SidebarSourceList`.
    @State private var sidebarFocusToken = 0
    /// Read here, in the view's own environment chain, and handed to the row
    /// backgrounds by value — see `NoteRowBackground`.
    @Environment(\.controlActiveState) private var activeState

    /// The note list wears the app's wash only while it holds the keyboard in a
    /// foreground window; otherwise the system grey, as in Notes.
    private var noteListIsEmphasized: Bool {
        model.focusedPane == .notes && activeState != .inactive
    }

    var body: some View {
        HSplitView {
            if model.sidebarVisible {
                sidebar
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 360, maxHeight: .infinity)
            }
            noteList
                .frame(minWidth: 340, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .background { Color(nsColor: .textBackgroundColor).ignoresSafeArea() }
                .layoutPriority(0)
            previewPane
                .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background { Color(nsColor: .textBackgroundColor).ignoresSafeArea() }
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $renameTarget) { note in
            renameSheet(for: note)
        }
        .sheet(item: $folderRenameTarget) { folder in
            folderRenameSheet(for: folder)
        }
        .confirmationDialog("Empty the Trash?", isPresented: $emptyingTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.trashCount) note(s) will be removed from disk. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(
                get: { permanentDeleteTarget != nil },
                set: { if !$0 { permanentDeleteTarget = nil } }
            ),
            presenting: permanentDeleteTarget
        ) { notes in
            Button("Delete Permanently", role: .destructive) {
                model.deletePermanently(notes)
                permanentDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) { permanentDeleteTarget = nil }
        } message: { notes in
            Text("\(notes.count) note(s) will be removed from disk. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete folder?",
            isPresented: Binding(
                get: { folderDeleteTarget != nil },
                set: { if !$0 { folderDeleteTarget = nil } }
            ),
            presenting: folderDeleteTarget
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                model.deleteFolder(folder)
                folderDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) { folderDeleteTarget = nil }
        } message: { folder in
            Text("Notes in “\(folder.name)” will be moved to the Trash. This cannot be undone for the folder itself.")
        }
        .onAppear {
            if model.rootURL != nil {
                model.reloadEverything()
            }
            if model.focusedNote == nil {
                focusSidebar()
            } else {
                pane = .notes
            }
        }
        // AppKit — the Find menu item, the search field — needs to know which
        // column the keyboard is in, and needs to be able to move it.
        //
        // **Non-nil only.** `focusSidebar()` sets `pane` to nil on purpose, so
        // that SwiftUI focuses nothing while the outline holds the keyboard;
        // copying that nil over would erase the mirror the sidebar just wrote.
        .onChange(of: pane) { _, value in
            guard let value else { return }
            model.focusedPane = value
        }
        // The same trap from the other side: the list can empty *while* it holds
        // the keyboard — the last note deleted, a search with no result, an empty
        // folder picked. Focus goes back to the sidebar rather than nowhere.
        .onChange(of: model.notes.isEmpty) { _, isEmpty in
            if isEmpty, model.focusedPane == .notes, model.sidebarVisible {
                focusSidebar()
            }
        }
        // And the third way to lose the keyboard: hiding the sidebar takes the
        // focused column out of the hierarchy, and showing it again brings back a
        // pane nothing has focused. Measured — after ⌃⌘S twice the library
        // answered no arrow key at all until the next mouse click.
        .onChange(of: model.sidebarVisible) { _, visible in
            if !visible, model.focusedPane == .sidebar {
                pane = model.notes.isEmpty ? .preview : .notes
            } else if visible, pane == nil {
                focusSidebar()
            }
        }
        .onChange(of: model.focusRequest) { _, request in
            guard let request else { return }
            if request == .sidebar {
                focusSidebar()
            } else {
                pane = request
            }
            model.focusRequest = nil
        }
        // A click in the preview: only the mirror is moved, not SwiftUI's focus.
        // Taking SwiftUI focus here would pull the first responder off the
        // preview host, which is the view that scrolls on the arrow keys.
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.previewTookFocus)) { _ in
            model.focusedPane = .preview
        }
        .onKeyPress(.escape) {
            guard !model.searchText.isEmpty else { return .ignored }
            model.searchText = ""
            LibraryWindowController.clearSearchField()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.storageDidChange)) { _ in
            model.scheduleRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.newNoteCommand)) { _ in
            model.createNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.newFolderCommand)) { _ in
            LibraryWindowController.promptNewFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.openExternalCommand)) { _ in
            model.openInExternalEditor(model.selectedNotes)
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.deleteCommand)) { _ in
            _ = deleteSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.renameCommand)) { _ in
            guard let note = model.focusedNote else { return }
            renameText = note.fileName
            renameError = nil
            renameTarget = note
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.matchFilenameCommand)) { _ in
            _ = model.matchFilenameToTitle(model.selectedNotes)
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.selectAllCommand)) { _ in
            model.selectAllVisibleNotes()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.printCommand)) { _ in
            if let note = model.focusedNote { model.printNote(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.revealCommand)) { _ in
            if model.focusedPane == .sidebar {
                model.revealSidebarSelectionInFinder()
            } else if !model.selectedNotes.isEmpty {
                model.revealInFinder(model.selectedNotes)
            } else {
                model.revealSidebarSelectionInFinder()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.pinCommand)) { _ in
            model.togglePin(model.selectedNotes)
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.shareCommand)) { _ in
            shareSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.exportPDFCommand)) { _ in
            exportSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.findNextCommand)) { _ in
            PreviewBridge.shared.findNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.findPreviousCommand)) { _ in
            PreviewBridge.shared.findPrevious()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.previewWantsNotesFocus)) { _ in
            pane = .notes
        }
        .onChange(of: pane) { _, new in
            if new == .preview {
                PreviewBridge.shared.becomeFirstResponder()
            }
        }
        .alert(
            "Could not move the folder",
            isPresented: Binding(
                get: { folderDropRefusal != nil },
                set: { if !$0 { folderDropRefusal = nil } }
            ),
            presenting: folderDropRefusal
        ) { _ in
            Button("OK", role: .cancel) { folderDropRefusal = nil }
        } message: { text in
            Text(text)
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryWindowController.editTagsCommand)) { _ in
            openTagEditor(for: model.selectedNotes)
        }
    }

    /// Dismisses the AppKit swipe banner, then runs `work` on the next turn.
    ///
    /// macOS `List` swipe actions are `NSTableViewRowAction`. AppKit tracks the
    /// revealed strip as a banner (`NSTableBannerRowData`) against a row index.
    /// A non-destructive swipe button does not collapse that banner; AppKit apps
    /// set `rowActionsVisible = false` in the handler. SwiftUI does not. Pin
    /// keeps the row and changes its index, so the banner must be gone before
    /// `OutlineListCoordinator` diffs.
    ///
    /// Sequence: `NoteListRowActions.dismiss()` now (never writes `true` — that
    /// throws); bump this row's swipe-session identity; then `work` after the
    /// current `CATransaction` commits the teardown. Pin/Unpin pass `reorders`
    /// so the move is not animated under a banner that just died.
    ///
    /// The note is captured **by value**.
    private func afterSwipeCloses(_ note: NoteSnapshot, reorders: Bool = false, _ work: @escaping () -> Void) {
        NoteListRowActions.dismiss()
        swipeGenerations[note.url, default: 0] += 1
        DispatchQueue.main.async {
            if reorders {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, work)
            } else {
                work()
            }
        }
    }

    /// The one way the tag editor is opened from a row, whichever of the three
    /// gestures asked for it. Dismisses the header's copy first so the two
    /// cannot stack.
    ///
    /// The anchor is the **first of the selection in list order**, so the popover
    /// points at the topmost of the rows it is about to change rather than at
    /// whichever one happened to be clicked last.
    private func openTagEditor(for notes: [NoteSnapshot]) {
        guard !notes.isEmpty else { return }
        let urls = Set(notes.map(\.url))
        guard let anchor = model.notes.first(where: { urls.contains($0.url) })?.url else { return }
        headerTagEditorPresented = false
        tagEditorNotes = notes.map(\.url)
        tagEditorAnchor = anchor
    }

    /// What the token field offers while a tag is being typed: the library's own
    /// tags, matched on the substring. Existing names and nothing else — this is
    /// the data the checkable list below already shows, reached from the keyboard.
    ///
    /// **This closure is the seam** for the *"Tag suggestions and tag hygiene"*
    /// lot. When the engine's ranked suggestion function lands, its body is
    /// replaced here and nowhere else; `TagPopover` and `TagTokenField` do not
    /// change. Nothing is invented in the meantime and nothing fake is stubbed.
    private func tagCompletions(_ substring: String) -> [String] {
        let needle = substring.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return model.tags.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// A real macOS source list, not a `List`: it is the only thing that can
    /// aim *between* two rows and so say at which level a dragged folder will
    /// land. Its keyboard belongs to AppKit — read the focus contract on
    /// `SidebarSourceList` before touching anything here.
    private var sidebar: some View {
        SidebarSourceList(
            model: model,
            focusToken: sidebarFocusToken,
            onTookFocus: { mirrorSidebarFocus() },
            onMoveToNotes: { pane = .notes },
            onRenameFolder: { folder in
                folderRenameText = folder.name
                folderRenameError = nil
                folderRenameTarget = folder
            },
            onDeleteFolder: { folderDeleteTarget = $0 },
            onEmptyTrash: { emptyingTrash = true },
            onFolderMoveRefused: { error in
                if let text = Self.refusalMessage(for: error) { folderDropRefusal = text }
            }
        )
        .frame(minWidth: 200)
    }

    /// The **one** way to move the keyboard into the folder column.
    ///
    /// # Why `pane = nil` comes first, and why it is not optional
    ///
    /// A click in the column works because the responder is moved by a real
    /// mouse event: SwiftUI *accepts* that loss and drops its own `@FocusState`.
    /// A programmatic `makeFirstResponder` while SwiftUI still believes it owns
    /// the focused view is a different thing entirely — its
    /// `FirstResponderObserver` sees the responder escape and **takes it back**.
    /// So the previous attempt, which left `pane` at `.notes` and relied on
    /// `mirrorSidebarFocus()` to clear it *after* `becomeFirstResponder`, was
    /// always going to lose the round: by then SwiftUI had already re-claimed.
    ///
    /// The fix is both halves at once. SwiftUI resigns **first**, here, and the
    /// outline takes the responder one turn **later**, from the single
    /// `DispatchQueue.main.async` behind the token door in `SidebarSourceList`
    /// — so the resignation has been delivered before AppKit moves.
    ///
    /// Note what falls out: with `pane` already nil and `focusedPane` already
    /// `.sidebar`, the `mirrorSidebarFocus()` that `becomeFirstResponder` calls
    /// next writes **nothing** — both its guards fail. No write, no update pass,
    /// no loop. The mirror does real work only on the click path, which is what
    /// it exists for.
    private func focusSidebar() {
        if pane != nil { pane = nil }
        if model.focusedPane != .sidebar { model.focusedPane = .sidebar }
        sidebarFocusToken += 1
    }

    /// The mirror, run when AppKit **already** has the keyboard: a click on the
    /// outline, the window becoming key, or the responder the token above just
    /// asked for. Deliberately **not** a variant of `focusSidebar()`: bumping
    /// the token here would ask AppKit to make a view that is already the first
    /// responder the first responder again, which is the first step of the loop.
    ///
    /// `pane` goes to nil rather than to `.sidebar`: SwiftUI must focus nothing
    /// at all while the outline holds the first responder. Writing it here is
    /// safe because the responder has already moved — SwiftUI has no focused
    /// view of its own left to resign, so the write ends the chain instead of
    /// starting a new one. Both writes are guarded so an unchanged state
    /// publishes nothing.
    ///
    /// On the **keyboard** path it is now silent by construction:
    /// `focusSidebar()` has already set `pane` to nil and `focusedPane` to
    /// `.sidebar`, so both guards fail and nothing is published. The click path
    /// is where it still does work.
    private func mirrorSidebarFocus() {
        if pane != nil { pane = nil }
        if model.focusedPane != .sidebar { model.focusedPane = .sidebar }
    }

    /// A refusal the human could not have predicted by looking. The hover
    /// already forbids what is structurally impossible, so in practice this is
    /// the name collision; `noChange` is a non-event and says nothing.
    private static func refusalMessage(for error: FolderMoveError) -> String? {
        switch error {
        case .intoDescendant:
            return NSLocalizedString(
                "A folder cannot be moved into itself or into one of its own folders.", comment: "")
        case .nameExists(let name):
            return String(
                format: NSLocalizedString(
                    "A folder named “%@” is already there. Rename one of them, then move it again.",
                    comment: ""),
                name)
        case .invalidDestination:
            return NSLocalizedString("That destination cannot hold a folder.", comment: "")
        case .noChange:
            return nil
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if model.rootURL == nil {
            ContentUnavailableView {
                Label("Choose a notes folder", systemImage: "folder.badge.plus")
            } description: {
                Text("Shokonotes reads Markdown files from a folder you pick. Editing happens in your own editor.")
            } actions: {
                Button("Choose Folder…") { model.chooseStorageFolder() }
                    .keyboardShortcut(.defaultAction)
                Button("Open Sample Library") { model.openSampleLibrary() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let note = model.focusedNote {
            VStack(spacing: 0) {
                NoteMetadataBar(
                    note: note,
                    model: model,
                    activeTags: model.selectedTags,
                    completions: tagCompletions,
                    tagEditorPresented: $headerTagEditorPresented,
                    onWillPresentTagEditor: { tagEditorAnchor = nil }
                )
                .prefersDefaultFocus(false, in: previewFocus)
                Divider()
                NotePreviewView(
                    note: note,
                    style: {
                        var style = settings.previewStyle
                        style.showTitle = false
                        return style
                    }(),
                    findQuery: model.previewFindQuery.isEmpty ? model.searchText : model.previewFindQuery
                )
                // Identity is the *style*, not the note and no longer the
                // appearance. The note comes in as a value and the host reloads
                // the document in the web view it already has; a style change
                // throws the host away, which is rare and is the cheap way to be
                // certain the page is repainted. The light / dark switch cannot
                // be an identity, because nothing publishes it to SwiftUI — the
                // host hears it from AppKit and reloads itself.
                .id(settings.previewStyle.cacheKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .prefersDefaultFocus(true, in: previewFocus)

                if model.previewFindVisible {
                    Divider()
                    PreviewFindBar(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusScope(previewFocus)
            .focusable()
            .focused($pane, equals: .preview)
            .onKeyPress(.leftArrow) {
                pane = .notes
                return .handled
            }
        } else if !model.selectedNotes.isEmpty {
            VStack(spacing: 12) {
                // Interpolated, not `String(format:)`: the `%lld notes selected`
                // key carries plural variations, and only the localized
                // interpolation APIs pick a form. Same key as the tag editor's
                // header — one entry for the translator, two places on screen.
                Text("\(model.selectedNotes.count) notes selected")
                    .foregroundStyle(.secondary)
                if model.selectedNotes.contains(where: \.fileStemDiffersFromTitle) {
                    Button("Rename file") {
                        _ = model.matchFilenameToTitle(model.selectedNotes)
                    }
                    .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focused($pane, equals: .preview)
            .onKeyPress(.leftArrow) {
                pane = .notes
                return .handled
            }
        } else {
            ContentUnavailableView {
                Label("Select a note", systemImage: "doc.text")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focused($pane, equals: .preview)
            .onKeyPress(.leftArrow) {
                pane = .notes
                return .handled
            }
        }
    }

    private var noteList: some View {
        List(selection: $model.selectedNoteIDs) {
            if model.isViewingTrash, model.trashCount > 0 {
                HStack {
                    Text("Notes in the Trash are removed from disk when emptied.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Empty") { emptyingTrash = true }
                }
                .padding(.vertical, 2)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .selectionDisabled()
            }

            if model.notes.isEmpty, (!model.searchText.isEmpty || !model.selectedTags.isEmpty) {
                Text("No results")
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .selectionDisabled()
            }

            ForEach(model.notes) { note in
                NoteRow(
                    note: note,
                    showExcerpt: model.settings.showExcerpt,
                    showDate: model.settings.showDate,
                    showTags: model.settings.showTagsInList,
                    showFolder: model.showsFolderOnRows,
                    compact: model.settings.compactRows,
                    activeTags: model.selectedTags
                )
                .tag(note.url)
                // No insets, and the selection given to the list as the row's
                // background: the chocolate then spans the whole row and takes
                // the place of the highlight the list would have drawn. The
                // padding lives inside `NoteRow`.
                .listRowInsets(EdgeInsets())
                .listRowBackground(
                    NoteRowBackground(
                        isSelected: model.selectedNoteIDs.contains(note.url),
                        isEmphasized: noteListIsEmphasized
                    )
                )
                .listRowSeparator(.hidden)
                // The editor hangs off the row it edits. One modifier per row
                // and one presented popover in the whole list: the binding is
                // true for exactly the anchor `openTagEditor` chose.
                .popover(
                    isPresented: Binding(
                        get: { tagEditorAnchor == note.url },
                        set: { if !$0 { tagEditorAnchor = nil } }
                    ),
                    arrowEdge: .trailing
                ) {
                    TagPopover(
                        urls: tagEditorNotes,
                        model: model,
                        completions: tagCompletions,
                        dismiss: { tagEditorAnchor = nil }
                    )
                }
                .draggable(NoteTransfer(url: note.url)) {
                    NoteRow(note: note, compact: true, activeTags: model.selectedTags).frame(width: 220)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        afterSwipeCloses(note) {
                            if model.isViewingTrash {
                                permanentDeleteTarget = [note]
                            } else {
                                model.delete([note])
                            }
                        }
                    } label: {
                        Label(model.isViewingTrash ? "Delete Permanently" : "Delete", systemImage: "trash")
                    }
                }
                // Full swipe would commit Pin while the banner is still in flight.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if model.isViewingTrash {
                        Button {
                            afterSwipeCloses(note) { model.restore([note]) }
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    } else {
                        Button {
                            afterSwipeCloses(note, reorders: true) { model.togglePin([note]) }
                        } label: {
                            Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                        // The swipe acts on the row it was made on, not on the
                        // selection: a swipe names its own note, the way Mail's
                        // does, and tagging nine other notes because they happened
                        // to be selected would be a surprise.
                        Button {
                            afterSwipeCloses(note) { openTagEditor(for: [note]) }
                        } label: {
                            Label("Tags…", systemImage: "tag")
                        }
                    }
                }
                .id(NoteListSwipeSession(url: note.url, generation: swipeGenerations[note.url, default: 0]))
            }
        }
        .listStyle(.plain)
        .onKeyPress(.return) {
            let notes = model.selectedNotes
            guard !notes.isEmpty else { return .ignored }
            model.openInExternalEditor(notes)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard model.sidebarVisible else { return .ignored }
            focusSidebar()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            pane = .preview
            PreviewBridge.shared.becomeFirstResponder()
            return .handled
        }
        .onKeyPress(.delete) { deleteSelection() }
        .onKeyPress(.deleteForward) { deleteSelection() }
        .onKeyPress(keys: ["a"]) { press in
            let flags = press.modifiers.intersection([.command, .control, .option, .shift])
            guard flags == .command || flags == .control else { return .ignored }
            model.selectAllVisibleNotes()
            return .handled
        }
        // Typing in the list starts a library search. Menu chords (⌘F, ⌘A, …)
        // stay with the menu; arrows, Return, Delete, Escape, and Tab are not
        // characters this accepts. Space is a folder action on the sidebar,
        // not on the list.
        .onKeyPress(phases: .down) { press in
            let flags = press.modifiers
            guard let text = LibraryKeyboard.searchInsertion(
                characters: press.characters,
                command: flags.contains(.command),
                control: flags.contains(.control),
                option: flags.contains(.option)
            ) else { return .ignored }
            LibraryWindowController.beginSearch(inserting: text)
            return .handled
        }
        .focused($pane, equals: .notes)
        .focusingPaneOnClick { pane = .notes }
        .contextMenu(forSelectionType: URL.self) { ids in
            noteContextMenu(for: ids.compactMap { model.note(with: $0) })
        } primaryAction: { ids in
            model.openInExternalEditor(ids.compactMap { model.note(with: $0) })
        }
        // The header goes on **outside** `.focused`, and that ordering is the
        // whole point. Inside it, the header's button was the first focusable
        // thing in the pane's focus scope, so the right arrow from the sidebar
        // landed the keyboard on it instead of on a row: the button took the
        // focus ring, the list's `onKeyPress` handlers never ran again, and
        // neither arrows nor clicks reached the rows until a toolbar button
        // broke the deadlock. Measured on the installed build.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.collectionTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if model.selectedNotes.contains(where: \.fileStemDiffersFromTitle) {
                    Button {
                        _ = model.matchFilenameToTitle(model.selectedNotes)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Rename file")
                    .accessibilityLabel("Rename file")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.background)
        }
        .frame(minWidth: 260)
    }

    @ViewBuilder
    private func noteContextMenu(for notes: [NoteSnapshot]) -> some View {
        if !notes.isEmpty {
            Button("Open External") { model.openInExternalEditor(notes) }

            if notes.count == 1, let note = notes.first {
                Button("Rename…") {
                    renameText = note.fileName
                    renameError = nil
                    renameTarget = note
                }
            }
            if notes.contains(where: \.fileStemDiffersFromTitle) {
                Button("Rename file") {
                    _ = model.matchFilenameToTitle(notes)
                }
            }

            Divider()

            // One item, not a submenu of every tag in the library. The submenu
            // could check and uncheck but could not create, and its "New Tag…"
            // opened a blind text field; both are `TagPopover` now, and a menu
            // that grows a line per tag was never going to survive a real
            // library anyway.
            Button("Tags…") { openTagEditor(for: notes) }

            Menu("Move") {
                if let root = model.rootURL {
                    Button { model.move(notes, to: root) } label: { Text("Inbox") }
                }
                ForEach(model.allFoldersFlat()) { folder in
                    Button(folder.name) { model.move(notes, to: folder.url) }
                }
            }

            Divider()

            Button(notes.allSatisfy(\.isPinned) ? "Unpin" : "Pin") {
                model.togglePin(notes)
            }

            if !model.isViewingTrash {
                let items = notes.map { Favourite.note($0.relativePath) }
                let allFavourite = items.allSatisfy(model.isFavourite)
                Button(allFavourite ? "Remove from Favourites" : "Add to Favourites") {
                    if allFavourite {
                        items.forEach { model.removeFavourite($0) }
                    } else {
                        items.filter { !model.isFavourite($0) }.forEach { model.addFavourite($0) }
                    }
                }
            }

            Button("Reveal in Finder") { model.revealInFinder(notes) }

            if notes.count == 1, let note = notes.first {
                Button("Print…") { model.printNote(note) }
                // Single note only: with several selected, the entry is absent
                // rather than queueing one save panel per note.
                Button("Export as PDF…") {
                    NoteExport.exportPDF(note, in: LibraryWindowController.currentWindow)
                }
                ShareLink(item: note.url) { Text("Share…") }
            }

            Divider()

            if model.isViewingTrash {
                Button("Restore") { model.restore(notes) }
                Button("Delete Permanently", role: .destructive) {
                    permanentDeleteTarget = notes
                }
            } else {
                Button("Delete", role: .destructive) { model.delete(notes) }
            }
        }
    }

    private func renameSheet(for note: NoteSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commitRename(note) }
            if let renameError {
                Text(renameError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(width: 320, alignment: .leading)
            }
            Text("The name becomes the file name. A YAML title is updated when present.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Rename") { commitRename(note) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func folderRenameSheet(for folder: FolderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Folder").font(.headline)
            TextField("Name", text: $folderRenameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commitFolderRename(folder) }
            if let folderRenameError {
                Text(folderRenameError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(width: 320, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { folderRenameTarget = nil }
                Button("Rename") { commitFolderRename(folder) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    /// `focusedNote` is nil unless exactly one note is selected, so this is the
    /// single-note path by construction. The save panel, its file name and any
    /// failure all belong to `NoteExport`; nothing is re-presented here.
    private func exportSelection() {
        guard let note = model.focusedNote else { return }
        NoteExport.exportPDF(note, in: LibraryWindowController.currentWindow)
    }

    private func shareSelection() {
        guard let note = model.focusedNote else { return }
        // Prefer the share toolbar button so the picker pops from the capsule
        // rather than the whole window. The content view is only the fallback
        // for a File menu invocation before that button has a view.
        guard let view = LibraryWindowController.shareToolbarItemView
                ?? LibraryWindowController.currentWindow?.contentView else { return }
        LibraryWindowController.presentSharePicker(for: note.url, relativeTo: view)
    }

    private func deleteSelection() -> KeyPress.Result {
        let notes = model.selectedNotes
        guard !notes.isEmpty else { return .ignored }
        if model.isViewingTrash {
            permanentDeleteTarget = notes
        } else {
            model.delete(notes)
        }
        return .handled
    }

    private func commitRename(_ note: NoteSnapshot) {
        if let message = model.rename(note, to: renameText) {
            renameError = message
            return
        }
        renameTarget = nil
    }

    private func commitFolderRename(_ folder: FolderSnapshot) {
        if let message = model.renameFolder(folder, to: folderRenameText) {
            folderRenameError = message
            return
        }
        folderRenameTarget = nil
    }
}
