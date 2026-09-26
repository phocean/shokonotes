import Foundation
import Darwin
import UniformTypeIdentifiers
import cmark_gfm
import cmark_gfm_extensions

enum MarkdownRenderer {
    static func html(
        from markdown: String,
        title: String,
        themeCSS: String = "",
        style: PreviewStyle = .default
    ) -> String {
        let rendered = gfmHTML(
            markdown,
            hardLineBreaks: style.hardLineBreaks,
            smartPunctuation: style.smartPunctuation
        )
        let masthead: String
        if style.showTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !bodyLeadsWithTitle(markdown, title: title) {
            masthead = "<header class=\"note-masthead\"><h1>\(escapeHTML(title))</h1></header>\n"
        } else {
            masthead = ""
        }
        return wrap(
            html: masthead + disableCheckboxes(in: rendered),
            title: title,
            themeCSS: themeCSS,
            style: style
        )
    }

    static func bodyHTML(
        from markdown: String,
        hardLineBreaks: Bool = false,
        smartPunctuation: Bool = false
    ) -> String {
        disableCheckboxes(in: gfmHTML(
            markdown,
            hardLineBreaks: hardLineBreaks,
            smartPunctuation: smartPunctuation
        ))
    }

    /// Compiled once. `NSRegularExpression` is documented as thread-safe for
    /// matching, and this one is immutable.
    private static let relativeURLRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"((?:src|href)=)(["'])(?!https?:|file:|mailto:|data:|#)([^"']+)\2"#,
        options: [.caseInsensitive]
    )

    /// The attribute the deferred-image marker is written into. The JS that
    /// swaps a rendition in finds its element by this, which is why it has to
    /// be stable and unique per image in the emitted document.
    static let deferredImageAttribute = "data-shoko-img"

    /// One image whose payload was not in the cache when the document was
    /// built. The element is already on screen carrying its `file://` `src`;
    /// the caller builds `descriptor` off the main thread and swaps the
    /// payload into the *live* document by `id`.
    struct DeferredImage: Sendable {
        let id: String
        let descriptor: PreviewImageRendition.Descriptor
    }

    /// A resolved document plus the images it is still waiting for.
    struct Resolution {
        var html: String
        var deferred: [DeferredImage]
    }

    /// Rewrites relative `src` / `href` against the note's folder. A local
    /// image `src` whose payload is **already cached** is inlined as a `data:`
    /// URI right here; one that is not keeps its `file://` URL, gains a
    /// `data-shoko-img` marker and is reported in `deferred` — nothing is read
    /// or encoded on this thread, at any size. Missing files, non-images and
    /// every `href` stay as `file://`, exactly as before.
    ///
    /// Builds the result in one forward pass — the previous per-match
    /// `replaceSubrange` on a `String` was quadratic in the number of images.
    static func resolve(
        _ html: String,
        base: URL,
        target: PreviewImageRendition.Target
    ) -> Resolution {
        guard let regex = relativeURLRegex else { return Resolution(html: html, deferred: []) }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Resolution(html: html, deferred: []) }

        var result = ""
        result.reserveCapacity(html.count + matches.count * 32)
        var deferred: [DeferredImage] = []
        var cursor = 0
        for match in matches {
            guard match.numberOfRanges == 4 else { continue }
            let whole = match.range
            let attr = ns.substring(with: match.range(at: 1))
            let quote = ns.substring(with: match.range(at: 2))
            let path = ns.substring(with: match.range(at: 3))
            result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))

            let resolved = URL(string: path, relativeTo: base)?.absoluteURL
                ?? base.appendingPathComponent(path)
            var value = resolved.absoluteString
            var marker = ""
            if attr.lowercased() == "src=",
               let descriptor = PreviewImageRendition.descriptor(for: resolved, target: target) {
                if let cached = PreviewImageRendition.cached(descriptor) {
                    value = cached
                } else {
                    let id = "shoko-img-\(deferred.count)"
                    deferred.append(DeferredImage(id: id, descriptor: descriptor))
                    marker = " \(deferredImageAttribute)=\"\(id)\""
                }
            }
            result += attr + quote + value + quote + marker
            cursor = whole.location + whole.length
        }
        result += ns.substring(from: cursor)
        return Resolution(html: result, deferred: deferred)
    }

    /// Builds every deferred payload into the cache. **Not for the main
    /// thread** — this is the read and the encode. Returns the payloads that
    /// were produced, keyed by element id; an image ImageIO cannot decode is
    /// simply absent and keeps the `file://` URL it already carries.
    static func buildDeferredImages(_ deferred: [DeferredImage]) -> [(id: String, uri: String)] {
        deferred.compactMap { item in
            guard let uri = PreviewImageRendition.payload(for: item.descriptor) else { return nil }
            return (id: item.id, uri: uri)
        }
    }

    /// Matches the `src` of an element `resolve` marked as deferred, together
    /// with the marker itself. The two are always adjacent and in this order
    /// because `resolve` above is the one place that writes them — the
    /// invariant lives in this file, next to the code that establishes it.
    private static let deferredMarkerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(src=)(["'])[^"']*\2(\s\#(deferredImageAttribute)=)(["'])([^"']+)\4"#,
        options: [.caseInsensitive]
    )

    /// Swaps built payloads into a document that still carries deferred-image
    /// markers, and drops each marker it consumes.
    ///
    /// This is the half an **export** uses, and the reason it exists is that a
    /// second `resolve` would recover the payloads only through
    /// `PreviewImageCache`, which is an `NSCache` and is free to evict between
    /// the build and the read — a page over the byte ceiling, or any page at
    /// all under memory pressure, would then be written to PDF with a dead
    /// `file://` src and no error. The payloads handed in here are the ones
    /// emitted, so correctness no longer depends on a cache hit; the cache
    /// stays a cache, and a hit inside `resolve` is still a saved encode.
    ///
    /// An id with no payload — an image ImageIO could not decode — is left
    /// exactly as `resolve` left it: its `file://` URL and its marker.
    static func substituteDeferredImages(
        in html: String,
        with payloads: [(id: String, uri: String)]
    ) -> String {
        guard !payloads.isEmpty, let regex = deferredMarkerRegex else { return html }
        var byID: [String: String] = [:]
        byID.reserveCapacity(payloads.count)
        for payload in payloads { byID[payload.id] = payload.uri }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        // One forward pass, like `resolve`: a per-match `replaceSubrange` on a
        // String is quadratic in the number of images.
        var result = ""
        result.reserveCapacity(html.count)
        var cursor = 0
        for match in matches {
            guard match.numberOfRanges == 6 else { continue }
            let whole = match.range
            let id = ns.substring(with: match.range(at: 5))
            guard let uri = byID[id] else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            let attr = ns.substring(with: match.range(at: 1))
            let quote = ns.substring(with: match.range(at: 2))
            result += attr + quote + uri + quote
            cursor = whole.location + whole.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Above this an image is inlined as a downscaled JPEG rendition rather
    /// than byte for byte. Kept as the renderer's own name for the rendition
    /// threshold so callers and tests have one place to read it from.
    static var inlineImageByteLimit: Int { PreviewImageRendition.inlineByteLimit }

    static func bodyLeadsWithTitle(_ markdown: String, title: String) -> Bool {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                trimmed = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            }
            return String(trimmed).compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return false
    }

    /// GitHub Flavored Markdown via swiftlang/swift-cmark. Safe HTML only
    /// (`CMARK_OPT_UNSAFE` is never set).
    private static func gfmHTML(
        _ markdown: String,
        hardLineBreaks: Bool,
        smartPunctuation: Bool
    ) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        var options = CMARK_OPT_FOOTNOTES
        if hardLineBreaks { options |= CMARK_OPT_HARDBREAKS }
        if smartPunctuation { options |= CMARK_OPT_SMART }

        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }

        for extensionName in ["table", "autolink", "strikethrough", "tasklist"] {
            if let ext = cmark_find_syntax_extension(extensionName) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }

        guard let cHTML = cmark_render_html(document, options, nil) else { return "" }
        defer { free(cHTML) }
        return String(cString: cHTML)
    }

    private static func disableCheckboxes(in html: String) -> String {
        html.replacingOccurrences(
            of: "<input type=\"checkbox\"",
            with: "<input type=\"checkbox\" disabled",
            options: .caseInsensitive
        )
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func wrap(
        html: String,
        title: String,
        themeCSS: String,
        style: PreviewStyle
    ) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>\(PreviewCSS.sheet(style))</style>
        <style>\(themeCSS)</style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }
}
