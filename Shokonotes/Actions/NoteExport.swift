import AppKit
import UniformTypeIdentifiers
import WebKit

/// Why an export could not be written. Presented through `NoteExport`'s own alert.
enum NoteExportError: LocalizedError, Equatable {
    case renderFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return NSLocalizedString("The note could not be rendered for export.", comment: "")
        case .writeFailed(let reason):
            return reason
        }
    }
}

/// Exporting a note **writes a new file**. The note on disk is never opened
/// for writing, never re-encoded, never renamed: the body is taken from the
/// snapshot already in memory, which is the first rule of this product.
@MainActor
enum NoteExport {

    /// Entry point for the File menu, the context menu and the share path.
    /// Asks the user where to save — the save panel is also what grants the
    /// sandboxed app the right to write there — then exports the note as PDF.
    /// The file name defaults to the note's title; overwriting is the panel's
    /// business, not ours.
    ///
    /// - Parameters:
    ///   - note: the note to export.
    ///   - window: the window to hang the save panel on as a sheet. Nil runs
    ///     the panel application-modal.
    ///   - completion: the written file, or nil when the user cancelled or the
    ///     export failed (the failure has already been presented).
    static func exportPDF(
        _ note: NoteSnapshot,
        in window: NSWindow? = nil,
        completion: @escaping (URL?) -> Void = { _ in }
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName(for: note, extension: "pdf")
        panel.prompt = NSLocalizedString("Export", comment: "Save panel button")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else {
                completion(nil)
                return
            }
            writePDF(note, to: destination) { result in
                switch result {
                case .success(let url):
                    completion(url)
                case .failure(let error):
                    present(error)
                    completion(nil)
                }
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// The panel-free core: renders the note through the preview's own
    /// cmark → HTML → WKWebView path and writes the PDF at `destination`.
    /// Nothing here touches `note.url`.
    static func writePDF(
        _ note: NoteSnapshot,
        to destination: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        PreviewPageRenderer.load(note) { result in
            switch result {
            case .failure:
                completion(.failure(NoteExportError.renderFailed))
            case .success(let webView):
                PDFPrintJob.run(webView: webView, to: destination, completion: completion)
            }
        }
    }

    /// The note's title, sanitized the same way a file name is anywhere else in
    /// the app, with the format's extension.
    static func suggestedFileName(for note: NoteSnapshot, extension ext: String) -> String {
        let base = FilenameSanitizer.sanitize(note.title)
        return (base as NSString).appendingPathExtension(ext) ?? "\(base).\(ext)"
    }

    private static func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("The note could not be exported.", comment: "")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// Draws a loaded page into a PDF file through the print system.
///
/// `WKWebView.createPDF` was tried first and measured: it returns the whole
/// document as **one** page — 800 × 7223 pt for a 120-paragraph note — which is
/// a screenshot, not a document. The print system is what paginates a web page
/// without cutting lines in half, and it is the same machinery ⌘P already uses,
/// so the exported file and the printed one are the same output.
///
/// It is run with `runModal(for:...)` and never with `run()`: a WKWebView print
/// operation needs the main run loop to keep turning while the web process
/// hands over the pages, and the synchronous call deadlocks waiting for it.
@MainActor
private final class PDFPrintJob: NSObject {
    /// Jobs in flight. Nothing else holds one between `run` and its callback.
    private static var live: [PDFPrintJob] = []

    private let destination: URL
    private var completion: ((Result<URL, Error>) -> Void)?
    private var webView: WKWebView?
    private var window: NSWindow?

    static func run(
        webView: WKWebView,
        to destination: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let job = PDFPrintJob(destination: destination, completion: completion)
        live.append(job)
        job.start(webView: webView)
    }

    private init(destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.completion = completion
    }

    private func start(webView: WKWebView) {
        self.webView = webView
        let operation = webView.printOperation(with: Self.printInfo(saving: destination))
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        // The operation wants a window to be modal for. Nothing is shown: no
        // panel is asked for, so this one never orders itself on screen — it
        // only gives the operation somewhere to run.
        let host = NSWindow(
            contentRect: PreviewPageRenderer.pageBox,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        host.isReleasedWhenClosed = false
        window = host

        operation.runModal(
            for: host,
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
        let wrote = success && FileManager.default.fileExists(atPath: destination.path)
        finish(wrote ? .success(destination) : .failure(NoteExportError.writeFailed(
            String(
                format: NSLocalizedString("The PDF could not be written to \"%@\".", comment: ""),
                destination.lastPathComponent
            )
        )))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let completion else { return }
        self.completion = nil
        window?.close()
        window = nil
        webView = nil
        completion(result)
        Self.live.removeAll { $0 === self }
    }

    private static func printInfo(saving destination: URL) -> NSPrintInfo {
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: destination,
        ])
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
}
