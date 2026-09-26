import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var appTitle: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return name ?? Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as! String
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        AppSettings.shared.applyAppearance()
        LibraryWindowController.show()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        GlobalShortcuts.register()
        if !LibraryModel.shared.restoreSavedRoot() {
            LibraryModel.shared.chooseStorageFolder()
        }
        DockBadge.refresh()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.attachedSheet != nil }),
              let library = LibraryWindowController.currentWindow,
              !library.isVisible || library.isMiniaturized else { return }
        // Restore the library on Cmd-Tab without taking focus from an open
        // Settings, About, or dialog window that AppKit already made key.
        let auxiliary = NSApp.keyWindow.flatMap { window in
            window !== library && window.isVisible && !window.isMiniaturized ? window : nil
        }
        LibraryWindowController.show(activateApplication: false)
        auxiliary?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let library = LibraryWindowController.currentWindow
        if library?.isVisible != true || library?.isMiniaturized == true {
            LibraryWindowController.show()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LibraryModel.shared.scopedRoot.stop()
    }

    @objc func showAboutWindow(_ sender: Any?) {
        AboutWindowController.show()
    }

    @objc func openPreferences(_ sender: Any?) {
        SettingsWindowController.show()
    }

    @objc func selectAllNotes(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSText {
            text.selectAll(sender)
            return
        }
        guard NSApp.keyWindow === LibraryWindowController.currentWindow else { return }
        NotificationCenter.default.post(name: LibraryWindowController.selectAllCommand, object: nil)
    }
}
