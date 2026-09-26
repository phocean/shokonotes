import AppKit

enum NoteActions {
    /// YAML front matter only. `title:` is quoted. No H1 is inserted.
    static func newNoteBody(named name: String) -> String {
        FrontMatterCodec.newNote(title: name)
    }

    static func openExternally(_ urls: [URL], bundleIdentifier: String) {
        guard !urls.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let appURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? workspace.urlForApplication(withBundleIdentifier: ExternalEditors.textEditBundle)

        guard let appURL else {
            presentOpenFailure()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        workspace.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            if error != nil {
                DispatchQueue.main.async { presentOpenFailure() }
            }
        }
    }

    private static func presentOpenFailure() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Unable to open external editor", comment: "")
        alert.informativeText = NSLocalizedString(
            "Check the external editor in Settings (for example, Typora).", comment: "")
        alert.runModal()
    }
}
