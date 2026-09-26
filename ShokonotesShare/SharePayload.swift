import Foundation
import UniformTypeIdentifiers

/// Text and at most one web URL from the host's share items.
enum SharePayload {
    struct Result {
        var text: String?
        var url: URL?
    }

    private static let urlTypes = [
        UTType.url.identifier,
        UTType.fileURL.identifier
    ]

    private static let textTypes = [
        UTType.plainText.identifier,
        UTType.text.identifier,
        UTType.utf8PlainText.identifier
    ]

    static func load(items: [Any]) async -> Result {
        var texts: [String] = []
        var urls: [URL] = []

        for item in items {
            guard let item = item as? NSExtensionItem else { continue }
            if let title = usable(item.attributedTitle?.string) {
                texts.append(title)
            }
            if let body = usable(item.attributedContentText?.string) {
                texts.append(body)
            }
            for provider in item.attachments ?? [] {
                if let url = await url(from: provider) {
                    urls.append(url)
                }
                if let text = await text(from: provider) {
                    texts.append(text)
                }
            }
        }

        var url = urls.compactMap(webURL).first
        var leftover: [String] = []
        for candidate in texts {
            guard let usableText = usable(candidate) else { continue }
            if let asURL = webURL(fromString: usableText) {
                if url == nil { url = asURL }
                continue
            }
            leftover.append(usableText)
        }

        let urlString = url?.absoluteString
        let text = leftover.first { candidate in
            if let urlString, candidate == urlString { return false }
            return true
        }
        return Result(text: text, url: url)
    }

    private static func usable(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func webURL(_ url: URL) -> URL? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func webURL(fromString string: String) -> URL? {
        guard let url = URL(string: string) else { return nil }
        return webURL(url)
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: URL.self) {
            if let loaded = await loadURLObject(from: provider) {
                return webURL(loaded) ?? webURL(fromString: loaded.absoluteString)
            }
        }
        for type in urlTypes where provider.hasItemConformingToTypeIdentifier(type) {
            guard let url = await loadURLItem(from: provider, type: type) else { continue }
            if let web = webURL(url) { return web }
            if let web = webURL(fromString: url.absoluteString) { return web }
        }
        return nil
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        if let loaded = await loadStringObject(from: provider), let usableText = usable(loaded) {
            return usableText
        }
        for type in textTypes where provider.hasItemConformingToTypeIdentifier(type) {
            if let text = await loadTextItem(from: provider, type: type),
               let usableText = usable(text) {
                return usableText
            }
        }
        return nil
    }

    /// Brave (and other Chromium shells) often fail `loadItem` and succeed here.
    private static func loadURLObject(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadStringObject(from provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                continuation.resume(returning: string)
            }
        }
    }

    private static func loadURLItem(from provider: NSItemProvider, type: String) async -> URL? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: type) else {
            return nil
        }
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func loadTextItem(from provider: NSItemProvider, type: String) async -> String? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: type) else {
            return nil
        }
        if let text = item as? String { return text }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let url = item as? URL { return url.absoluteString }
        return nil
    }
}
