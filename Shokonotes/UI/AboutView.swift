import SwiftUI
import AppKit

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text(AppDelegate.appTitle).font(.title2).bold()

            Text(verbatim: version)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("A library for Markdown notes. Editing happens in your own editor.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)

            Text(verbatim: "GPLv3 © Jean-Christophe Baptiste")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 380)
    }
}

final class AboutWindowController: NSWindowController {
    private static var shared: AboutWindowController?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = ""
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AboutView())
        window.center()

        let controller = AboutWindowController(window: window)
        shared = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
