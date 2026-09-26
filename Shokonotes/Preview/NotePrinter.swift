import AppKit
import WebKit

@MainActor
enum NotePrinter {
    static func print(_ note: NoteSnapshot) {
        // The body is already in memory, front matter removed; printing does
        // not go back to the disk for it. Same renderer as the preview and as
        // the PDF export, so all three agree on the page.
        PreviewPageRenderer.load(note) { result in
            guard case .success(let webView) = result else { return }
            NotePrintJob.run(webView: webView)
        }
    }

    /// A copy of `base` with the same pagination PDF export uses: fit across,
    /// automatic down the page, not centered. A tall note centered on the
    /// first sheet is an empty first page. Disposition stays whatever `base`
    /// had (`.spool` on `.shared`) — this is paper, not a save-to-PDF job.
    static func printInfo(from base: NSPrintInfo = .shared) -> NSPrintInfo {
        // `copy()` so pagination never writes back into `.shared`. Printer
        // choice still starts from the shared info the panel last used.
        let info = base.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        return info
    }

    /// The print panel is a sheet on the library when that window is on
    /// screen. Closed or miniaturized, the off-screen host is the
    /// `runModal(for:)` window so print still works while the app is running
    /// without a visible library.
    static func printPanelAttachesToLibrary(isVisible: Bool, isMiniaturized: Bool) -> Bool {
        isVisible && !isMiniaturized
    }
}

/// A WKWebView print operation needs the main run loop to keep turning while
/// the web process hands over the pages, so this is run with
/// `runModal(for:delegate:didRun:)` and never with `run()`. The view is kept
/// in an off-screen window until the callback: WebKit paints the panel
/// preview from the web process but spools a blank page if the view is not
/// in a window.
@MainActor
private final class NotePrintJob: NSObject {
    /// Jobs in flight. Nothing else holds one between `run` and its callback,
    /// and `PreviewPageRenderer` has already dropped its own retain.
    private static var live: [NotePrintJob] = []

    private var webView: WKWebView?
    private var host: NSWindow?

    static func run(webView: WKWebView) {
        let job = NotePrintJob()
        live.append(job)
        job.start(webView: webView)
    }

    private func start(webView: WKWebView) {
        self.webView = webView

        // Off-screen, never ordered front. PDF export creates a host and
        // never sets `contentView`; print must, or WebKit paints the panel
        // preview from the web process and spools a blank page.
        let host = NSWindow(
            contentRect: PreviewPageRenderer.pageBox,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.isExcludedFromWindowsMenu = true
        host.contentView = webView
        self.host = host

        let operation = webView.printOperation(with: NotePrinter.printInfo())
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true

        let library = LibraryWindowController.currentWindow
        let parent: NSWindow
        if let library, NotePrinter.printPanelAttachesToLibrary(
            isVisible: library.isVisible,
            isMiniaturized: library.isMiniaturized
        ) {
            parent = library
        } else {
            parent = host
        }

        operation.runModal(
            for: parent,
            delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        finish()
    }

    private func finish() {
        host?.contentView = nil
        host?.close()
        host = nil
        webView = nil
        Self.live.removeAll { $0 === self }
    }
}
