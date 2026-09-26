import SwiftUI
import UIKit

/// Share-to-Inbox. Persist first (queue, Inbox write, pasteboard list), then
/// an in-sheet check for ~0.7s, then finish. Opening the host is best-effort
/// during that delay. Empty Post dismisses with no check.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 320, height: 280)

        let host = UIHostingController(rootView: ShareSheetView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        model.start(extensionContext: extensionContext) { [weak self] url, done in
            self?.openHost(url, completion: done)
        }
    }

    /// `UIApplication.shared` is unavailable in the extension.
    /// `extensionContext.open` is the documented door; the `openURL:` walk
    /// covers hosts (Brave among them) that ignore it.
    /// Completes on the open callback *or* after 0.5s so Brave cannot hang
    /// the sheet.
    private func openHost(_ url: URL, completion: @escaping () -> Void) {
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completion()
        }
        extensionContext?.open(url, completionHandler: { _ in
            DispatchQueue.main.async(execute: finish)
        })
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
            }
            responder = current.next
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: finish)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var draft = ""
    @Published var isLoading = true
    @Published var isPosting = false
    @Published var didSave = false

    private var extensionContext: NSExtensionContext?
    private var openHost: ((URL, @escaping () -> Void) -> Void)?

    func start(
        extensionContext: NSExtensionContext?,
        openHost: @escaping (URL, @escaping () -> Void) -> Void
    ) {
        self.extensionContext = extensionContext
        self.openHost = openHost
        let items = extensionContext?.inputItems ?? []
        Task {
            let payload = await SharePayload.load(items: items)
            draft = InboxCapture.compose(text: payload.text, url: payload.url)
            isLoading = false
        }
    }

    func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
    }

    func post() {
        guard !isPosting else { return }
        isPosting = true
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishRequest()
            return
        }
        persistBeforeDismiss()
        didSave = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let url = InboxHandoff.inboxURL, let openHost {
            openHost(url) { }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.finishRequest()
        }
    }

    /// Queue, Inbox file, pasteboard list — in that order — before the sheet
    /// goes away. Opening the host is best-effort and often a no-op.
    private func persistBeforeDismiss() {
        InboxShareQueue(defaults: AppGroup.defaults ?? .standard).enqueue(draft)
        if let bookmark = AppGroup.storageBookmark {
            _ = try? InboxCapture.write(text: draft, bookmark: bookmark)
        }
        InboxHandoff.append(draft)
    }

    private func finishRequest() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
