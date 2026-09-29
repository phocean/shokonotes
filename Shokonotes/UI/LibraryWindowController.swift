import AppKit
import Combine
import SwiftUI

/// The window's background in **opaque sidebar** mode: one flat semantic
/// colour, and the only background the folder column has then. In the default
/// glass mode it is switched off (`fillsBackground`) and draws nothing: the
/// system's sidebar is that column's one layer. It replaced an
/// `NSVisualEffectView` — see where it is installed in `show()`.
///
/// It fills in `draw(_:)` rather than setting a layer colour, so the fill is
/// resolved against the appearance in force at the moment it is drawn; a
/// `CGColor` handed to a layer is a fixed value and would keep the light tone
/// after a switch to dark. `viewDidChangeEffectiveAppearance` asks for that
/// redraw, because AppKit does not promise one for a view that draws itself.
final class OpaqueBackdropView: NSView {
    var fillsBackground = true {
        didSet { if fillsBackground != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { fillsBackground }

    override func draw(_ dirtyRect: NSRect) {
        guard fillsBackground else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let storageDidChange = Notification.Name("shokonotes.library.storageDidChange")
    static let newNoteCommand = Notification.Name("shokonotes.library.newNote")
    static let newFolderCommand = Notification.Name("shokonotes.library.newFolder")
    static let printCommand = Notification.Name("shokonotes.library.print")
    static let focusSearchCommand = Notification.Name("shokonotes.library.focusSearch")
    static let openExternalCommand = Notification.Name("shokonotes.library.openExternal")
    static let deleteCommand = Notification.Name("shokonotes.library.delete")
    static let renameCommand = Notification.Name("shokonotes.library.rename")
    static let matchFilenameCommand = Notification.Name("shokonotes.library.matchFilename")
    static let revealCommand = Notification.Name("shokonotes.library.reveal")
    static let pinCommand = Notification.Name("shokonotes.library.pin")
    static let editTagsCommand = Notification.Name("shokonotes.library.editTags")
    static let shareCommand = Notification.Name("shokonotes.library.share")
    static let exportPDFCommand = Notification.Name("shokonotes.library.exportPDF")
    static let findNextCommand = Notification.Name("shokonotes.library.findNext")
    static let findPreviousCommand = Notification.Name("shokonotes.library.findPrevious")
    static let selectAllCommand = Notification.Name("shokonotes.library.selectAll")
    static let previewWantsNotesFocus = Notification.Name("shokonotes.library.previewWantsNotes")
    static let previewTookFocus = Notification.Name("shokonotes.library.previewTookFocus")

    private static var shared: LibraryWindowController?
    private static var libraryToolbar: LibraryToolbarController?
    private var hosted: NSHostingController<LibraryView>?
    private var backdrop: OpaqueBackdropView?
    private var sidebarModeObserver: AnyCancellable?
    private var appliedOpaqueSidebar: Bool?

    /// Glass (default) or opaque folder column. Opaque: the window is opaque and
    /// the backdrop fills it, exactly as before. Glass: the backdrop draws
    /// nothing, so the only layer behind the column is
    /// the system sidebar's. The SwiftUI tree swaps its own structure on the
    /// same setting; the toolbar is then pointed at the new split view.
    private func applySidebarMode(force: Bool = false) {
        let opaque = AppSettings.shared.opaqueSidebar
        guard force || appliedOpaqueSidebar != opaque, let window else { return }
        appliedOpaqueSidebar = opaque
        backdrop?.fillsBackground = opaque
        // The window stays opaque with its ordinary background in both modes.
        // A clear window in glass mode left the 1 pt strip of the list /
        // preview divider — the one place no column paints — with nothing
        // behind it, so the translucent separator colour drew over the
        // desktop and read much heavier than over `windowBackgroundColor`.
        // The system sidebar does not need a clear window: the glass is its
        // own layer, and a default window is what any sidebar app has.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        guard !force else { return }
        // The SwiftUI tree rebuilds on this same change; look for its split
        // view once it has laid out.
        DispatchQueue.main.async {
            window.contentView?.layoutSubtreeIfNeeded()
            Self.libraryToolbar?.structureDidChange()
        }
    }

    static func notifyStorageChanged() {
        NotificationCenter.default.post(name: storageDidChange, object: nil)
    }

    @objc func newNote(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.newNoteCommand, object: nil)
    }

    @objc func newFolder(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.newFolderCommand, object: nil)
    }

    @objc func revealInFinder(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.revealCommand, object: nil)
    }

    @objc func pinNote(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.pinCommand, object: nil)
    }

    /// The third door into `TagPopover`, beside the left swipe and the context
    /// menu — the same editor, opened on the note list's own selection, so the
    /// library can be tagged without a pointer ever being used.
    @objc func editTags(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.editTagsCommand, object: nil)
    }

    @objc func shareNote(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.shareCommand, object: nil)
    }

    @objc func findNext(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.findNextCommand, object: nil)
    }

    @objc func findPrevious(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.findPreviousCommand, object: nil)
    }

    /// Deliberately **not** named `toggleSidebar(_:)`. That selector is AppKit's
    /// own (`NSSplitViewController`), and something ahead of this controller in
    /// the responder chain answered to it and did nothing: ⌃⌘S was inert and so
    /// was clicking the View menu item, while the toolbar button — which targets
    /// its own object directly — worked. A name AppKit does not already own
    /// reaches the window controller.
    @objc func toggleLibrarySidebar(_ sender: Any?) {
        LibraryModel.shared.toggleSidebar()
    }

    static func clearSearchField() {
        libraryToolbar?.clearSearch()
    }

    static func beginSearch(inserting text: String) {
        libraryToolbar?.focusSearch(inserting: text)
    }

    static func promptNewFolder() {
        libraryToolbar?.promptNewFolder()
    }

    /// The share toolbar button's view, when AppKit has installed one. File ▸
    /// Share… prefers this as the picker anchor so the sheet pops from the
    /// button rather than the whole window.
    static var shareToolbarItemView: NSView? { libraryToolbar?.shareItemView }

    static func presentSharePicker(for noteURL: URL, relativeTo view: NSView) {
        libraryToolbar?.presentSharePicker(for: noteURL, relativeTo: view)
    }

    @objc func printNote(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.printCommand, object: nil)
    }

    /// One note, one save panel. The menu item is disabled for a multi-selection
    /// rather than firing N panels in a row — see `validateMenuItem`.
    @objc func exportPDF(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.exportPDFCommand, object: nil)
    }

    @objc func openExternal(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.openExternalCommand, object: nil)
    }

    @objc func deleteNote(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.deleteCommand, object: nil)
    }

    @objc func matchFilenameToTitle(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.matchFilenameCommand, object: nil)
    }

    @objc func renameNote(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.renameCommand, object: nil)
    }

    /// ⌘F means "find where I am": the shown note when the keyboard is in the
    /// preview, the whole library everywhere else.
    ///
    /// The preview only carries a find bar while it is showing one note. With
    /// nothing selected, or with several notes selected, there is nothing in
    /// the preview to search — ⌘F falls back to the library search field, and
    /// the find bar's state is left alone so it cannot pop up later on its own.
    @objc func focusSearch(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        let model = LibraryModel.shared
        if model.focusedPane == .preview, model.rootURL != nil, model.focusedNote != nil {
            model.showPreviewFind()
        } else {
            Self.libraryToolbar?.focusSearch()
        }
    }

    /// The sidebar item names the action rather than the state, the way Finder
    /// and Mail do; the toolbar button already flips the same way.
    ///
    /// `NSMenuItemValidation` has to be declared. Without it this method is not
    /// `@objc`, so the Objective-C runtime cannot see it and AppKit never calls
    /// it — the title stayed on "Hide Sidebar" whatever the sidebar was doing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLibrarySidebar(_:)) {
            menuItem.title = LibraryModel.shared.sidebarVisible
                ? NSLocalizedString("Hide Sidebar", comment: "")
                : NSLocalizedString("Show Sidebar", comment: "")
        }
        // Print, Share and Export all need exactly one focused note. With
        // nothing selected, or with several notes selected, there is no single
        // note to print, share or write: the items grey out instead of opening
        // a panel they could not use.
        if menuItem.action == #selector(exportPDF(_:))
            || menuItem.action == #selector(printNote(_:))
            || menuItem.action == #selector(shareNote(_:)) {
            return LibraryModel.shared.focusedNote != nil
        }
        // The popover is anchored on a note row and edits the selection, so with
        // nothing selected there is neither an anchor nor anything to tag.
        if menuItem.action == #selector(editTags(_:)) {
            return !LibraryModel.shared.selectedNotes.isEmpty
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppSettings.shared.quitOnWindowClose {
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    /// Closing the library keeps the app running — the two global shortcuts
    /// depend on it — so the controller, the hosting controller and the whole
    /// view tree stay alive. Releasing them was studied and refused: the
    /// `HSplitView` column widths have no autosave name, both scroll offsets
    /// and the focus would go with them, and `applicationDidBecomeActive`
    /// guards on `currentWindow`, so ⌘Tab would stop restoring the library.
    ///
    /// What does go is the `WKWebView`, and with it three WebKit helper
    /// processes holding a document nobody can see. It comes back on
    /// `windowDidBecomeKey` with the same note at the same scroll position.
    func windowWillClose(_ notification: Notification) {
        PreviewBridge.shared.suspend()
    }

    /// Every path that puts the library back on screen makes it key —
    /// `show()`, the Dock, ⌘Tab, the bring-to-front shortcut, ⌘F — so this is
    /// the one place the preview has to be rebuilt from. It is a no-op unless
    /// the preview is actually suspended, which ordinary focus changes are not.
    func windowDidBecomeKey(_ notification: Notification) {
        PreviewBridge.shared.resume()
    }

    static var currentWindow: NSWindow? { shared?.window }

    /// Hands the keyboard back to the SwiftUI columns. Setting `@FocusState`
    /// does nothing while an AppKit control — the toolbar's search field — is
    /// the first responder.
    static func focusContentView() {
        guard let controller = shared, let view = controller.hosted?.view else { return }
        controller.window?.makeFirstResponder(view)
    }

    static func show(activateApplication: Bool = true) {
        if let existing = shared, let window = existing.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            existing.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            // `windowDidBecomeKey` normally carries this, and does it first;
            // said again here so a reopen that somehow never takes key — a
            // Settings sheet already holding it — still gets its preview back.
            PreviewBridge.shared.resume()
            if activateApplication {
                NSApp.activate(ignoringOtherApps: true)
            }
            NotificationCenter.default.post(name: storageDidChange, object: nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shokonotes"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.toolbarStyle = .unified
        // The content runs the full height of the window, titlebar included, so
        // each column paints its own background up there: the backdrop above the
        // sidebar, `textBackgroundColor` above the note list and the preview.
        // That is what the system does, and it is what keeps the titlebar strip
        // from reading as a band of its own above the folder column.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // Opaque, since the backdrop below is. A clear window background was
        // what the vibrancy needed; kept, it would show through as a flash of
        // nothing wherever the content has not been redrawn yet — the sidebar
        // divider being dragged is exactly that case.
        // Set for real by `applySidebarMode` once the controller exists: opaque
        // and flat for the opaque sidebar, the system glass otherwise.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        // Wide enough for the three columns at their minimum, dividers
        // included: sidebar 200 (its own `minWidth`, which is what actually
        // binds) + note list 340 + preview 420 + two 1pt split dividers. The
        // note list keeps its 340 so the toolbar search field stays a field
        // rather than collapsing to a magnifier button.
        window.contentMinSize = NSSize(width: 962, height: 420)
        window.setFrameAutosaveName("shokonotes.library.window")
        if window.frame.width < 800 || window.frame.height < 500 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        let targetFrame = window.frame

        // The window's backdrop, and the *only* layer of background the folder
        // column has. The sidebar leaves its own background clear so this shows
        // through; the note list and the preview paint `textBackgroundColor`
        // over it.
        //
        // It used to be an `NSVisualEffectView` in `.sidebar` material. The
        // vibrancy is gone, and deliberately: removing the SwiftUI wash that
        // sat on top of it took away one flicker, but the flash at every
        // application switch survived — the human sees the same flash in every
        // app with a translucent panel, so the cause is the vibrancy itself,
        // which redraws on AppKit's own desaturation clock. One layer, opaque,
        // and there is no second clock to beat.
        //
        // `windowBackgroundColor` is the compensation asked for: it is the flat
        // system panel tone, lighter in light appearance than a blurred desktop
        // usually came out, and in dark appearance lighter than the
        // `textBackgroundColor` of the two columns beside it. Either way the
        // column is distinct from its neighbours and never the darkest surface.
        // `controlBackgroundColor` was the other candidate and is refused: it is
        // essentially `textBackgroundColor` in both appearances, so the column
        // would have merged into the note list. `underPageBackgroundColor` is
        // the darkest of the three in light appearance — the opposite of what
        // was asked.
        //
        // The rule that costs an application if it is broken stays: **one**
        // layer of background on this column. Nothing in the SwiftUI tree may
        // add a second.
        let backdrop = OpaqueBackdropView()

        let hosting = NSHostingController(rootView: LibraryView())
        hosting.sizingOptions = []
        // The window's toolbar and title are ours (`LibraryToolbarController`);
        // the `NavigationSplitView` of the glass mode must not take them over.
        hosting.sceneBridgingOptions = []
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])

        let container = NSViewController()
        container.view = backdrop
        container.addChild(hosting)
        window.contentViewController = container

        let controller = LibraryWindowController(window: window)
        controller.hosted = hosting
        controller.backdrop = backdrop
        controller.applySidebarMode(force: true)
        controller.sidebarModeObserver = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] _ in controller?.applySidebarMode() }
        shared = controller
        window.delegate = controller
        controller.showWindow(nil)
        window.setFrame(targetFrame, display: true)
        window.makeKeyAndOrderFront(nil)

        let toolbar = LibraryToolbarController()
        libraryToolbar = toolbar
        // The tracking separators need the split view, which SwiftUI only
        // builds on the first layout pass.
        window.contentView?.layoutSubtreeIfNeeded()

        window.toolbar = toolbar.makeToolbar(
            splitView: LibraryToolbarController.splitView(in: window.contentView))
        // A `NavigationSplitView` may not have built its split view by the first
        // layout pass; look again on the next turn and rebuild if it appeared.
        DispatchQueue.main.async { [weak toolbar] in
            window.contentView?.layoutSubtreeIfNeeded()
            toolbar?.structureDidChange()
        }

        if activateApplication {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
