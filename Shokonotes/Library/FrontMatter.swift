import Foundation

/// YAML front matter the library is allowed to write: `title`, `tags`, `created`.
/// The Markdown body after the closing `---` is never rewritten by the parser.
struct FrontMatter: Equatable {
    var title: String?
    var tags: [String] = []
    var created: String?
    /// YAML lines that are not title / tags / created. Kept verbatim on rewrite.
    var extraLines: [String] = []

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    func rendered() -> String {
        let titleLine = "title: \(FrontMatter.quote(title ?? ""))"
        let tagsLine: String
        if tags.isEmpty {
            tagsLine = "tags: []"
        } else {
            tagsLine = "tags: [" + tags.map { FrontMatter.quote($0) }.joined(separator: ", ") + "]"
        }
        let createdLine = "created: \(created ?? FrontMatter.today())"
        var lines = ["---", titleLine, tagsLine, createdLine]
        for extra in extraLines {
            // Only drop top-level known keys; indented nested maps stay verbatim.
            if !yamlLineIsIndented(extra) {
                let trimmed = extra.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("title:") || trimmed.hasPrefix("tags:") || trimmed.hasPrefix("created:") {
                    continue
                }
            }
            lines.append(extra)
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    static func today() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
    }
}

struct ParsedDocument: Equatable {
    var frontMatter: FrontMatter?
    var body: String
    var raw: String

    var bodyForSearch: String {
        var parts: [String] = []
        if let title = frontMatter?.title { parts.append(title) }
        if let tags = frontMatter?.tags, !tags.isEmpty {
            parts.append(contentsOf: tags)
        }
        parts.append(body)
        return parts.joined(separator: "\n")
    }
}

enum FrontMatterCodec {
    static func parse(_ raw: String) -> ParsedDocument {
        guard let split = splitFence(raw),
              looksLikeYAML(split.yaml),
              let matter = decodeYAML(split.yaml) else {
            return ParsedDocument(frontMatter: nil, body: raw, raw: raw)
        }
        return ParsedDocument(frontMatter: matter, body: split.body, raw: raw)
    }

    /// New-note helper. Prefer `splice` when updating an existing file so the
    /// Markdown body is not reconstructed.
    static func write(frontMatter: FrontMatter, body: String) -> String {
        frontMatter.rendered() + body
    }

    /// YAML fence plus `body`. No H1 is inserted. `body` is copied unchanged;
    /// pass `"\n"` for an empty new note.
    static func newNote(title: String, body: String = "\n") -> String {
        write(
            frontMatter: FrontMatter(title: title, tags: [], created: FrontMatter.today()),
            body: body
        )
    }

    static func withTitle(_ raw: String, title: String) -> String {
        var matter = parse(raw).frontMatter ?? FrontMatter(title: title, tags: [], created: FrontMatter.today())
        matter.title = title
        return splice(raw: raw, matter: matter)
    }

    static func withTags(_ raw: String, tags: [String]) -> String {
        let parsed = parse(raw)
        var matter = parsed.frontMatter ?? FrontMatter(
            title: inferredTitle(from: parsed),
            tags: [],
            created: FrontMatter.today()
        )
        matter.tags = uniqueTags(tags)
        return splice(raw: raw, matter: matter)
    }

    /// Replaces only the YAML fence. The body substring of `raw` is copied
    /// unchanged (including CRLF).
    static func splice(raw: String, matter: FrontMatter) -> String {
        let yaml = matter.rendered()
        if let split = splitFence(raw), looksLikeYAML(split.yaml) {
            return yaml + split.body
        }
        return yaml + raw
    }

    /// YAML text (LF-normalized for the parser) and the exact body after the fence.
    ///
    /// Scans Unicode scalars, not Swift `Character`s: CRLF is one grapheme cluster,
    /// so `firstIndex(of: "\n")` misses every Windows line ending.
    static func splitFence(_ raw: String) -> (yaml: String, body: String)? {
        let scalars = raw.unicodeScalars
        var index = scalars.startIndex
        guard consumeFence(scalars, at: &index) else { return nil }
        let yamlStart = index

        while index < scalars.endIndex {
            var probe = index
            if consumeFence(scalars, at: &probe) {
                let yaml = normalizeNewlines(String(String.UnicodeScalarView(scalars[yamlStart..<index])))
                let body = String(String.UnicodeScalarView(scalars[probe...]))
                return (yaml, body)
            }
            guard let next = advanceLine(scalars, from: index) else { return nil }
            index = next
        }
        return nil
    }

    /// `---` at column 0, optional trailing space/tab, then a line ending or EOF.
    /// `--- not a fence` is rejected; `--- ` is a valid fence.
    private static func consumeFence(
        _ scalars: String.UnicodeScalarView,
        at index: inout String.UnicodeScalarView.Index
    ) -> Bool {
        var cursor = index
        for _ in 0..<3 {
            guard cursor < scalars.endIndex, scalars[cursor] == "-" else { return false }
            cursor = scalars.index(after: cursor)
        }
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if scalar == " " || scalar == "\t" {
                cursor = scalars.index(after: cursor)
                continue
            }
            break
        }
        if cursor == scalars.endIndex {
            index = cursor
            return true
        }
        guard let after = consumeLineEnding(scalars, at: cursor) else { return false }
        index = after
        return true
    }

    private static func consumeLineEnding(
        _ scalars: String.UnicodeScalarView,
        at index: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index? {
        guard index < scalars.endIndex else { return nil }
        if scalars[index] == "\r" {
            let next = scalars.index(after: index)
            if next < scalars.endIndex, scalars[next] == "\n" {
                return scalars.index(after: next)
            }
            return next
        }
        if scalars[index] == "\n" {
            return scalars.index(after: index)
        }
        return nil
    }

    private static func advanceLine(
        _ scalars: String.UnicodeScalarView,
        from index: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index? {
        var cursor = index
        while cursor < scalars.endIndex {
            if let after = consumeLineEnding(scalars, at: cursor) { return after }
            cursor = scalars.index(after: cursor)
        }
        return nil
    }

    private static func normalizeNewlines(_ string: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = string.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index] == "\r" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    index = scalars.index(after: next)
                } else {
                    index = next
                }
                output.append("\n")
                continue
            }
            output.append(scalars[index])
            index = scalars.index(after: index)
        }
        return String(output)
    }

    static func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            if seen.insert(key).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    private static func inferredTitle(from parsed: ParsedDocument) -> String {
        if let title = parsed.frontMatter?.title, !title.isEmpty { return title }
        for line in parsed.body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                return trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
        return ""
    }

    private static func looksLikeYAML(_ yaml: String) -> Bool {
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("-") { continue }
            if scalar(named: "title", in: trimmed) != nil { return true }
            if scalar(named: "tags", in: trimmed) != nil || trimmed == "tags:" { return true }
            if scalar(named: "created", in: trimmed) != nil { return true }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon])
                if !key.isEmpty, !key.contains(" "), key.rangeOfCharacter(from: .letters) != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func decodeYAML(_ yaml: String) -> FrontMatter? {
        guard looksLikeYAML(yaml) else { return nil }
        var matter = FrontMatter()
        let lines = yaml.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if yamlLineIsIndented(line) {
                matter.extraLines.append(line)
                index += 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "tags:" || trimmed.hasPrefix("tags:") {
                let (tags, consumed) = parseTags(lines: lines, start: index)
                matter.tags = uniqueTags(tags)
                index += consumed
                continue
            }

            if let value = scalar(named: "title", in: trimmed) {
                matter.title = unquote(value)
                index += 1
                continue
            }
            if let value = scalar(named: "created", in: trimmed) {
                matter.created = unquote(value)
                index += 1
                continue
            }

            matter.extraLines.append(line)
            index += 1
        }
        return matter
    }

    private static func parseTags(lines: [String], start: Int) -> ([String], Int) {
        let header = lines[start].trimmingCharacters(in: .whitespaces)
        if let inline = scalar(named: "tags", in: header) {
            let inner = inline.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            if inner.isEmpty { return ([], 1) }
            let parts = splitCommaList(inner).map(unquote)
            return (parts, 1)
        }

        var tags: [String] = []
        var consumed = 1
        var index = start + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                tags.append(unquote(String(trimmed.dropFirst(2))))
                consumed += 1
                index += 1
            } else if trimmed == "-" {
                consumed += 1
                index += 1
            } else {
                break
            }
        }
        return (tags, consumed)
    }

    private static func scalar(named key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return stripUnquotedInlineComment(rest)
    }

    /// Drops an unquoted `#` comment that sits after a scalar, so
    /// `title: "Hello" # keep` unquotes as `Hello`. A `#` inside quotes stays.
    private static func stripUnquotedInlineComment(_ raw: String) -> String {
        var inDouble = false
        var inSingle = false
        var escape = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            let next = raw.index(after: index)
            if inDouble {
                if escape {
                    escape = false
                } else if character == "\\" {
                    escape = true
                } else if character == "\"" {
                    inDouble = false
                }
            } else if inSingle {
                if character == "'" {
                    if next < raw.endIndex, raw[next] == "'" {
                        index = next
                    } else {
                        inSingle = false
                    }
                }
            } else if character == "\"" {
                inDouble = true
            } else if character == "'" {
                inSingle = true
            } else if character == "#" {
                let atStart = index == raw.startIndex
                let precededBySpace = !atStart && raw[raw.index(before: index)].isWhitespace
                if atStart || precededBySpace {
                    return String(raw[..<index]).trimmingCharacters(in: .whitespaces)
                }
            }
            index = next
        }
        return raw
    }

    private static func splitCommaList(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        var escape = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            let next = raw.index(after: index)
            if inDouble {
                if escape {
                    current.append(character)
                    escape = false
                    index = next
                    continue
                }
                if character == "\\" {
                    escape = true
                    index = next
                    continue
                }
                if character == "\"" {
                    inDouble = false
                }
                current.append(character)
                index = next
                continue
            }
            if inSingle {
                if character == "'" {
                    if next < raw.endIndex, raw[next] == "'" {
                        current.append("'")
                        current.append("'")
                        index = raw.index(after: next)
                        continue
                    }
                    inSingle = false
                }
                current.append(character)
                index = next
                continue
            }
            if escape {
                current.append(character)
                escape = false
                index = next
                continue
            }
            if character == "\\" {
                escape = true
                index = next
                continue
            }
            if character == "\"" {
                inDouble = true
                current.append(character)
                index = next
                continue
            }
            if character == "'" {
                inSingle = true
                current.append(character)
                index = next
                continue
            }
            if character == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = next
                continue
            }
            current.append(character)
            index = next
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }
}

/// Nested YAML maps are indented with space or tab; those lines are not note metadata.
private func yamlLineIsIndented(_ line: String) -> Bool {
    guard let first = line.unicodeScalars.first else { return false }
    return first == " " || first == "\t"
}

enum NoteExcerpt {
    static func make(from body: String, limit: Int = 180) -> String {
        let lines = body.components(separatedBy: "\n")
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                trimmed = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.isEmpty { continue }
            if trimmed.count <= limit { return trimmed }
            let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
            return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return ""
    }

    static func title(from parsed: ParsedDocument, fileName: String, useFirstLine: Bool = true) -> String {
        if let title = parsed.frontMatter?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if !useFirstLine { return fileName }
        for line in parsed.body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return heading }
                continue
            }
            return trimmed
        }
        return fileName
    }
}

enum FilenameSanitizer {
    /// Character cap, unchanged: an ASCII title stays readable at 150 glyphs.
    static let maxCharacters = 150

    /// UTF-8 byte cap for the *stem*. Measured 2026-09-18: APFS does **not**
    /// enforce 255 UTF-8 bytes — a 252-ideogram name (756 bytes) writes fine,
    /// while 400 UTF-16 units of flag emoji fail with ENAMETOOLONG. The
    /// enforced local limit is ~255 UTF-16 units. A byte cap is kept anyway
    /// for two reasons: it subsumes the UTF-16 limit (200 UTF-8 bytes can
    /// never exceed 200 UTF-16 units), and the library folder is routinely
    /// synced to SMB, NFS or Linux-backed storage — Nextcloud, Syncthing —
    /// where 255 *bytes* really is the limit.
    /// What lands on disk is stem + uniqueness suffix + extension:
    ///   - ` 999` from `uniqueName`, or ` ` + 8 UUID characters = 9 bytes
    ///     worst case;
    ///   - `.md` = 3 bytes, or a longer export extension (`.html` = 5).
    /// 200 + 9 + 5 = 214, leaving ~40 bytes of slack for a longer suffix a
    /// future caller might append. A CJK glyph is 3 bytes, so 200 bytes is
    /// about 66 ideograms, against 150 glyphs for an ASCII title. That
    /// asymmetry is deliberate: 66 ideograms is already a long Japanese
    /// sentence, and the alternative is a name that breaks the day the
    /// folder syncs to a Linux host.
    static let maxUTF8Bytes = 200

    static func sanitize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\0", with: "")
        while value.hasPrefix(".") {
            value.removeFirst()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "Untitled Note" }
        value = truncate(value)
        // Truncation can expose trailing whitespace that was in the middle of
        // the title; it must not end up in the file name.
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "Untitled Note" }
        return value
    }

    /// Cuts `value` to whichever cap it hits first — 150 `Character`s or 200
    /// UTF-8 bytes — always on a grapheme-cluster boundary, so a composed
    /// emoji or a flag is kept whole or dropped whole, never split.
    static func truncate(_ value: String) -> String {
        var result = value
        if result.count > maxCharacters {
            result = String(result.prefix(maxCharacters))
        }
        guard result.utf8.count > maxUTF8Bytes else { return result }
        var bytes = 0
        var cut = result.startIndex
        for character in result {
            let width = String(character).utf8.count
            if bytes + width > maxUTF8Bytes { break }
            bytes += width
            cut = result.index(after: cut)
        }
        return String(result[..<cut])
    }

    static func uniqueName(base: String, ext: String, in directory: URL, excluding: URL? = nil) -> String {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
            if url.standardizedFileURL == excluding?.standardizedFileURL { return false }
            return fm.fileExists(atPath: url.path)
        }
        if !exists(base) { return base }
        for index in 2...999 {
            let candidate = "\(base) \(index)"
            if !exists(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8))"
    }
}
