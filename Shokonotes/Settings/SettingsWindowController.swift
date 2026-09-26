import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show() {
        if let existing = shared {
            if let window = existing.window {
                lockChrome(window)
            }
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Settings", comment: "")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 500)

        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = []
        // Today's default; written down so a SwiftUI change cannot silently let
        // the panes draw into the titlebar safe area.
        hosting.safeAreaRegions = .all
        window.contentViewController = hosting
        // Setting contentViewController resizes the window to the controller's
        // preferred size — zero with sizingOptions = [] — so the window falls
        // back to contentMinSize. Restore the intended size explicitly.
        window.setContentSize(NSSize(width: 760, height: 560))
        // Compact titled bar. Do not copy the library's hidden title, unified
        // toolbar, or fullSizeContentView — those eat the first row and inject
        // a sidebar-collapse control. Lock chrome after hosting, in case SwiftUI
        // tries to promote the window.
        Self.lockChrome(window)
        window.center()

        let controller = SettingsWindowController(window: window)
        shared = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Belt: re-lock once after the first layout pass, in case SwiftUI ever
        // promotes the window to full-size content. Once only — re-locking on
        // every layout would flicker the title.
        DispatchQueue.main.async { Self.lockChrome(window) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let window {
            Self.lockChrome(window)
        }
    }

    private static func lockChrome(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .resizable]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbar = nil
    }
}
