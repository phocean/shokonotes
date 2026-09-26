import Foundation

/// One Inbox note at the library root. No `LibraryStore`, no rescan — the
/// share extension is too short-lived for a full scan.
enum InboxCapture {
    /// Safari / Mail payload → one string. Text only, URL only, or text then
    /// a blank line then the URL.
    static func compose(text: String?, url: URL?) -> String {
        let usableText: String? = {
            guard let text else { return nil }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return text
        }()
        switch (usableText, url) {
        case (let text?, let url?):
            return "\(text)\n\n\(url.absoluteString)"
        case (let text?, nil):
            return text
        case (nil, let url?):
            return url.absoluteString
        case (nil, nil):
            return ""
        }
    }

    /// A shared paragraph has no newline, so the "first line" can be the whole
    /// payload. The YAML `title` is a label, not the note: bound it. The body
    /// is never touched.
    static let maxTitleLength = 120

    /// First non-empty line, else the start of the text, else Untitled.
    /// Bounded by `maxTitleLength`, at a word boundary when there is one.
    static func captureTitle(from text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return bounded(trimmed) }
        }
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !start.isEmpty { return bounded(start) }
        return NSLocalizedString("Untitled Note", comment: "")
    }

    /// Cuts at the last space in the second half of the allowance, so a bound
    /// never lands mid-word unless the word itself is longer than the bound.
    private static func bounded(_ title: String) -> String {
        guard title.count > maxTitleLength else { return title }
        let head = title.prefix(maxTitleLength)
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) > maxTitleLength / 2 {
            return String(head[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(head).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes one `.md` at `inbox` (library root). Empty/whitespace → nil, no file.
    /// YAML `title` follows `captureTitle`. Body on disk is YAML plus exactly `text`.
    @discardableResult
    static func write(text: String, into inbox: URL, fileExtension: String = "md") throws -> URL? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let title = captureTitle(from: text)
        let body = FrontMatterCodec.newNote(title: title, body: text)
        let name = FilenameSanitizer.sanitize(title)
        let unique = FilenameSanitizer.uniqueName(base: name, ext: fileExtension, in: inbox)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let url = inbox.appendingPathComponent(unique).appendingPathExtension(fileExtension)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Resolves the security-scoped bookmark, accesses it, writes, then stops.
    @discardableResult
    static func write(text: String, bookmark: Data, fileExtension: String = "md") throws -> URL? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let inbox: URL
        do {
            inbox = try BookmarkStore.resolve(bookmark).url
        } catch {
            throw LibraryError.cannotOpenFolder
        }
        let accessed = inbox.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                inbox.stopAccessingSecurityScopedResource()
            }
        }
        if !accessed {
            // iOS must have the scope. A local folder in Mac tests is already
            // visible; `startAccessing` returns false without a sandbox.
            #if os(iOS)
            throw LibraryError.cannotOpenFolder
            #else
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                throw LibraryError.cannotOpenFolder
            }
            #endif
        }
        return try write(text: text, into: inbox, fileExtension: fileExtension)
    }
}

/// Durable Inbox drafts. Append, never overwrite. Production:
/// `InboxShareQueue(defaults: AppGroup.defaults ?? .standard)` so a signed
/// share extension and the host share one suite.
struct InboxShareQueue {
    static let key = "inboxShareQueue"

    var defaults: UserDefaults

    /// Ignores empty / whitespace. Stores the text as given.
    func enqueue(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var next = items
        next.append(text)
        persist(next)
    }

    /// All items, then clear. Order is the enqueue order.
    func drain() -> [String] {
        let current = items
        defaults.removeObject(forKey: Self.key)
        return current
    }

    /// Peek. Does not clear.
    var items: [String] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func persist(_ items: [String]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The pure half of the share-extension → host handoff: URL coding, the
/// pasteboard marker (JSON array of drafts, with a single-body fallback),
/// and the UTF-16 bound. It lives here rather than in `InboxHandoff` because
/// that file imports UIKit, which the macOS test target cannot reach — and
/// an unencoded `%` shipped for exactly that reason.
/// `InboxHandoff` keeps only the `UIPasteboard` layer.
enum InboxHandoffCodec {
    static let scheme = "shokonotes"
    static let host = "inbox"
    static let bodyQuery = "body"
    /// Public text, not a custom UTI. Other processes often cannot read undeclared types.
    static let pasteboardMarker = "§shokonotes-inbox§\n"
    static let maxUTF16Length = 16_000

    /// `urlQueryAllowed` contains `%` and `#`: without removing them a shared
    /// "-20% off" becomes a stray escape in `percentEncodedQuery`, and `#`
    /// truncates the body at a fragment.
    static let bodyDisallowed = "&+=?%#"

    static func openURL(body: String) -> URL? {
        let truncated = truncated(body)
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: bodyDisallowed)
        let encoded = truncated.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        components.percentEncodedQuery = "\(bodyQuery)=\(encoded)"
        return components.url
    }

    static func body(from url: URL) -> String? {
        guard isInboxURL(url) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let raw = components.percentEncodedQueryItems?.first(where: { $0.name == bodyQuery })?.value
            ?? components.queryItems?.first(where: { $0.name == bodyQuery })?.value
        guard let raw else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : decoded
    }

    static func isInboxURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    /// Never cuts a surrogate pair in half: an emoji at the bound is dropped
    /// whole rather than left as a lone lead unit.
    static func truncated(_ text: String) -> String {
        let utf16 = text.utf16
        guard utf16.count > maxUTF16Length else { return text }
        let end = utf16.index(utf16.startIndex, offsetBy: maxUTF16Length)
        var units = Array(utf16[utf16.startIndex..<end])
        if let last = units.last, UTF16.isLeadSurrogate(last) {
            units.removeLast()
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Marked payload for the pasteboard. The reader strips the marker.
    static func marked(_ text: String) -> String {
        pasteboardMarker + text
    }

    /// JSON array of drafts after the marker.
    static func marked(_ drafts: [String]) -> String {
        let json: String
        if let data = try? JSONEncoder().encode(drafts),
           let encoded = String(data: data, encoding: .utf8) {
            json = encoded
        } else {
            json = "[]"
        }
        return pasteboardMarker + json
    }

    /// The text behind the marker, or nil when this is not our payload.
    static func unmarked(_ string: String?) -> String? {
        guard let string, string.hasPrefix(pasteboardMarker) else { return nil }
        return String(string.dropFirst(pasteboardMarker.count))
    }

    /// Drafts in a marked string. A JSON array, or one item for the old
    /// single-body format. Not our marker → empty.
    static func queue(from string: String?) -> [String] {
        guard let rest = unmarked(string) else { return [] }
        if let data = rest.data(using: .utf8),
           let items = try? JSONDecoder().decode([String].self, from: data) {
            return items
        }
        return [rest]
    }
}
