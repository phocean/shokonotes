import UIKit
import UniformTypeIdentifiers

/// Share extension → host. The durable queue and the Inbox file write live
/// in `ShareModel.post`. This type is the `UIPasteboard` layer plus the short
/// `shokonotes://inbox` open URL. URL coding, the marker and the UTF-16 bound
/// are in `InboxHandoffCodec` (`Shokonotes/Library/InboxCapture.swift`).
enum InboxHandoff {
    static var scheme: String { InboxHandoffCodec.scheme }
    static var host: String { InboxHandoffCodec.host }
    static var bodyQuery: String { InboxHandoffCodec.bodyQuery }
    static var pasteboardMarker: String { InboxHandoffCodec.pasteboardMarker }
    static var maxUTF16Length: Int { InboxHandoffCodec.maxUTF16Length }

    /// Local-only so a draft does not ride Universal Clipboard onto his Mac.
    /// 24 hours: two Publier without opening the app must still be ingestible.
    static let pasteboardLifetime: TimeInterval = 24 * 60 * 60

    /// `shokonotes://inbox` with no body. The queue and the pasteboard list
    /// hold the text; a huge query was losing drafts in Brave.
    static var inboxURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        return components.url
    }

    /// Appends `text` to the marked pasteboard list. Does not replace a
    /// previous marked draft (JSON array or the old single-body payload).
    static func append(_ text: String) {
        let body = truncated(text)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var items = InboxHandoffCodec.queue(from: UIPasteboard.general.string)
        items.append(body)
        writePasteboard(InboxHandoffCodec.marked(items))
    }

    static func openURL(body: String) -> URL? {
        InboxHandoffCodec.openURL(body: body)
    }

    static func body(from url: URL) -> String? {
        InboxHandoffCodec.body(from: url)
    }

    static func isInboxURL(_ url: URL) -> Bool {
        InboxHandoffCodec.isInboxURL(url)
    }

    static func truncated(_ text: String) -> String {
        InboxHandoffCodec.truncated(text)
    }

    /// Query `body` first (old clients); then the marked pasteboard list.
    /// Consumes the pasteboard so a later take cannot ingest twice.
    static func take(from url: URL) -> [String] {
        var items: [String] = []
        if let body = body(from: url) {
            items.append(body)
        }
        for draft in takeQueue() where !items.contains(draft) {
            items.append(draft)
        }
        return items
    }

    /// Marked pasteboard list. Takes the marker off so we do not ingest twice.
    /// Leaves the last draft as plain text instead of emptying the clipboard.
    static func takeQueue() -> [String] {
        let items = InboxHandoffCodec.queue(from: UIPasteboard.general.string)
        guard !items.isEmpty else { return [] }
        let usable = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let last = usable.last {
            writePasteboard(last)
        } else {
            UIPasteboard.general.items = []
        }
        return usable
    }

    /// Single-body leftover of `takeQueue()`. Prefer the list.
    static func takePending() -> String? {
        takeQueue().last
    }

    private static func writePasteboard(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(pasteboardLifetime)
            ]
        )
    }
}
