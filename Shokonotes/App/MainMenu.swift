import AppKit

enum MainMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(windowMenuItem())
        NSApp.mainMenu = main
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    private static func appMenuItem() -> NSMenuItem {
        let name = ProcessInfo.processInfo.processName
        return submenu(name) { menu in
            menu.addItem(
                withTitle: String(format: NSLocalizedString("About %@", comment: ""), name),
                action: #selector(AppDelegate.showAboutWindow(_:)),
                keyEquivalent: "")
            menu.addItem(.separator())
            let settings = menu.addItem(
                withTitle: NSLocalizedString("Settings…", comment: ""),
                action: #selector(AppDelegate.openPreferences(_:)),
                keyEquivalent: ",")
            settings.keyEquivalentModifierMask = [.command]
            menu.addItem(.separator())
            menu.addItem(
                withTitle: String(format: NSLocalizedString("Hide %@", comment: ""), name),
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h")
            let hideOthers = menu.addItem(
                withTitle: NSLocalizedString("Hide Others", comment: ""),
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(
                withTitle: NSLocalizedString("Show All", comment: ""),
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(
                withTitle: String(format: NSLocalizedString("Quit %@", comment: ""), name),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
        }
    }

    private static func fileMenuItem() -> NSMenuItem {
        submenu(NSLocalizedString("File", comment: "")) { menu in
            menu.addItem(
                withTitle: NSLocalizedString("New Note", comment: ""),
                action: #selector(LibraryWindowController.newNote(_:)),
                keyEquivalent: "n")
            let newFolder = menu.addItem(
                withTitle: NSLocalizedString("New Folder", comment: ""),
                action: #selector(LibraryWindowController.newFolder(_:)),
                keyEquivalent: "n")
            newFolder.keyEquivalentModifierMask = [.command, .shift]
            let open = menu.addItem(
                withTitle: NSLocalizedString("Open External", comment: ""),
                action: #selector(LibraryWindowController.openExternal(_:)),
                keyEquivalent: "o")
            open.keyEquivalentModifierMask = [.command]
            let rename = menu.addItem(
                withTitle: NSLocalizedString("Rename…", comment: ""),
                action: #selector(LibraryWindowController.renameNote(_:)),
                keyEquivalent: "r")
            rename.keyEquivalentModifierMask = [.command]
            menu.addItem(
                withTitle: NSLocalizedString("Rename file", comment: ""),
                action: #selector(LibraryWindowController.matchFilenameToTitle(_:)),
                keyEquivalent: "")
            menu.addItem(.separator())
            // ⌃⌘T is Finder's own chord for exactly this popover on exactly this
            // kind of selection. Not a chord invented here: the whole point of
            // the item is that the editor is reachable without the pointer, and
            // a shortcut the human already has in his fingers costs nothing to
            // learn. Nothing else in this app claims it.
            let tags = menu.addItem(
                withTitle: NSLocalizedString("Tags…", comment: ""),
                action: #selector(LibraryWindowController.editTags(_:)),
                keyEquivalent: "t")
            tags.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(
                withTitle: NSLocalizedString("Pin", comment: ""),
                action: #selector(LibraryWindowController.pinNote(_:)),
                keyEquivalent: "")
            menu.addItem(.separator())
            let reveal = menu.addItem(
                withTitle: NSLocalizedString("Reveal in Finder", comment: ""),
                action: #selector(LibraryWindowController.revealInFinder(_:)),
                keyEquivalent: "r")
            reveal.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(
                withTitle: NSLocalizedString("Share…", comment: ""),
                action: #selector(LibraryWindowController.shareNote(_:)),
                keyEquivalent: "")
            menu.addItem(.separator())
            let delete = menu.addItem(
                withTitle: NSLocalizedString("Delete", comment: ""),
                action: #selector(LibraryWindowController.deleteNote(_:)),
                keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
            delete.keyEquivalentModifierMask = [.command]
            menu.addItem(.separator())
            menu.addItem(
                withTitle: NSLocalizedString("Close", comment: ""),
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w")
            menu.addItem(
                withTitle: NSLocalizedString("Print…", comment: ""),
                action: #selector(LibraryWindowController.printNote(_:)),
                keyEquivalent: "p")
            // Beside Print, because it is the same page through the same
            // pagination — one written to disk instead of to a printer. No key
            // equivalent: nothing in the system reserves one for Export, and a
            // chord invented here would be one more thing to remember.
            menu.addItem(
                withTitle: NSLocalizedString("Export as PDF…", comment: ""),
                action: #selector(LibraryWindowController.exportPDF(_:)),
                keyEquivalent: "")
        }
    }

    private static func editMenuItem() -> NSMenuItem {
        submenu(NSLocalizedString("Edit", comment: "")) { menu in
            menu.addItem(withTitle: NSLocalizedString("Undo", comment: ""),
                         action: Selector(("undo:")), keyEquivalent: "z")
            let redo = menu.addItem(withTitle: NSLocalizedString("Redo", comment: ""),
                                    action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(.separator())
            menu.addItem(withTitle: NSLocalizedString("Cut", comment: ""),
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            menu.addItem(withTitle: NSLocalizedString("Copy", comment: ""),
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            menu.addItem(withTitle: NSLocalizedString("Paste", comment: ""),
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            menu.addItem(withTitle: NSLocalizedString("Select All", comment: ""),
                         action: #selector(AppDelegate.selectAllNotes(_:)), keyEquivalent: "a")
            menu.addItem(.separator())
            let find = menu.addItem(withTitle: NSLocalizedString("Find", comment: ""),
                                    action: #selector(LibraryWindowController.focusSearch(_:)),
                                    keyEquivalent: "f")
            find.keyEquivalentModifierMask = [.command]
            menu.addItem(
                withTitle: NSLocalizedString("Find Next", comment: ""),
                action: #selector(LibraryWindowController.findNext(_:)),
                keyEquivalent: "g")
            let findPrev = menu.addItem(
                withTitle: NSLocalizedString("Find Previous", comment: ""),
                action: #selector(LibraryWindowController.findPrevious(_:)),
                keyEquivalent: "g")
            findPrev.keyEquivalentModifierMask = [.command, .shift]
        }
    }

    private static func viewMenuItem() -> NSMenuItem {
        submenu(NSLocalizedString("View", comment: "")) { menu in
            let sidebar = menu.addItem(
                withTitle: NSLocalizedString("Hide Sidebar", comment: ""),
                action: #selector(LibraryWindowController.toggleLibrarySidebar(_:)),
                keyEquivalent: "s")
            sidebar.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(.separator())
            let fullScreen = menu.addItem(
                withTitle: NSLocalizedString("Enter Full Screen", comment: ""),
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f")
            fullScreen.keyEquivalentModifierMask = [.command, .control]
        }
    }

    static func windowMenuItem() -> NSMenuItem {
        let item = submenu(NSLocalizedString("Window", comment: "")) { menu in
            menu.addItem(withTitle: NSLocalizedString("Minimize", comment: ""),
                         action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            menu.addItem(withTitle: NSLocalizedString("Zoom", comment: ""),
                         action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            let library = menu.addItem(
                withTitle: NSLocalizedString("Library", comment: ""),
                action: #selector(AppDelegate.showLibraryWindow(_:)),
                keyEquivalent: "0")
            library.keyEquivalentModifierMask = [.command]
            menu.addItem(.separator())
            menu.addItem(withTitle: NSLocalizedString("Bring All to Front", comment: ""),
                         action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        }
        NSApp.windowsMenu = item.submenu
        return item
    }
}
