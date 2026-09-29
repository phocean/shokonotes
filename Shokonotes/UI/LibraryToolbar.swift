import AppKit
import Combine

/// Identifier order and the single-note enablement rule, as values. The
/// controller applies them; tests read them without an `NSWindow`.
enum LibraryToolbarLayout {
    static let sidebar = NSToolbarItem.Identifier("shokonotes.toolbar.sidebar")
    static let newNote = NSToolbarItem.Identifier("shokonotes.toolbar.newNote")
    static let newFolder = NSToolbarItem.Identifier("shokonotes.toolbar.newFolder")
    static let search = NSToolbarItem.Identifier("shokonotes.toolbar.search")
    static let sort = NSToolbarItem.Identifier("shokonotes.toolbar.sort")
    static let print = NSToolbarItem.Identifier("shokonotes.toolbar.print")
    static let share = NSToolbarItem.Identifier("shokonotes.toolbar.share")
    static let exportPDF = NSToolbarItem.Identifier("shokonotes.toolbar.exportPDF")
    static let settings = NSToolbarItem.Identifier("shokonotes.toolbar.settings")
    static let editor = NSToolbarItem.Identifier("shokonotes.toolbar.editor")
    /// Pinned to the sidebar / note list divider.
    static let sidebarSeparator = NSToolbarItem.Identifier("shokonotes.toolbar.sidebarSeparator")
    /// Pinned to the note list / preview divider.
    static let listSeparator = NSToolbarItem.Identifier("shokonotes.toolbar.listSeparator")

    /// Export, Print and Share stay adjacent so AppKit draws them as one
    /// capsule; a `.space` after that run keeps Settings + editor as the app
    /// capsule. See the grouping comment on
    /// `LibraryToolbarController.identifiers`.
    static func identifiers(sidebarVisible: Bool) -> [NSToolbarItem.Identifier] {
        let preview: [NSToolbarItem.Identifier] = [
            .flexibleSpace, exportPDF, print, share, .space, settings, editor,
        ]
        if sidebarVisible {
            return [
                .flexibleSpace, sidebar, .space, newFolder, .space,
                sidebarSeparator,
                newNote, search, sort,
                listSeparator,
            ] + preview
        }
        return [
            sidebar, .space, newFolder, .space, newNote,
            search, sort,
            listSeparator,
        ] + preview
    }

    /// Exactly one selected note that is still in the visible list — what
    /// `LibraryModel.focusedNote` means, and what greys Print, Share and Export.
    static func isSingleNoteActionEnabled(selectedNoteIDs: Set<URL>, visibleNoteIDs: Set<URL>) -> Bool {
        selectedNoteIDs.count == 1 && selectedNoteIDs.isSubset(of: visibleNoteIDs)
    }
}

@MainActor
final class LibraryToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {

    private var model: LibraryModel { LibraryModel.shared }
    private weak var sidebarItem: NSToolbarItem?
    private weak var printItem: NSToolbarItem?
    private weak var shareItem: NSToolbarItem?
    private weak var exportItem: NSToolbarItem?
    /// Held while `NSSharingServicePicker` is on screen; the picker does not
    /// retain itself after `show(relativeTo:of:preferredEdge:)`.
    private var sharingPicker: NSSharingServicePicker?
    private var sidebarObserver: AnyCancellable?
    private var selectionObserver: AnyCancellable?
    private var notesObserver: AnyCancellable?
    private weak var searchField: NSSearchField?
    /// The split view the tracking separators follow. SwiftUI owns it, so it is
    /// held weakly and looked up again whenever the columns change.
    private weak var splitView: NSSplitView?
    private weak var toolbar: NSToolbar?

    func makeToolbar(splitView: NSSplitView?) -> NSToolbar {
        let toolbar = NSToolbar(identifier: "shokonotes.library.toolbar")
        self.splitView = splitView
        self.toolbar = toolbar
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // `dropFirst` skips the value `@Published` replays at subscription: it
        // carries no change, and rebuilding on it would tear the items down and
        // build a fresh search field right after the window opened.
        sidebarObserver = model.$sidebarVisible.dropFirst().sink { [weak self] visible in
            // Published fires before the property is assigned, so the items are
            // updated with the incoming value rather than the current one.
            self?.updateSidebarItem(sidebarVisible: visible)
            // Hiding the sidebar removes a divider, so the separator has to
            // track a different one; the items are rebuilt rather than nudged.
            // Deferred because the columns have not been laid out yet at the
            // moment the flag changes.
            DispatchQueue.main.async { self?.rebuildItems() }
        }
        // Print, Share and Export all act on exactly one note, so the buttons
        // follow the same rule as the File menu items
        // (`LibraryWindowController.validateMenuItem`). That rule reads two
        // states — one selected note, and that note still in the visible list —
        // so both are watched. Watching the selection alone left the buttons
        // live after a search, a folder or a tag dropped the selected note out
        // of `notes`, while the menu items, revalidated by AppKit every time
        // the menu opens, greyed out: a button that posts a command
        // `LibraryView` then drops for want of a `focusedNote`.
        //
        // Writing `isEnabled` is idempotent and cheap, so the rate of `$notes`
        // costs nothing. Nothing is rebuilt from either sink. Same `dropFirst`
        // in both: the replayed value carries no change, and the items read the
        // current state when they are created.
        selectionObserver = model.$selectedNoteIDs.dropFirst().sink { [weak self] ids in
            // Published fires before the property is assigned, so the incoming
            // value is used and the other state read from the model.
            guard let self else { return }
            updateSingleNoteItems(selectedNoteIDs: ids, notes: model.notes)
        }
        notesObserver = model.$notes.dropFirst().sink { [weak self] notes in
            guard let self else { return }
            updateSingleNoteItems(selectedNoteIDs: model.selectedNoteIDs, notes: notes)
        }
        return toolbar
    }

    /// The first split view under `root`: the one SwiftUI's `HSplitView` (opaque
    /// sidebar) or `NavigationSplitView` (glass sidebar) is backed by.
    static func splitView(in root: NSView?) -> NSSplitView? {
        guard let root else { return nil }
        if let split = root as? NSSplitView { return split }
        for sub in root.subviews {
            if let found = splitView(in: sub) { return found }
        }
        return nil
    }

    /// One zone per column, each holding what acts on that column: the sidebar
    /// its own controls, the note list everything that makes it (new note,
    /// search, sort), the preview Print / Share / Export of the note it shows,
    /// Settings, and the editor it opens the note in.
    /// Hiding the sidebar takes a divider away, so its zone merges into the list's.
    ///
    /// The `.space` items are not padding. macOS groups **adjacent** bordered
    /// toolbar items into one shared capsule, and it did: hiding the sidebar and
    /// making a folder — two functions with nothing to do with each other — were
    /// drawn inside a single rounded pill, while compose and sort each had their
    /// own circle. Adjacency, not intent, had grouped them. A `.space` between
    /// them breaks the run, so each draws as its own button like its neighbours.
    /// They stay in the same zone, before the same tracking separator, so the
    /// separators pinned to the `HSplitView` dividers are untouched.
    ///
    /// The trailing zone reads by that same rule. Export, Print and Share stay
    /// adjacent so AppKit draws them as one capsule: three ways to get the note
    /// out of the library. Settings and the external editor stay adjacent —
    /// both act on the application — and a `.space` keeps them their own capsule
    /// after that run.
    private var identifiers: [NSToolbarItem.Identifier] {
        // The leading `.flexibleSpace` (sidebar visible) pushes the sidebar
        // zone's two buttons to the right, against the tracking separator,
        // instead of leaving them jammed against the traffic lights. The
        // separator is pinned to the split view's divider and anchors the zone,
        // so the slack this absorbs is the sidebar zone's own: the note-list
        // items and the second separator do not move.
        //
        // The trailing `.space` after new-folder is the margin that keeps that
        // button off the zone's edge. Fixed, not flexible — a second flexible
        // space would share the slack with the first and re-centre the pair
        // instead of right-aligning it.
        //
        // No sidebar means no sidebar zone and no divider to align against, so
        // those buttons stay at the left. With no divider between them, the
        // same run would otherwise swallow the new-note button as well.
        LibraryToolbarLayout.identifiers(sidebarVisible: model.sidebarVisible)
    }

    /// The columns were rebuilt — the sidebar mode changed, or the
    /// `NavigationSplitView` finished its first layout — so the tracking
    /// separators must be pointed at the split view that exists now. Tried
    /// twice: SwiftUI does not promise its update has landed on the next turn.
    func structureDidChange() {
        rebuildItems()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let found = Self.splitView(in: LibraryWindowController.currentWindow?.contentView)
            if found !== splitView { rebuildItems() }
        }
    }

    private func rebuildItems() {
        guard let toolbar else { return }
        splitView = Self.splitView(in: LibraryWindowController.currentWindow?.contentView)
        let text = model.searchText

        while !toolbar.items.isEmpty {
            toolbar.removeItem(at: toolbar.items.count - 1)
        }
        for (index, identifier) in identifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }

        // The search field is a fresh view after the rebuild.
        searchField?.stringValue = text
    }

    func focusSearch() {
        guard let field = searchField else { return }
        field.window?.makeFirstResponder(field)
    }

    /// Starts a query with `text` and leaves the caret at the end so the next
    /// key continues it. Setting `stringValue` does not notify the delegate,
    /// so the model is updated here too.
    func focusSearch(inserting text: String) {
        model.searchText = text
        guard let field = searchField else { return }
        field.stringValue = text
        field.window?.makeFirstResponder(field)
        placeCaretAtEnd(of: field)
        // Becoming first responder selects the contents; the next turn is
        // after that selection, so the caret stays after the inserted character.
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    private func placeCaretAtEnd(of field: NSSearchField) {
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case LibraryToolbarLayout.sidebarSeparator, LibraryToolbarLayout.listSeparator:
            // Dividers count from the left. The sidebar / list one is always the
            // first; the list / preview one is the second while the sidebar is
            // showing and the first once it is gone.
            //
            // In opaque mode the `HSplitView` drops the sidebar's subview when it
            // is hidden, so the second divider becomes the first. In glass mode
            // the `NavigationSplitView` keeps a collapsed sidebar as an arranged
            // (hidden) subview, so the list / preview divider is always the
            // second.
            let index: Int
            if itemIdentifier == LibraryToolbarLayout.sidebarSeparator {
                index = 0
            } else {
                index = (model.sidebarVisible || !AppSettings.shared.opaqueSidebar) ? 1 : 0
            }
            guard let splitView, splitView.arrangedSubviews.count > index + 1 else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: index)

        case LibraryToolbarLayout.sidebar:
            let item = button(itemIdentifier, symbol: "sidebar.leading",
                              label: NSLocalizedString("Hide Sidebar", comment: ""),
                              action: #selector(toggleSidebar))
            sidebarItem = item
            updateSidebarItem(sidebarVisible: model.sidebarVisible)
            return item
        case LibraryToolbarLayout.newNote:
            // Notes' compose glyph. At the shared title3/medium metric its ink
            // is 15×15 against 18×14 on sidebar / macwindow. Point size 18
            // brings that ink to 18×18; the symbol does not change.
            return button(itemIdentifier, symbol: "square.and.pencil",
                          label: NSLocalizedString("New Note", comment: ""),
                          action: #selector(newNote),
                          metric: Self.composeMetric)
        case LibraryToolbarLayout.newFolder:
            return button(itemIdentifier, symbol: "folder.badge.plus",
                          label: NSLocalizedString("New Folder", comment: ""),
                          action: #selector(newFolder))
        case LibraryToolbarLayout.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.delegate = self
            item.searchField.placeholderString = NSLocalizedString("Search", comment: "")
            item.searchField.sendsSearchStringImmediately = true
            // The note list column is narrow; ask for little enough that the
            // field stays a field instead of collapsing to a magnifier.
            item.preferredWidthForSearchField = 100
            searchField = item.searchField
            return item
        case LibraryToolbarLayout.sort:
            // The shared metric below does apply — measured: the same
            // configuration takes `arrow.up.arrow.down` from 18×15 to 22×18 pt.
            // It cannot fix what was actually wrong, because a point size sets
            // cap height, not ink: at one metric the two stacked arrows still
            // come out 18 pt tall against a 12 pt `line.3.horizontal.decrease`,
            // and read as a heavier, taller glyph than everything beside them.
            // So the glyph changes: three shortening lines are also what Notes
            // and Mail use for this menu.
            return menuButton(itemIdentifier, symbol: "line.3.horizontal.decrease",
                              label: NSLocalizedString("Sort", comment: ""),
                              toolTip: NSLocalizedString("Sort notes", comment: ""),
                              menu: sortMenu())
        case LibraryToolbarLayout.print:
            // Nil target, same selector as File ▸ Print…: one print path.
            // Shared metric; `printer` is the system print glyph.
            let item = button(itemIdentifier, symbol: "printer",
                              label: NSLocalizedString("Print…", comment: ""),
                              action: #selector(LibraryWindowController.printNote(_:)))
            item.target = nil
            item.autovalidates = false
            printItem = item
            updateSingleNoteItems(selectedNoteIDs: model.selectedNoteIDs, notes: model.notes)
            return item
        case LibraryToolbarLayout.share:
            // `square.and.arrow.up` is the system share glyph — the one Export
            // refused because it would have promised this picker. The click
            // shows `NSSharingServicePicker` on the note file, anchored on this
            // button; File ▸ Share… uses the same picker through `shareCommand`.
            let item = button(itemIdentifier, symbol: "square.and.arrow.up",
                              label: NSLocalizedString("Share…", comment: ""),
                              action: #selector(shareFromToolbar))
            item.autovalidates = false
            shareItem = item
            updateSingleNoteItems(selectedNoteIDs: model.selectedNoteIDs, notes: model.notes)
            return item
        case LibraryToolbarLayout.exportPDF:
            // A document carrying an out-arrow badge: the system's export glyph.
            // Not `square.and.arrow.up`, which means share everywhere else in
            // macOS and would promise a share sheet this button does not open.
            // Shared metric, no override: its ink is 16×18, so the 18 pt it is
            // wide-or-tall is the same 18 that `sidebar.leading` / `macwindow`
            // measure across and that `square.and.pencil` is asked for.
            //
            // Nil target, same selector as File ▸ Export as PDF…: the click goes
            // up the responder chain to `LibraryWindowController.exportPDF(_:)`,
            // which posts `exportPDFCommand`. One export path, two entry points.
            let item = button(itemIdentifier, symbol: "doc.badge.arrow.up",
                              label: NSLocalizedString("Export as PDF…", comment: ""),
                              action: #selector(LibraryWindowController.exportPDF(_:)))
            item.target = nil
            // AppKit would enable a nil-target item as soon as the responder
            // chain answers the selector, which is always. The single-note rule
            // lives in `updateSingleNoteItems` instead.
            item.autovalidates = false
            exportItem = item
            updateSingleNoteItems(selectedNoteIDs: model.selectedNoteIDs, notes: model.notes)
            return item
        case LibraryToolbarLayout.settings:
            // Same selector as the menu's Settings… (⌘,): one Settings host.
            // Sliders, not the gear: the gear stays the General *section*
            // icon inside Settings. Shared title3/medium metric.
            let item = button(itemIdentifier, symbol: "slider.horizontal.3",
                              label: NSLocalizedString("Settings…", comment: ""),
                              action: #selector(AppDelegate.openPreferences(_:)))
            item.target = NSApp.delegate
            return item
        case LibraryToolbarLayout.editor:
            // `arrow.up.forward.app` at this metric is 18×17 with a 13.5×14.2 pt
            // ink box — a smaller rounded square than `square.and.pencil`
            // (19×19, 14.5×14.5) or `sidebar.leading` (22×17, 17.4×14.2). Nested
            // arrow-on-app/square glyphs share that inset body; `macwindow` is
            // the same canvas and ink as the sidebar, meaning open in an app.
            return menuButton(itemIdentifier, symbol: "macwindow",
                              label: NSLocalizedString("External editor", comment: ""),
                              toolTip: String(
                                format: NSLocalizedString("Open in %@", comment: ""),
                                ExternalEditors.displayName(for: model.externalEditorBundle)),
                              menu: editorMenu())
        default:
            return nil
        }
    }

    /// One optical metric for every symbol in the toolbar. Left to themselves,
    /// SF Symbols render at their own intrinsic size — two stacked arrows read
    /// as a bigger glyph than a pencil — so they are all asked for the same
    /// point size. The size is the system's `.title3` text metric, which is the
    /// 15pt a macOS unified toolbar draws its symbols at and which follows the
    /// user's text settings, rather than a number picked to suit one screenshot.
    private static let symbolMetric = NSImage.SymbolConfiguration(textStyle: .title3, scale: .medium)
    /// `square.and.pencil` only: 18 pt so its ink matches the 18 pt width of
    /// `sidebar.leading` / `macwindow` at `symbolMetric`. Same glyph as Notes.
    private static let composeMetric = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular, scale: .medium)

    private static func symbolImage(
        _ name: String,
        metric: NSImage.SymbolConfiguration = symbolMetric
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(metric)
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        action: Selector,
        metric: NSImage.SymbolConfiguration = symbolMetric
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = Self.symbolImage(symbol, metric: metric)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    /// The same button, carrying a menu. It goes through this one path rather
    /// than building its image inline, so a menu-bearing item cannot drift away
    /// from the plain buttons it sits next to.
    private func menuButton(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        toolTip: String,
        menu: NSMenu
    ) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = toolTip
        item.image = Self.symbolImage(symbol)
        // The disclosure chevron a menu item draws beside its symbol is what
        // made the frame wider than its neighbours'. The menu still opens on
        // click.
        item.showsIndicator = false
        item.menu = menu
        return item
    }

    static let editorMenuID = NSUserInterfaceItemIdentifier("shokonotes.menu.editor")
    static let sortMenuID = NSUserInterfaceItemIdentifier("shokonotes.menu.sort")

    private func editorMenu() -> NSMenu {
        let menu = NSMenu()
        menu.identifier = Self.editorMenuID
        menu.delegate = self
        return menu
    }

    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.identifier = Self.sortMenuID
        menu.delegate = self
        return menu
    }

    /// The button names the action, not the state: Finder and Mail both flip
    /// the label between hiding and showing.
    private func updateSidebarItem(sidebarVisible: Bool) {
        guard let item = sidebarItem else { return }
        let label = sidebarVisible
            ? NSLocalizedString("Hide Sidebar", comment: "")
            : NSLocalizedString("Show Sidebar", comment: "")
        item.label = label
        item.toolTip = label
    }

    /// Enabled for exactly one selected note that is in the list, which is what
    /// `LibraryModel.focusedNote` means and what the File menu items check. Both
    /// states are parameters rather than reads through `model`, because
    /// `@Published` fires before assignment: whichever of the two just changed,
    /// the caller hands in the incoming value. Print, Share and Export share
    /// the rule so a search that drops the selected note greys all three.
    private func updateSingleNoteItems(selectedNoteIDs: Set<URL>, notes: [NoteSnapshot]) {
        let enabled = LibraryToolbarLayout.isSingleNoteActionEnabled(
            selectedNoteIDs: selectedNoteIDs,
            visibleNoteIDs: Set(notes.map(\.url))
        )
        printItem?.isEnabled = enabled
        shareItem?.isEnabled = enabled
        exportItem?.isEnabled = enabled
    }

    /// The share button, used as the picker anchor from the toolbar click and
    /// from File ▸ Share…. Standard bordered items often leave
    /// `NSToolbarItem.view` nil even while the button is on screen, so a miss
    /// walks the titlebar for the control that carries this item's action.
    var shareItemView: NSView? {
        if let view = shareItem?.view { return view }
        guard let root = LibraryWindowController.currentWindow?.contentView?.superview else {
            return nil
        }
        return control(in: root, action: #selector(shareFromToolbar), target: self)
    }

    func presentSharePicker(for noteURL: URL, relativeTo view: NSView) {
        let picker = NSSharingServicePicker(items: [noteURL])
        sharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    @objc private func shareFromToolbar() {
        guard let note = model.focusedNote else { return }
        if let view = shareItemView {
            presentSharePicker(for: note.url, relativeTo: view)
        } else {
            NotificationCenter.default.post(name: LibraryWindowController.shareCommand, object: nil)
        }
    }

    private func control(in view: NSView, action: Selector, target: AnyObject) -> NSView? {
        if let control = view as? NSControl, control.action == action, control.target === target {
            return view
        }
        for sub in view.subviews {
            if let found = self.control(in: sub, action: action, target: target) {
                return found
            }
        }
        return nil
    }

    @objc private func toggleSidebar() { model.toggleSidebar() }
    @objc private func newNote() { model.createNote() }

    func clearSearch() {
        searchField?.stringValue = ""
    }

    func promptNewFolder() {
        newFolder()
    }

    @objc private func newFolder() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("New Folder", comment: "")
        alert.informativeText = NSLocalizedString(
            "The folder is created in the selected directory, or in the notes folder.", comment: "")
        let field = NSTextField(string: NSLocalizedString("Untitled Folder", comment: ""))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("Create", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = model.createFolder(named: field.stringValue)
    }

    @objc private func pickEditor(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        model.externalEditorBundle = bundle
    }

    @objc private func pickSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let sort = SortKey(rawValue: raw) else { return }
        model.sortBy = sort
    }

    @objc private func toggleDirection() {
        model.sortAscending.toggle()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        model.searchText = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchField?.stringValue = ""
            model.searchText = ""
            return true
        }
        // Down and Return hand the keyboard to the filtered list, the query left
        // in the field so ⌘F comes straight back to it.
        if commandSelector == #selector(NSResponder.moveDown(_:))
            || commandSelector == #selector(NSResponder.insertNewline(_:)) {
            LibraryWindowController.focusContentView()
            model.focusNotesList()
            return true
        }
        return false
    }
}

@MainActor
extension LibraryToolbarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if menu.identifier == Self.editorMenuID {
            for editor in ExternalEditors.installed() {
                let item = NSMenuItem(title: editor.name, action: #selector(pickEditor(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = editor.bundle
                item.state = (editor.bundle == model.externalEditorBundle) ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let choose = NSMenuItem(
                title: NSLocalizedString("Choose…", comment: ""),
                action: #selector(chooseEditor),
                keyEquivalent: ""
            )
            choose.target = self
            menu.addItem(choose)
            return
        }

        let options: [(SortKey, String)] = [
            (.modified, NSLocalizedString("Modification Date", comment: "")),
            (.created, NSLocalizedString("Creation Date", comment: "")),
            (.title, NSLocalizedString("Title", comment: "")),
        ]
        for (sort, title) in options {
            let item = NSMenuItem(title: title, action: #selector(pickSort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sort.rawValue
            item.state = (model.sortBy == sort) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let ascending = NSMenuItem(
            title: NSLocalizedString("Ascending", comment: ""),
            action: #selector(toggleDirection),
            keyEquivalent: ""
        )
        ascending.target = self
        ascending.state = model.sortAscending ? .on : .off
        menu.addItem(ascending)
    }

    @objc private func chooseEditor() {
        if let bundle = ExternalEditors.pickApplication() {
            model.externalEditorBundle = bundle
        }
    }
}
