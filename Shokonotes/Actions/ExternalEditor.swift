import AppKit
import UniformTypeIdentifiers

enum ExternalEditors {
    static let textEditBundle = "com.apple.TextEdit"

    private static let known: [(name: String, bundle: String)] = [
        ("Typora", "abnerworks.Typora"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Marked 2", "com.brettterpstra.marked2"),
        ("TextEdit", textEditBundle),
    ]

    static func defaultBundleIdentifier() -> String {
        if bundleExists("abnerworks.Typora") { return "abnerworks.Typora" }
        return textEditBundle
    }

    static func installed() -> [(name: String, bundle: String)] {
        known.filter { bundleExists($0.bundle) }
    }

    static func displayName(for bundle: String) -> String {
        if let known = known.first(where: { $0.bundle == bundle }) {
            return known.name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundle
    }

    static func bundleExists(_ identifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
    }

    static func pickApplication() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
    }
}
