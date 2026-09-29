import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the source list. A class, because `NSOutlineView` identifies its
/// rows by object identity.
final class SidebarNode {
    enum Role: Equatable {
        /// All Notes, Inbox, Untagged, Trash.
        case fixed
        /// A "Folders" / "Tags" / "Favourites" section header.
        case header
        case folder
        case tag
        /// A shortcut in Favourites. Same `item` as the original row; no children.
        case favourite
    }

    let role: Role
    /// What selecting this row selects. Nil on a header, which is not selectable.
    let item: LibraryModel.SidebarItem?
    /// Already localized.
    let title: String
    let symbol: String?
    /// Shown on the right. Nil, or zero, draws nothing.
    let count: Int?
    /// The folder this row stands for as a drop destination: a folder's own URL,
    /// the library root for the Inbox row.
    let destination: URL?
    let folder: FolderSnapshot?
    var children: [SidebarNode]

    var folderURL: URL? { folder?.url }

    init(
        role: Role,
        item: LibraryModel.SidebarItem?,
        title: String,
        symbol: String? = nil,
        count: Int? = nil,
        destination: URL? = nil,
        folder: FolderSnapshot? = nil,
        children: [SidebarNode] = []
    ) {
        self.role = role
        self.item = item
        self.title = title
        self.symbol = symbol
        self.count = count
        self.destination = destination
        self.folder = folder
        self.children = children
    }
}

/// The folder column, as a real macOS source list.
///
/// It replaced a SwiftUI `List`, for one reason: a `List` cannot aim *between*
/// two rows, so there was no way to say at which level a dragged folder would
/// land — and its per-row drop targets sat behind the per-row indentation
/// padding, so the target of a nested folder was offset from the row the human
/// saw. `NSOutlineView` answers both in one delegate method,
/// `validateDrop:proposedItem:proposedChildIndex:`.
///
/// # The focus contract — do not loosen it
///
/// **The keyboard of this column belongs to AppKit, and to AppKit alone.**
///
/// An earlier attempt at this panel hung the app: main thread at 100 %, 1.1 GB,
/// dead in 45 seconds. `.focused($pane, equals: .sidebar)` on the representable
/// made SwiftUI hand the first responder to the enclosing `NSScrollView`;
/// `updateNSView` then saw `isFocused` and called `makeFirstResponder(outline)`
/// on **every** pass; the outline's `becomeFirstResponder` wrote SwiftUI state,
/// which scheduled another pass, in which SwiftUI found its focused view was no
/// longer the responder and took it back. No fixed point, ever.
///
/// So:
///
/// 1. This view carries **no** `.focused(...)` and is the target of no
///    `@FocusState`. No `focusingPaneOnClick` either — clicking an
///    `NSOutlineView` already makes it the first responder.
/// 2. `focusToken` is the **only** door to `makeFirstResponder`. `updateNSView`
///    acts only when the token differs from the one the coordinator remembers,
///    and remembers the new one first. Never on an ordinary update pass.
///
///    Behind that door the responder is taken from a `DispatchQueue.main.async`
///    — **one send per token change, never one per update pass**. That
///    distinction is the whole difference from the hang: what killed the app
///    was a rendezvous *rescheduled on every pass*, a loop with no fixed point.
///    Here the token is recorded **before** anything is scheduled (never inside
///    the block), and `focusDispatchInFlight` keeps a single block in the air:
///    a second token bump while one is pending updates the target token instead
///    of stacking a second block. The delay is what the fix needs: SwiftUI's
///    `pane = nil`, written in `focusSidebar()` before the token bump, must be
///    *delivered* before AppKit moves the responder, or SwiftUI's
///    `FirstResponderObserver` takes it straight back.
/// 3. `becomeFirstResponder` calls `onTookFocus`, which writes the SwiftUI
///    mirror **only when it differs** — and bumps no token, so it cannot come
///    back around.
///
/// `LibraryModel.focusedPane` is `@Published`: writing it re-runs
/// `updateNSView`. That is exactly why the token has to be the only door.
struct SidebarSourceList: NSViewRepresentable {
    let model: LibraryModel
    /// Bumped by `LibraryView.focusSidebar()` to move the keyboard here. See
    /// the focus contract above.
    let focusToken: Int
    /// The outline took the first responder on its own — a click, or the window
    /// becoming key. Mirrors the focus into SwiftUI; moves nothing.
    let onTookFocus: () -> Void
    /// The right arrow leaving the column for a non-empty note list.
    let onMoveToNotes: () -> Void
    let onRenameFolder: (FolderSnapshot) -> Void
    let onDeleteFolder: (FolderSnapshot) -> Void
    let onEmptyTrash: () -> Void
    let onFolderMoveRefused: (FolderMoveError) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        // The gutter a childless folder keeps and the per-level step are the
        // same number on purpose: the disclosure triangle lives in the
        // indentation, so every name in the column starts on one vertical.
        outline.indentationPerLevel = 16
        outline.indentationMarkerFollowsCell = true
        outline.autoresizesOutlineColumn = false
        outline.allowsTypeSelect = true
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = true
        outline.focusRingType = .none
        outline.draggingDestinationFeedbackStyle = .sourceList
        // The folder column has **one** background layer, and it is never this
        // outline's: in the default mode it is the system sidebar's (Liquid
        // Glass on macOS 26 and later), in the opaque-sidebar mode the window's
        // `OpaqueBackdropView`. Nothing goes behind this outline — if the column
        // reads too light or too dark, that is the system's, or the backdrop's
        // colour in `LibraryWindowController`, not something to fix here. The
        // selection and text colours below are all AppKit semantic colours, so
        // they hold on either background.
        outline.backgroundColor = .clear

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.onTookFocus = { context.coordinator.parent.onTookFocus() }
        outline.onRightArrow = { context.coordinator.rightArrow() }
        outline.onLeftArrow = { context.coordinator.leftArrow() }
        outline.onSpace = { context.coordinator.space() }
        outline.contextMenuForRow = { context.coordinator.menu(forRow: $0) }

        // Move is the folder tree; copy/generic is favouriting. The destination
        // picks, so a tree drop still returns `.move` and never `moveFolder`s
        // from a favourite shortcut.
        outline.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.shokonotesFolder.identifier),
            NSPasteboard.PasteboardType(UTType.shokonotesNote.identifier),
            NSPasteboard.PasteboardType(UTType.shokonotesTag.identifier),
            NSPasteboard.PasteboardType(UTType.shokonotesFavourite.identifier),
        ])

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder

        context.coordinator.outline = outline
        context.coordinator.rebuild(force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.rebuild(force: false)

        // The one door to the first responder. The token is remembered *before*
        // anything is scheduled — never inside the block — so a state write
        // triggered by the focus change cannot bring us back here for a second
        // attempt.
        guard focusToken != coordinator.appliedFocusToken else { return }
        coordinator.appliedFocusToken = focusToken
        guard let outline = coordinator.outline else { return }
        guard outline.window != nil else {
            // Asked for before the view was in a window: taken once on attach,
            // not retried on a timer.
            outline.wantsFocusOnAttach = true
            return
        }

        // One send in the air at a time. A newer token arriving while this one
        // is pending has already been written to `appliedFocusToken` above, and
        // the pending block reads that latest value when it runs — so it cannot
        // stack a second block, and it cannot deliver a stale request either.
        guard !coordinator.focusDispatchInFlight else { return }
        coordinator.focusDispatchInFlight = true
        DispatchQueue.main.async { [weak coordinator] in
            guard let coordinator else { return }
            coordinator.focusDispatchInFlight = false
            let token = coordinator.appliedFocusToken
            guard token != coordinator.deliveredFocusToken else { return }
            guard let outline = coordinator.outline, let window = outline.window else { return }
            coordinator.deliveredFocusToken = token
            window.makeFirstResponder(outline)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: SidebarSourceList
        weak var outline: SidebarOutlineView?
        /// The latest focus request seen by `updateNSView`. Written there,
        /// synchronously, before anything is scheduled.
        var appliedFocusToken = 0
        /// The last request actually handed to `makeFirstResponder`.
        var deliveredFocusToken = 0
        /// A single hand-off in the air at a time — see the focus contract.
        var focusDispatchInFlight = false

        private var roots: [SidebarNode] = []
        private var fingerprint = StructureFingerprint()
        /// Guards against selection → notification → selection and the same
        /// loop for the disclosure state.
        private var isApplyingSelection = false
        private var isApplyingExpansion = false
        /// What is actually being dragged, for the length of one session.
        /// Cleared on **every** ending — cancelled, dropped outside, refused —
        /// which is the leak that made the second drag of a session unresponsive.
        /// A tag or favourite drag must not leave a folder URL here: that would
        /// make the next folder drag think a folder is in flight.
        private var draggedKind: SidebarDragKind?
        /// A drag session is in flight, so the tree must hold still. Same
        /// lifetime as `draggedKind`: raised in `willBeginAt`, lowered in
        /// `endedAt`. See `rebuild(force:)`.
        private var isDragging = false
        /// Last routed drop, taken in `validateDrop` and performed in `acceptDrop`.
        private var pendingDrop: SidebarRoutedPlan?
        /// The row the keyboard is on when the same `SidebarItem` is selected
        /// twice (favourite + original). `selectedRow` after dual-highlight is
        /// whichever index AppKit picked from the set, which is not the click.
        private var keyboardRole: SidebarNode.Role?
        private var keyboardItem: LibraryModel.SidebarItem?
        private var symbolPopover: NSPopover?

        private var model: LibraryModel { parent.model }

        init(_ parent: SidebarSourceList) {
            self.parent = parent
            super.init()
        }

        // MARK: - Tree

        /// Rebuilds only when the tree actually changed. This is called on every
        /// SwiftUI pass — a keystroke in the search field, a count changing, an
        /// activation.
        ///
        /// **Nothing happens while a drag is in flight.** Not the fingerprint
        /// check, not the reload, not the selection or disclosure mirroring. A
        /// watcher refresh needs no human to arrive: `FileWatcher` →
        /// `scheduleRefresh` changes the counts on its own, and every write to
        /// `focusedPane` or `selectedNoteIDs` re-runs `updateNSView`. Reloading
        /// under the open session resets the feedback and replaces every
        /// `SidebarNode`, including the one AppKit retargeted through
        /// `setDropItem` and hands back to `acceptDrop`. `endedAt` lowers the
        /// flag and then rebuilds unconditionally, so whatever was refused here
        /// is caught up at the end of the drag rather than at the next pass.
        func rebuild(force: Bool) {
            guard !isDragging else { return }
            let next = StructureFingerprint(model)
            guard force || next != fingerprint else {
                applyExpansion()
                applySelection()
                return
            }
            fingerprint = next
            roots = buildRoots()
            outline?.reloadData()
            applyExpansion()
            applySelection()
        }

        /// Everything the column draws that is not selection or disclosure: the
        /// folder tree, the tag list, the favourites, the three counts, the library root.
        ///
        /// It holds the model's **values** and lets the compiler compare them.
        /// The string key it replaced was rebuilt on every pass — one
        /// interpolation per folder, allocated and thrown away — and
        /// `updateNSView` runs on every SwiftUI pass, so moving the selection
        /// down the note list paid for the whole tree at each keystroke.
        /// `FolderSnapshot` and `String` are `Equatable`, and an untouched
        /// `@Published` array hands back the same storage, so the common answer
        /// ("nothing changed") costs an identity check on each array instead of
        /// a walk.
        ///
        /// It detects exactly what the key detected. Order, nesting and paths
        /// come from `folders` compared element by element; `symbol` is a stored
        /// field of `FolderSnapshot`; `name` and `parentURL` ride along, and
        /// they are functions of the URL and of the tree, so they add no
        /// wake-up of their own — a folder whose name changed is a folder whose
        /// URL changed.
        private struct StructureFingerprint: Equatable {
            var root: URL?
            var inbox = 0
            var untagged = 0
            var trash = 0
            var tags: [String] = []
            var folders: [FolderSnapshot] = []
            var favourites: [Favourite] = []
            /// Live titles of favourite notes, so a YAML rename redraws the row.
            var favouriteNoteTitles: [String] = []

            init() {}

            @MainActor
            init(_ model: LibraryModel) {
                root = model.rootURL
                inbox = model.inboxCount
                untagged = model.untaggedCount
                trash = model.trashCount
                tags = model.tags
                folders = model.folders
                favourites = model.favourites
                favouriteNoteTitles = model.favourites.compactMap { item in
                    guard case .note(let path) = item else { return nil }
                    return model.note(relativePath: path)?.title ?? item.displayName
                }
            }
        }

        private func buildRoots() -> [SidebarNode] {
            var nodes: [SidebarNode] = [
                SidebarNode(
                    role: .fixed, item: .all,
                    title: NSLocalizedString("All Notes", comment: ""), symbol: "tray.full"),
                // The Inbox row is the notes folder itself, so it is where a
                // folder goes back to the top level of the library.
                SidebarNode(
                    role: .fixed, item: .inbox,
                    title: NSLocalizedString("Inbox", comment: ""), symbol: "tray",
                    count: model.inboxCount, destination: model.rootURL),
                SidebarNode(
                    role: .fixed, item: .untagged,
                    title: NSLocalizedString("Untagged", comment: ""), symbol: "tag.slash",
                    count: model.untaggedCount),
                SidebarNode(
                    role: .fixed, item: .trash,
                    title: NSLocalizedString("Trash", comment: ""), symbol: "trash",
                    count: model.trashCount),
            ]

            if !model.favourites.isEmpty {
                nodes.append(
                    SidebarNode(
                        role: .header, item: nil,
                        title: NSLocalizedString("Favourites", comment: ""),
                        children: favouriteNodes(model.favourites)))
            }
            if !model.folders.isEmpty {
                nodes.append(
                    SidebarNode(
                        role: .header, item: nil,
                        title: NSLocalizedString("Folders", comment: ""),
                        children: folderNodes(model.folders)))
            }
            if !model.tags.isEmpty {
                nodes.append(
                    SidebarNode(
                        role: .header, item: nil,
                        title: NSLocalizedString("Tags", comment: ""),
                        children: model.tags.map { tag in
                            SidebarNode(role: .tag, item: .tag(tag), title: tag, symbol: "tag")
                        }))
            }
            return nodes
        }

        private func folderNodes(_ folders: [FolderSnapshot]) -> [SidebarNode] {
            folders.map { folder in
                SidebarNode(
                    role: .folder,
                    item: .project(folder.url),
                    title: folder.name,
                    symbol: FolderSymbolCatalogue.resolved(folder.symbol),
                    destination: folder.url,
                    folder: folder,
                    children: folderNodes(folder.children ?? []))
            }
        }

        /// Display order is `model.favourites` already. The UI does not sort.
        private func favouriteNodes(_ items: [Favourite]) -> [SidebarNode] {
            items.compactMap { favourite in
                switch favourite {
                case .folder(let path):
                    guard let root = model.rootURL else { return nil }
                    let url = root.appendingPathComponent(path, isDirectory: true)
                    let folder = LibraryKeyboard.folder(url, in: model.folders)
                    let resolved = folder?.url ?? url
                    return SidebarNode(
                        role: .favourite,
                        item: .project(resolved),
                        title: folder?.name ?? favourite.displayName,
                        symbol: FolderSymbolCatalogue.resolved(folder?.symbol),
                        destination: resolved,
                        folder: folder,
                        children: [])
                case .tag(let name):
                    return SidebarNode(
                        role: .favourite,
                        item: .tag(name),
                        title: name,
                        symbol: "tag",
                        children: [])
                case .note(let path):
                    guard let root = model.rootURL else { return nil }
                    let snapshot = model.note(relativePath: path)
                    let url = (snapshot?.url ?? root.appendingPathComponent(path)).standardizedFileURL
                    return SidebarNode(
                        role: .favourite,
                        item: .note(url),
                        title: snapshot?.title ?? favourite.displayName,
                        symbol: "note.text",
                        destination: nil,
                        children: [])
                }
            }
        }

        private var foldersHeader: SidebarNode? {
            roots.first { $0.role == .header && $0.children.first?.role == .folder }
        }

        private var favouritesHeader: SidebarNode? {
            roots.first { $0.role == .header && $0.children.first?.role == .favourite }
        }

        private func node(for item: LibraryModel.SidebarItem) -> SidebarNode? {
            func walk(_ nodes: [SidebarNode]) -> SidebarNode? {
                for node in nodes {
                    if Self.sameItem(node.item, item) { return node }
                    if let found = walk(node.children) { return found }
                }
                return nil
            }
            return walk(roots)
        }

        private func node(role: SidebarNode.Role, item: LibraryModel.SidebarItem) -> SidebarNode? {
            func walk(_ nodes: [SidebarNode]) -> SidebarNode? {
                for node in nodes {
                    if node.role == role, Self.sameItem(node.item, item) { return node }
                    if let found = walk(node.children) { return found }
                }
                return nil
            }
            return walk(roots)
        }

        /// Every row whose `item` matches — favourite and original together.
        private func nodes(matching item: LibraryModel.SidebarItem) -> [SidebarNode] {
            var result: [SidebarNode] = []
            func walk(_ nodes: [SidebarNode]) {
                for node in nodes {
                    if Self.sameItem(node.item, item) { result.append(node) }
                    walk(node.children)
                }
            }
            walk(roots)
            return result
        }

        /// A folder selection is compared on the **standardized** path. The
        /// model writes `.project(url)` from three places — a click here, a
        /// restored session token, the remap after a move — and a `/private`
        /// prefix or a trailing slash between two of them would leave a selected
        /// folder with no row and no highlight.
        private static func sameItem(_ lhs: LibraryModel.SidebarItem?, _ rhs: LibraryModel.SidebarItem) -> Bool {
            if case .project(let left) = lhs, case .project(let right) = rhs {
                return left.standardizedFileURL == right.standardizedFileURL
            }
            if case .note(let left) = lhs, case .note(let right) = rhs {
                return left.standardizedFileURL == right.standardizedFileURL
            }
            return lhs == rhs
        }

        // MARK: - Selection and disclosure, mirrored from the model

        private func applyExpansion() {
            guard let outline else { return }
            isApplyingExpansion = true
            defer { isApplyingExpansion = false }
            let expanded = Set(model.expandedFolders.map(\.standardizedFileURL))
            // Headers first, and top down: a row inside a collapsed parent has
            // no place in the outline yet.
            func walk(_ nodes: [SidebarNode]) {
                for node in nodes {
                    switch node.role {
                    case .header:
                        outline.expandItem(node)
                    case .folder where !node.children.isEmpty:
                        guard let url = node.folderURL?.standardizedFileURL else { break }
                        if expanded.contains(url) {
                            outline.expandItem(node)
                        } else {
                            outline.collapseItem(node)
                        }
                    default:
                        break
                    }
                    walk(node.children)
                }
            }
            walk(roots)
        }

        private func applySelection() {
            guard let outline else { return }
            let wanted = indexes(
                for: SidebarTagSelection.Resolution(
                    collection: model.sidebarSelection,
                    tags: model.selectedTags
                )
            )
            guard wanted != outline.selectedRowIndexes else { return }
            isApplyingSelection = true
            defer { isApplyingSelection = false }
            if wanted.isEmpty {
                // The selected folder is hidden inside a collapsed parent, or
                // gone. Either way the column must not keep a stale highlight.
                outline.deselectAll(nil)
            } else {
                outline.selectRowIndexes(wanted, byExtendingSelection: false)
                if let role = keyboardRole, let item = keyboardItem,
                   let node = node(role: role, item: item) {
                    let row = outline.row(forItem: node)
                    if row >= 0 { outline.scrollRowToVisible(row) }
                } else if let row = wanted.first {
                    outline.scrollRowToVisible(row)
                }
            }
        }

        /// The collection row plus every selected tag row, plus favourite note
        /// rows whose URL is in `selectedNoteIDs`. Tag-only is refused: if the
        /// collection is not on screen, tags stay dark. A favourite note still
        /// lights — its folder row may be collapsed.
        ///
        /// A favourite is a shortcut, not a copy: when the same `SidebarItem`
        /// appears twice, **every** matching row highlights, not the first
        /// `node(for:)`.
        private func indexes(for resolution: SidebarTagSelection.Resolution) -> IndexSet {
            guard let outline else { return IndexSet() }
            var collection = resolution.collection
            let tags = resolution.tags
            if collection == .untagged, !tags.isEmpty {
                collection = .all
            }
            switch collection {
            case .tag, .note:
                collection = .all
            default:
                break
            }
            var result = IndexSet()
            var foundCollection = false
            for node in nodes(matching: collection) {
                let row = outline.row(forItem: node)
                if row >= 0 {
                    result.insert(row)
                    foundCollection = true
                }
            }
            if foundCollection {
                for name in tags {
                    for node in nodes(matching: .tag(name)) {
                        let row = outline.row(forItem: node)
                        if row >= 0 { result.insert(row) }
                    }
                }
            }
            for url in model.selectedNoteIDs {
                for node in nodes(matching: .note(url)) where node.role == .favourite {
                    let row = outline.row(forItem: node)
                    if row >= 0 { result.insert(row) }
                }
            }
            return result
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? SidebarNode { return node.children[index] }
            return roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? SidebarNode)?.children.isEmpty ?? true)
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? SidebarNode)?.role == .header
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? SidebarNode)?.item != nil
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
        ) -> IndexSet {
            if isApplyingSelection { return proposedSelectionIndexes }
            rememberKeyboard(from: proposedSelectionIndexes, in: outlineView)
            if let node = aimedRowNode(from: proposedSelectionIndexes, in: outlineView),
               node.role == .favourite,
               case .note = node.item,
               let favourite = favouriteItem(from: node) {
                // Jumping is the meaning of this row, including ⌘-click and arrows.
                model.revealFavouriteNote(favourite)
                var result = indexes(
                    for: SidebarTagSelection.Resolution(
                        collection: model.sidebarSelection,
                        tags: model.selectedTags
                    )
                )
                let row = outlineView.row(forItem: node)
                if row >= 0 { result.insert(row) }
                return result
            }
            let proposed = proposedSelectionIndexes.compactMap { row -> SidebarTagSelection.Kind? in
                guard let node = outlineView.item(atRow: row) as? SidebarNode,
                      let item = node.item else { return nil }
                return SidebarTagSelection.Kind.of(item)
            }
            let resolved = SidebarTagSelection.resolve(
                proposed: proposed,
                currentCollection: model.sidebarSelection,
                currentTags: model.selectedTags,
                modifier: SidebarTagSelection.modifier(from: NSEvent.modifierFlags)
            )
            return indexes(for: resolved)
        }

        /// Dual-highlight selects both the favourite and the original. The row
        /// the user aimed at is the one that was *proposed*, not the first of
        /// the resolved set — that is what Space / arrows must follow.
        private func rememberKeyboard(from proposed: IndexSet, in outline: NSOutlineView) {
            guard let node = aimedRowNode(from: proposed, in: outline),
                  node.item != nil else { return }
            keyboardRole = node.role
            keyboardItem = node.item
        }

        /// The row the user aimed at: the added row, else the single proposed row.
        private func aimedRowNode(from proposed: IndexSet, in outline: NSOutlineView) -> SidebarNode? {
            let added = proposed.subtracting(outline.selectedRowIndexes)
            let pick = added.first ?? proposed.first
            guard let row = pick else { return nil }
            return outline.item(atRow: row) as? SidebarNode
        }

        /// The sections are furniture, not content: they stay open.
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            (item as? SidebarNode)?.role != .header
        }

        /// A row view of our own, so the cell can be told when the row becomes
        /// selected without becoming emphasized — see `SidebarRowView`.
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("sidebarRow")
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView {
                return reused
            }
            let view = SidebarRowView()
            view.identifier = identifier
            return view
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier(node.role == .header ? "header" : "row")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
                ?? SidebarCellView(isHeader: node.role == .header, identifier: identifier)
            view.configure(node)
            return view
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let outline else { return }
            var collections: [LibraryModel.SidebarItem] = []
            var tags = Set<String>()
            for row in outline.selectedRowIndexes {
                guard let node = outline.item(atRow: row) as? SidebarNode,
                      let item = node.item else { continue }
                switch item {
                case .tag(let name):
                    tags.insert(name)
                case .note:
                    break
                default:
                    collections.append(item)
                }
            }
            let collection: LibraryModel.SidebarItem
            if let match = collections.first(where: {
                SidebarTagSelection.sameCollection($0, model.sidebarSelection)
            }) {
                collection = match
            } else if let first = collections.first {
                collection = first
            } else {
                collection = model.sidebarSelection
            }
            if case .tag = collection { return }
            if case .note = collection { return }
            if model.sidebarSelection != collection {
                model.sidebarSelection = collection
            }
            if model.selectedTags != tags {
                model.selectedTags = tags
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            recordDisclosure(notification, expanded: true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            recordDisclosure(notification, expanded: false)
        }

        private func recordDisclosure(_ notification: Notification, expanded: Bool) {
            guard !isApplyingExpansion,
                  let node = notification.userInfo?["NSObject"] as? SidebarNode,
                  let url = node.folderURL else { return }
            var next = model.expandedFolders
            if expanded { next.insert(url) } else { next.remove(url) }
            guard next != model.expandedFolders else { return }
            model.expandedFolders = next
        }

        // MARK: - Keyboard

        /// The row the keyboard is on, which is often a tag while
        /// `sidebarSelection` is still the collection. A favourite and its
        /// original share an `item`; the remembered role picks which of the
        /// two the arrows speak to.
        private func currentRowNode() -> SidebarNode? {
            if let role = keyboardRole, let item = keyboardItem,
               let node = node(role: role, item: item) {
                return node
            }
            guard let outline, outline.selectedRow >= 0 else { return nil }
            return outline.item(atRow: outline.selectedRow) as? SidebarNode
        }

        private func currentRowItem() -> LibraryModel.SidebarItem? {
            currentRowNode()?.item
        }

        /// Right: open a closed folder, otherwise hand the keyboard to the note
        /// list — but **never** to an empty one. SwiftUI's focus then lands
        /// nowhere at all: this column has given it up, the list never took it,
        /// and from that point no arrow key reaches either pane. Measured on the
        /// installed build with an empty Inbox selected.
        ///
        /// The **row** decides, not the collection. A tag must not expand the
        /// selected folder just because that folder is still `sidebarSelection`.
        /// A favourite is a leaf shortcut: right moves to notes, never expands
        /// the original folder.
        func rightArrow() -> Bool {
            guard let node = currentRowNode(), let item = node.item else { return false }
            if node.role == .favourite { return moveToNotesIfPossible() }
            if case .tag = item { return moveToNotesIfPossible() }
            switch LibraryKeyboard.sidebarRight(
                item, in: model.folders, expanded: model.expandedFolders
            ) {
            case .expand(let next):
                model.expandedFolders = next
                return true
            case .moveToNotes:
                return moveToNotesIfPossible()
            default:
                return false
            }
        }

        /// Left: close an open folder, otherwise select its parent.
        /// A favourite is a leaf: left is ignored, and does not collapse the
        /// original folder.
        func leftArrow() -> Bool {
            guard let node = currentRowNode(), let item = node.item else { return false }
            if node.role == .favourite { return false }
            if case .tag = item { return false }
            switch LibraryKeyboard.sidebarLeft(
                item, in: model.folders, expanded: model.expandedFolders
            ) {
            case .collapse(let next):
                model.expandedFolders = next
                return true
            case .select(let parent):
                model.sidebarSelection = parent
                return true
            default:
                return false
            }
        }

        func space() -> Bool {
            guard let node = currentRowNode(), let item = node.item else { return false }
            if case .tag(let name) = item {
                var next = model.selectedTags
                if next.contains(name) { next.remove(name) } else { next.insert(name) }
                model.selectedTags = next
                return true
            }
            if node.role == .favourite { return false }
            guard let next = LibraryKeyboard.toggling(
                item, in: model.folders, expanded: model.expandedFolders
            ) else { return false }
            model.expandedFolders = next
            return true
        }

        private func moveToNotesIfPossible() -> Bool {
            guard let first = model.notes.first else { return true }
            if model.selectedNoteIDs.isEmpty { model.selectedNoteIDs = [first.url] }
            parent.onMoveToNotes()
            return true
        }

        // MARK: - Context menu

        /// The clicked row is selected *before* the menu is built, which is what
        /// Finder and Notes do — and what keeps "New Folder" honest: creation
        /// resolves its parent from the sidebar selection, so a right-click on a
        /// nested folder creates inside that folder and not inside whatever was
        /// selected a moment ago.
        func menu(forRow row: Int) -> NSMenu? {
            guard let outline, let node = outline.item(atRow: row) as? SidebarNode else { return nil }

            if node.role == .fixed, node.item == .trash {
                let menu = NSMenu()
                let empty = menu.addItem(
                    withTitle: NSLocalizedString("Empty Trash", comment: ""),
                    action: #selector(emptyTrash), keyEquivalent: "")
                empty.target = self
                empty.isEnabled = model.trashCount > 0
                return menu
            }

            if node.role == .favourite {
                let menu = NSMenu()
                if let favourite = favouriteItem(from: node) {
                    appendFavouriteToggle(to: menu, favourite, already: true)
                }
                if case .project(let url) = node.item {
                    let reveal = menu.addItem(
                        withTitle: NSLocalizedString("Reveal in Finder", comment: ""),
                        action: #selector(revealFolder), keyEquivalent: "")
                    reveal.target = self
                    reveal.representedObject = url
                }
                return menu
            }

            if node.role == .tag, case .tag(let name) = node.item {
                let menu = NSMenu()
                let favourite = Favourite.tag(name)
                appendFavouriteToggle(to: menu, favourite, already: model.isFavourite(favourite))
                return menu
            }

            guard node.role == .folder, let folder = node.folder else { return nil }
            let menu = NSMenu()
            for (title, selector) in [
                ("New Folder", #selector(newFolder)),
                ("Rename…", #selector(renameFolder)),
                ("Choose Symbol…", #selector(chooseSymbol)),
                ("Reveal in Finder", #selector(revealFolder)),
                ("Delete Folder", #selector(deleteFolder)),
            ] {
                let entry = menu.addItem(
                    withTitle: NSLocalizedString(title, comment: ""),
                    action: selector, keyEquivalent: "")
                entry.target = self
                entry.representedObject = folder.url
            }
            if let favourite = favouriteItem(from: node) {
                menu.addItem(.separator())
                appendFavouriteToggle(to: menu, favourite, already: model.isFavourite(favourite))
            }
            return menu
        }

        private func appendFavouriteToggle(to menu: NSMenu, _ favourite: Favourite, already: Bool) {
            let title = already
                ? NSLocalizedString("Remove from Favourites", comment: "")
                : NSLocalizedString("Add to Favourites", comment: "")
            let selector = already ? #selector(removeFromFavourites) : #selector(addToFavourites)
            let entry = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            entry.target = self
            entry.representedObject = favourite
        }

        /// Every entry point to folder creation goes through one prompt — the
        /// toolbar button, the File menu, ⇧⌘N and this menu — so the folder is
        /// named before it exists, wherever the human started from.
        @objc private func newFolder() {
            LibraryWindowController.promptNewFolder()
        }

        @objc private func renameFolder(_ sender: NSMenuItem) {
            guard let folder = folder(for: sender) else { return }
            parent.onRenameFolder(folder)
        }

        @objc private func deleteFolder(_ sender: NSMenuItem) {
            guard let folder = folder(for: sender) else { return }
            parent.onDeleteFolder(folder)
        }

        @objc private func revealFolder(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            model.revealFolderInFinder(url)
        }

        @objc private func emptyTrash() {
            parent.onEmptyTrash()
        }

        @objc private func addToFavourites(_ sender: NSMenuItem) {
            guard let favourite = sender.representedObject as? Favourite else { return }
            model.addFavourite(favourite)
        }

        @objc private func removeFromFavourites(_ sender: NSMenuItem) {
            guard let favourite = sender.representedObject as? Favourite else { return }
            model.removeFavourite(favourite)
        }

        /// Anchored on the folder it edits, as a popover on the row — the way
        /// the retired SwiftUI row popover was.
        @objc private func chooseSymbol(_ sender: NSMenuItem) {
            guard let outline, let folder = folder(for: sender),
                  let node = node(role: .folder, item: .project(folder.url))
                    ?? node(for: .project(folder.url)) else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, let anchor = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
            else { return }

            symbolPopover?.close()
            let popover = NSPopover()
            let hosting = NSHostingController(
                rootView: FolderSymbolPicker(title: folder.name, current: folder.symbol) { [weak self] name in
                    self?.model.setFolderSymbol(folder.url, name)
                    self?.symbolPopover?.close()
                })
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
            popover.behavior = .transient
            symbolPopover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        }

        private func folder(for sender: NSMenuItem) -> FolderSnapshot? {
            guard let url = sender.representedObject as? URL else { return nil }
            return LibraryKeyboard.folder(url, in: model.folders)
        }

        // MARK: - Drag source

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarNode else { return nil }
            switch node.role {
            case .folder:
                guard let url = node.folderURL,
                      let data = try? JSONEncoder().encode(FolderTransfer(url: url)) else { return nil }
                let entry = NSPasteboardItem()
                entry.setData(data, forType: NSPasteboard.PasteboardType(UTType.shokonotesFolder.identifier))
                return entry
            case .tag:
                guard case .tag(let name) = node.item,
                      let data = try? JSONEncoder().encode(TagTransfer(name: name)) else { return nil }
                let entry = NSPasteboardItem()
                entry.setData(data, forType: NSPasteboard.PasteboardType(UTType.shokonotesTag.identifier))
                return entry
            case .favourite:
                guard let favourite = favouriteItem(from: node),
                      let data = try? JSONEncoder().encode(FavouriteTransfer(item: favourite)) else { return nil }
                let entry = NSPasteboardItem()
                entry.setData(data, forType: NSPasteboard.PasteboardType(UTType.shokonotesFavourite.identifier))
                return entry
            default:
                return nil
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            isDragging = true
            draggedKind = nil
            guard let node = draggedItems.first as? SidebarNode else { return }
            switch node.role {
            case .folder:
                if let url = node.folderURL { draggedKind = .folder(url) }
            case .tag:
                if case .tag(let name) = node.item { draggedKind = .tag(name) }
            case .favourite:
                if let favourite = favouriteItem(from: node) { draggedKind = .favourite(favourite) }
            default:
                break
            }
        }

        /// Every ending, without exception: cancelled, dropped outside the
        /// window, dropped on a row that refused it. The old singleton cleared
        /// itself on the success path only, which is why the *second* drag of a
        /// session never lit anything up again.
        ///
        /// AppKit runs `acceptDrop` from the destination's
        /// `performDragOperation:`, which finishes before the source is sent
        /// this message — so the drop is already done here, and the rebuild
        /// below is what publishes its result. The reverse order is survivable
        /// too: `dragKind(on:)` falls back to the pasteboard when the session
        /// record is gone, and a stale `SidebarNode` still carries the right
        /// URL, which is all `destination(forDropOn:childIndex:)` reads.
        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            draggedKind = nil
            pendingDrop = nil
            // Unconditional: a refresh that arrived mid-drag left `fingerprint`
            // untouched, so only a forced pass can see it.
            rebuild(force: true)
        }

        // MARK: - Drop

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let kind = dragKind(on: info.draggingPasteboard),
                  let located = dropTarget(at: info.draggingLocation) else { return [] }

            let routed = SidebarFavouritesDrop.route(
                kind: kind,
                target: located.target,
                favourites: model.favourites,
                root: model.rootURL
            )
            pendingDrop = routed

            switch routed {
            case .move(.onRow):
                guard let node = located.hover.rowNode else { return [] }
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            case .move(.between):
                guard let parentNode = located.hover.parentNode else { return [] }
                // A header is the outline's stand-in for the library root, and
                // its child level is where a first-level folder is drawn.
                outlineView.setDropItem(parentNode, dropChildIndex: located.hover.childIndex)
                return .move
            case .favourite(.add), .favourite(.addNotes):
                guard let header = favouritesHeader else { return [] }
                outlineView.setDropItem(header, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            case .favourite(.place(_, at: let rank)), .favourite(.placeNotes(at: let rank)):
                guard let header = favouritesHeader else { return [] }
                outlineView.setDropItem(header, dropChildIndex: rank)
                return .copy
            case .favourite(.reorder(from: _, to: let rank)):
                guard let header = favouritesHeader else { return [] }
                outlineView.setDropItem(header, dropChildIndex: rank)
                return .generic
            case .favourite(.moveNotes):
                guard let node = located.hover.rowNode else { return [] }
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            case .move(.refuse), .favourite(.refuse), .refuse:
                pendingDrop = nil
                return []
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            let plan = pendingDrop
            pendingDrop = nil
            guard let kind = dragKind(on: info.draggingPasteboard) else { return false }

            if let plan {
                return perform(plan, kind: kind, info: info, outlineView: outlineView, item: item, childIndex: index)
            }

            // No pending plan: reconstruct from the retargeted item, but never
            // through `destination(forDropOn:)` for a Favourites header — that
            // method treats any header as the library root, which would move
            // a folder on disk.
            if isFavouritesDropItem(item) { return false }
            guard let destination = destination(forDropOn: item, childIndex: index) else { return false }
            return acceptTreeMove(kind: kind, to: destination, info: info, outlineView: outlineView)
        }

        private func perform(
            _ plan: SidebarRoutedPlan,
            kind: SidebarDragKind,
            info: NSDraggingInfo,
            outlineView: NSOutlineView,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            switch plan {
            case .favourite(.add(let favourite)):
                model.addFavourite(favourite)
                return true
            case .favourite(.addNotes):
                return acceptFavouriteNotes(info, placeAt: nil, in: outlineView)
            case .favourite(.place(let favourite, at: let rank)):
                placeFavourite(favourite, at: rank)
                return true
            case .favourite(.placeNotes(at: let rank)):
                return acceptFavouriteNotes(info, placeAt: rank, in: outlineView)
            case .favourite(.reorder(from: let from, to: let to)):
                model.reorderFavourites(fromOffsets: IndexSet(integer: from), toOffset: to)
                return true
            case .favourite(.moveNotes(let url)):
                let destination = (item as? SidebarNode)?.destination ?? url
                return acceptNotes(info, to: destination, in: outlineView)
            case .move:
                guard !isFavouritesDropItem(item),
                      let destination = destination(forDropOn: item, childIndex: index) else { return false }
                return acceptTreeMove(kind: kind, to: destination, info: info, outlineView: outlineView)
            case .favourite(.refuse), .refuse:
                return false
            }
        }

        /// Add, then `reorderFavourites` to the aimed rank. The UI does not sort.
        private func placeFavourite(_ item: Favourite, at index: Int) {
            if !model.isFavourite(item) {
                model.addFavourite(item)
            }
            guard let from = model.favourites.firstIndex(of: item) else { return }
            model.reorderFavourites(fromOffsets: IndexSet(integer: from), toOffset: index)
        }

        /// Notes onto Favourites: add each as `Favourite.note`, then optionally
        /// place the first at `rank`. URLs often arrive only on this path —
        /// SwiftUI `.draggable` is lazy, so validateDrop must not require them.
        private func acceptFavouriteNotes(
            _ info: NSDraggingInfo,
            placeAt rank: Int?,
            in outlineView: NSOutlineView
        ) -> Bool {
            guard model.rootURL != nil else { return false }
            let urls = SidebarOutlineDrop.noteURLs(on: info.draggingPasteboard)
            if !urls.isEmpty {
                return addFavouriteNotes(urls, placeAt: rank)
            }
            return SidebarOutlineDrop.loadNoteURLs(
                from: info, in: outlineView
            ) { [weak self] loaded in
                _ = self?.addFavouriteNotes(loaded, placeAt: rank)
            }
        }

        @discardableResult
        private func addFavouriteNotes(_ urls: [URL], placeAt rank: Int?) -> Bool {
            guard let root = model.rootURL, !urls.isEmpty else { return false }
            for url in urls {
                let item = Favourite.note(LibraryPaths.relativePath(of: url, to: root))
                if !model.isFavourite(item) {
                    model.addFavourite(item)
                }
            }
            if let rank {
                let first = Favourite.note(LibraryPaths.relativePath(of: urls[0], to: root))
                placeFavourite(first, at: rank)
            }
            return true
        }

        private func acceptTreeMove(
            kind: SidebarDragKind,
            to destination: URL,
            info: NSDraggingInfo,
            outlineView: NSOutlineView
        ) -> Bool {
            switch kind {
            case .folder(let source):
                guard let folder = LibraryKeyboard.folder(source, in: model.folders) else { return false }
                guard let error = model.moveFolder(folder, into: destination) else { return true }
                // A drop back onto the current parent is a non-event, not a
                // refusal. The rest is reported, name collisions included: the
                // eye could not have predicted that one.
                if error != .noChange { parent.onFolderMoveRefused(error) }
                return false
            case .notes:
                return acceptNotes(info, to: destination, in: outlineView)
            case .tag, .favourite:
                return false
            }
        }

        private func acceptNotes(
            _ info: NSDraggingInfo,
            to destination: URL,
            in outlineView: NSOutlineView
        ) -> Bool {
            let urls = SidebarOutlineDrop.noteURLs(on: info.draggingPasteboard)
            if !urls.isEmpty {
                return move(urls, to: destination)
            }
            // The pasteboard had the *type* but not the bytes: SwiftUI's
            // `.draggable` registers its payload lazily. Ask the providers,
            // accept the drop, and move when they answer.
            return SidebarOutlineDrop.loadNoteURLs(
                from: info, in: outlineView
            ) { [weak self] loaded in
                _ = self?.move(loaded, to: destination)
            }
        }

        private func isFavouritesDropItem(_ item: Any?) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node === favouritesHeader || node.role == .favourite
        }

        /// Resolves note references against the library and moves whatever is
        /// still there. Shared by the synchronous and the deferred path.
        @discardableResult
        private func move(_ urls: [URL], to destination: URL) -> Bool {
            let notes = urls.compactMap { model.note(with: $0) }
            guard !notes.isEmpty else { return false }
            model.move(notes, to: destination)
            return true
        }

        /// The session record first: it is what lets the feedback be shaped while
        /// the mouse is still down. The pasteboard is the fallback, for the one
        /// case where the record is already gone — `endedAt` reached before
        /// `acceptDrop` — and it is sound because `pasteboardWriterForItem`
        /// wrote those bytes itself, eagerly.
        ///
        /// Favourite and tag types are read before the folder type, so a
        /// leftover folder URL cannot masquerade as a tree move.
        private func dragKind(on pasteboard: NSPasteboard) -> SidebarDragKind? {
            if let draggedKind { return draggedKind }
            if let favourite = SidebarFavouritesDrop.favourite(on: pasteboard) {
                return .favourite(favourite)
            }
            if let name = SidebarFavouritesDrop.tagName(on: pasteboard) {
                return .tag(name)
            }
            let folderType = NSPasteboard.PasteboardType(UTType.shokonotesFolder.identifier)
            let noteType = NSPasteboard.PasteboardType(UTType.shokonotesNote.identifier)
            if pasteboard.availableType(from: [folderType]) != nil {
                guard let source = SidebarOutlineDrop.folderURL(on: pasteboard) else { return nil }
                return .folder(source)
            }
            if pasteboard.availableType(from: [noteType]) != nil { return .notes }
            return nil
        }

        private func favouriteItem(from node: SidebarNode) -> Favourite? {
            guard let root = model.rootURL else { return nil }
            switch node.item {
            case .project(let url):
                return .folder(LibraryPaths.relativePath(of: url, to: root))
            case .tag(let name):
                return .tag(name)
            case .note(let url):
                return .note(LibraryPaths.relativePath(of: url, to: root))
            default:
                return nil
            }
        }

        /// Where AppKit's retargeted item and index point.
        private func destination(forDropOn item: Any?, childIndex index: Int) -> URL? {
            guard let node = item as? SidebarNode else { return nil }
            if index == NSOutlineViewDropOnItemIndex { return node.destination }
            // An insertion line: the destination is the parent whose children
            // the line sits among — the library root under a section header.
            // The Favourites header is not a move destination; a folder drop
            // there favourites, it does not land at the library root.
            switch node.role {
            case .header where node.children.first?.role == .favourite:
                return nil
            case .header: return model.rootURL
            case .folder: return node.folderURL
            default: return nil
            }
        }

        /// AppKit geometry translated into the pure decision's terms.
        private struct Hover {
            let aim: SidebarDropAim
            let rowNode: SidebarNode?
            let parentNode: SidebarNode?
            let childIndex: Int
        }

        private struct LocatedDrop {
            let target: SidebarDropTarget
            let hover: Hover
        }

        /// A few points, as in the Finder: the body of a row means "inside", its
        /// edges mean "a sibling of this row, so at this level". Over Favourites
        /// the same band is a **rank**, not a level.
        private static let edgeBand: CGFloat = 5

        private func dropTarget(at draggingLocation: NSPoint) -> LocatedDrop? {
            guard let outline else { return nil }
            let point = outline.convert(draggingLocation, from: nil)
            let row = outline.row(at: point)
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else {
                let hover = Hover(aim: .nowhere, rowNode: nil, parentNode: nil, childIndex: 0)
                return LocatedDrop(target: .tree(.nowhere), hover: hover)
            }

            if node.role == .header, node.children.first?.role == .favourite {
                let hover = Hover(aim: .nowhere, rowNode: node, parentNode: node, childIndex: 0)
                return LocatedDrop(target: .favourites(.header), hover: hover)
            }

            if node.role == .favourite {
                let parentNode = outline.parent(forItem: node) as? SidebarNode
                let siblings = parentNode?.children ?? []
                let indexInParent = siblings.firstIndex { $0 === node } ?? 0
                let rect = outline.rect(ofRow: row)
                let nearTop = point.y - rect.minY < Self.edgeBand
                let nearBottom = rect.maxY - point.y < Self.edgeBand
                let hover = Hover(
                    aim: .nowhere,
                    rowNode: node,
                    parentNode: parentNode,
                    childIndex: indexInParent + (nearBottom ? 1 : 0))
                if nearTop || nearBottom {
                    return LocatedDrop(target: .favourites(.rank(index: hover.childIndex)), hover: hover)
                }
                guard let item = favouriteItem(from: node) else {
                    return LocatedDrop(target: .tree(.nowhere), hover: hover)
                }
                return LocatedDrop(
                    target: .favourites(.row(index: indexInParent, item: item)),
                    hover: hover)
            }

            let hover = treeHover(node: node, point: point, row: row, outline: outline)
            return LocatedDrop(target: .tree(hover.aim), hover: hover)
        }

        private func treeHover(
            node: SidebarNode,
            point: NSPoint,
            row: Int,
            outline: NSOutlineView
        ) -> Hover {
            let rect = outline.rect(ofRow: row)
            let nearTop = point.y - rect.minY < Self.edgeBand
            let nearBottom = rect.maxY - point.y < Self.edgeBand

            // Only a folder row has a level to be a sibling of.
            guard node.role == .folder else {
                return Hover(
                    aim: SidebarDropAim(rowDestination: node.destination, siblingParent: nil, onEdge: false),
                    rowNode: node, parentNode: nil, childIndex: 0)
            }

            let parentNode = (outline.parent(forItem: node) as? SidebarNode) ?? foldersHeader
            let siblings = parentNode?.children ?? []
            let indexInParent = siblings.firstIndex { $0 === node } ?? 0
            let siblingParent: URL? = parentNode?.role == .folder ? parentNode?.folderURL : model.rootURL

            return Hover(
                aim: SidebarDropAim(
                    rowDestination: node.destination,
                    siblingParent: siblingParent,
                    onEdge: nearTop || nearBottom),
                rowNode: node,
                parentNode: parentNode,
                childIndex: indexInParent + (nearBottom ? 1 : 0))
        }
    }
}

/// The outline itself. It owns the keyboard of this column: arrows and type
/// select are AppKit's, and left / right / space are the library's contract.
final class SidebarOutlineView: NSOutlineView {
    var onTookFocus: () -> Void = {}
    var onRightArrow: () -> Bool = { false }
    var onLeftArrow: () -> Bool = { false }
    var onSpace: () -> Bool = { false }
    var contextMenuForRow: ((Int) -> NSMenu?)?
    /// Focus was asked for before this view had a window. Taken once, on
    /// attach — see the focus contract on `SidebarSourceList`.
    var wantsFocusOnAttach = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        // Mirrors the focus into SwiftUI. Writes nothing that could move a first
        // responder, and bumps no token.
        if took { onTookFocus() }
        return took
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocusOnAttach, let window else { return }
        wantsFocusOnAttach = false
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        switch Int(scalar.value) {
        case NSRightArrowFunctionKey where onRightArrow():
            return
        case NSLeftArrowFunctionKey where onLeftArrow():
            return
        case 0x20 where onSpace():
            return
        default:
            super.keyDown(with: event)
        }
    }

    /// Right-click selects the row under the cursor before the menu is built.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        if selectedRow != row, delegate?.outlineView?(self, shouldSelectItem: item(atRow: row) as Any) != false {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return contextMenuForRow?(row)
    }
}

/// The row container, for one reason only: it is the only place that knows a row
/// is **selected but not emphasized**.
///
/// `NSTableCellView.backgroundStyle` does not distinguish that state from an
/// unselected row — both are `.normal` — and no `viewFor:` pass is made when the
/// selection changes, so reading the state at configure time would never catch
/// the transition. `rowView(atRow:makeIfNecessary:)` would have to be called
/// from inside `viewFor:`, which re-enters the table's own row-view creation and
/// still gives no callback. A row-view subclass gets both: `isSelected` and
/// `isEmphasized` are the source, and they are observable.
///
/// It draws nothing of its own. The source list's selection stays AppKit's.
final class SidebarRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { refreshCells() }
    }

    override var isEmphasized: Bool {
        didSet { refreshCells() }
    }

    /// A recycled cell is added to a row that may already be selected, and
    /// `setBackgroundStyle:` carries no news when the style does not change.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SidebarCellView)?.refreshTint()
    }

    private func refreshCells() {
        for case let cell as SidebarCellView in subviews { cell.refreshTint() }
    }
}

/// One row: the folder glyph, the name, and a count on the trailing edge.
///
/// The colours are AppKit's, deliberately. A source list draws its own
/// selection, and the identity wash of this app stays on exactly one surface —
/// the focused selection of the note list. What this cell does own is the
/// inversion on a selected row, and it takes **three** states, because a row
/// can be selected without being emphasized — the keyboard is in the note
/// list, or the window is in the background:
///
/// | Row | Glyph | Count |
/// |---|---|---|
/// | emphasized | `alternateSelectedControlTextColor` | `alternateSelectedControlTextColor` |
/// | selected, grey | `labelColor` | `secondaryLabelColor` |
/// | neither | `controlAccentColor` | `secondaryLabelColor` |
///
/// The middle state is the whole point. Measured on the retired SwiftUI rows:
/// the user's accent left on the grey selection is **1.10:1**, which is why the
/// inversion exists at all; `alternateSelectedControlTextColor` is **3.18:1** on
/// the emphasized fill, the value the white title already gets; and
/// `secondaryLabelColor` is **4.14:1** both on the grey selection and on the
/// plain sidebar, which is why the count needs no middle value of its own.
///
/// Those three numbers were taken while the column was vibrant. The column is
/// now flat `windowBackgroundColor`, so they were recomputed against it, and
/// the table above still holds — nothing moved band:
///
/// - the count on the plain column: **3.9:1** in light (`secondaryLabelColor`
///   resolves to ≈ #767676 on ≈ #ECECEC) and **5.1:1** in dark (≈ #A3A3A3 on
///   ≈ #323232), against 4.14:1 on the material. Same range, same role.
/// - "selected, grey" is the state to watch, and it is the one that changed
///   least: `unemphasizedSelectedContentBackgroundColor` is the fill, not the
///   backdrop, so `labelColor` on it reads as it always did — near-black on a
///   light grey, white on a dark one. What the opaque backdrop removed is the
///   desktop showing through that fill, which could only ever hurt it.
/// - "neither" keeps `controlAccentColor` on the column itself: ≈ 3.6:1 in
///   light and ≈ 3.9:1 in dark for the default blue, which is a glyph value,
///   not a text one — and the same reason the middle state exists, since that
///   accent on the grey selection was 1.10:1.
final class SidebarCellView: NSTableCellView {
    private let count = NSTextField(labelWithString: "")
    private let isHeader: Bool

    init(isHeader: Bool, identifier: NSUserInterfaceItemIdentifier) {
        self.isHeader = isHeader
        super.init(frame: .zero)
        self.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = isHeader ? .preferredFont(forTextStyle: .subheadline) : .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label

        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        addSubview(count)

        label.translatesAutoresizingMaskIntoConstraints = false
        count.translatesAutoresizingMaskIntoConstraints = false

        var leading = leadingAnchor
        if !isHeader {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
            ])
            leading = icon.trailingAnchor
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: isHeader ? 0 : 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    func configure(_ node: SidebarNode) {
        textField?.stringValue = node.title
        if let symbol = node.symbol {
            imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        } else {
            imageView?.image = nil
        }
        if let value = node.count, value > 0 {
            count.stringValue = "\(value)"
            count.isHidden = false
        } else {
            count.stringValue = ""
            count.isHidden = true
        }
        applyTint()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        get { super.backgroundStyle }
        set {
            super.backgroundStyle = newValue
            applyTint()
        }
    }

    /// Called by `SidebarRowView` when the row's selection or emphasis changed,
    /// neither of which passes through `backgroundStyle`.
    func refreshTint() {
        applyTint()
    }

    private func applyTint() {
        // `.emphasized` is the strong fill. The grey selection reports `.normal`
        // like an unselected row, so the row view is asked.
        let emphasized = backgroundStyle == .emphasized
        let selected = emphasized || (superview as? NSTableRowView)?.isSelected == true

        if emphasized {
            imageView?.contentTintColor = .alternateSelectedControlTextColor
        } else if selected {
            imageView?.contentTintColor = .labelColor
        } else {
            imageView?.contentTintColor = .controlAccentColor
        }
        count.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        if isHeader { textField?.textColor = .secondaryLabelColor }
    }
}
