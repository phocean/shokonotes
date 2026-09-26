import Foundation

struct NoteSnapshot: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let title: String
    let excerpt: String
    let tags: [String]
    let modifiedAt: Date
    let createdAt: Date
    let isPinned: Bool
    let folderURL: URL
    let relativePath: String
    let isTrashed: Bool
    /// The Markdown body as it sits in the file, front matter removed. The
    /// preview renders this instead of re-reading the note from disk.
    let rawBody: String
    /// Title + tags + body, case- and diacritic-folded once at indexing time.
    /// Search compares folded terms against it; never shown to the user.
    let searchHaystack: String
    /// Precomputed: `NoteRow` asks for it on every row of every render.
    let fileStemDiffersFromTitle: Bool

    var tagLine: String {
        tags.map { "#" + $0 }.joined(separator: " ")
    }

    /// Folder path relative to the library root, or nil when the note sits at the root.
    var folderPathLabel: String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." { return nil }
        return parent
    }

    var fileName: String {
        url.deletingPathExtension().lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension
    }

    /// True when the file stem is not the sanitized display title. Same rule as
    /// before, evaluated once per indexing instead of once per row per render.
    static func stemDiffersFromTitle(url: URL, title: String) -> Bool {
        let stem = FilenameSanitizer.sanitize(title)
        if stem.isEmpty { return true }
        return url.deletingPathExtension().lastPathComponent
            .localizedStandardCompare(stem) != .orderedSame
    }

    /// The one folding rule, used both when indexing and when searching.
    /// Half-width katakana must find full-width and back (ﾊﾞﾅﾅ / バナナ,
    /// ＡＢＣ / ABC). `.widthInsensitive` alone does not do it: it widens ﾊ to
    /// ハ but leaves the half-width voiced mark U+FF9E standing on its own, so
    /// `ﾊﾞﾅﾅ` folded to `ハﾞナナ` and never matched `バナナ`. Compatibility
    /// normalization (NFKC) composes the pair first; the width option then
    /// costs nothing and documents the intent. The folded text is only ever
    /// compared, never displayed, so no width is lost to the user.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                locale: .current
            )
    }

    static func haystack(title: String, tags: [String], body: String) -> String {
        fold(title + "\n" + tags.joined(separator: " ") + "\n" + body)
    }

    func matches(terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        return matches(foldedTerms: terms.map(Self.fold))
    }

    /// Hot path: the caller folds each term once for the whole library rather
    /// than once per note per term.
    func matches(foldedTerms: [String]) -> Bool {
        guard !foldedTerms.isEmpty else { return true }
        return foldedTerms.allSatisfy { searchHaystack.contains($0) }
    }
}

struct FolderSnapshot: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let parentURL: URL?
    var children: [FolderSnapshot]?
    /// SF Symbol name. Nil means the default `folder` glyph.
    let symbol: String?

    init(
        url: URL,
        name: String,
        parentURL: URL?,
        children: [FolderSnapshot]? = nil,
        symbol: String? = nil
    ) {
        self.url = url
        self.name = name
        self.parentURL = parentURL
        self.children = children
        self.symbol = symbol
    }

    var hasChildren: Bool { children?.isEmpty == false }

    var nestedLabel: String {
        name
    }
}

enum LibraryPaths {
    static let trashFolderName = "Trash"
    static let sidecarFolderName = ".shokonotes"
    static let pinsFileName = "pins.json"
    static let folderSymbolsFileName = "folderSymbols.json"
    static let favouritesFileName = "favourites.json"
    static let originsFileName = "origins.json"

    static func trashURL(root: URL) -> URL {
        root.appendingPathComponent(trashFolderName, isDirectory: true)
    }

    static func sidecarURL(root: URL) -> URL {
        root.appendingPathComponent(sidecarFolderName, isDirectory: true)
    }

    static func pinsURL(root: URL) -> URL {
        sidecarURL(root: root).appendingPathComponent(pinsFileName)
    }

    static func folderSymbolsURL(root: URL) -> URL {
        sidecarURL(root: root).appendingPathComponent(folderSymbolsFileName)
    }

    static func favouritesURL(root: URL) -> URL {
        sidecarURL(root: root).appendingPathComponent(favouritesFileName)
    }

    static func originsURL(root: URL) -> URL {
        trashURL(root: root).appendingPathComponent(originsFileName)
    }

    static func isReservedFolderName(_ name: String) -> Bool {
        name == trashFolderName || name == sidecarFolderName
    }

    static let defaultAttachmentFolderPatterns = ["i", "*.assets"]

    /// User-configured names omitted from the sidebar. `*.suffix` matches a
    /// trailing substring; anything else is an exact name (case-insensitive).
    static func isAttachmentFolderName(_ name: String, patterns: [String]) -> Bool {
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            if pattern.hasPrefix("*") {
                let suffix = String(pattern.dropFirst())
                guard !suffix.isEmpty,
                      name.lowercased().hasSuffix(suffix.lowercased()) else { continue }
                return true
            }
            if name.compare(pattern, options: .caseInsensitive) == .orderedSame {
                return true
            }
        }
        return false
    }

    static func relativePath(of url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    static func isInsideTrash(_ url: URL, root: URL) -> Bool {
        isInside(url, folder: trashURL(root: root))
    }

    static func isInside(_ url: URL, folder: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == folderPath || path.hasPrefix(folderPath + "/")
    }

    /// Rewrites a URL that lives inside `oldFolder` so it points at the same
    /// item under `newFolder`. Nil when the URL is outside. Directory
    /// boundary, so `Work2` is never caught by a move of `Work`.
    static func retargeted(_ url: URL, from oldFolder: URL, to newFolder: URL) -> URL? {
        let old = oldFolder.standardizedFileURL
        let standardized = url.standardizedFileURL
        guard isInside(standardized, folder: old) else { return nil }
        let suffix = String(standardized.path.dropFirst(old.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let new = newFolder.standardizedFileURL
        if suffix.isEmpty { return new }
        return new.appendingPathComponent(suffix).standardizedFileURL
    }

    /// True when `path` is `prefix` or a descendant. Directory boundary
    /// (`prefix/`), so `Work2` is never inside `Work`.
    static func isRelativePath(_ path: String, under prefix: String) -> Bool {
        path == prefix || (!prefix.isEmpty && path.hasPrefix(prefix + "/"))
    }

    /// Rewrites a library-relative path that lives inside `oldPrefix` so it
    /// points at the same item under `newPrefix`. Nil when outside.
    static func remappedRelativePath(_ path: String, from oldPrefix: String, to newPrefix: String) -> String? {
        guard isRelativePath(path, under: oldPrefix) else { return nil }
        if path == oldPrefix { return newPrefix }
        let oldDir = oldPrefix + "/"
        let newDir = newPrefix.isEmpty ? "" : newPrefix + "/"
        let suffix = String(path.dropFirst(oldDir.count))
        return suffix.isEmpty ? newPrefix : newDir + suffix
    }
}

struct PinFile: Codable {
    var paths: [String]
}

/// Relative folder path → SF Symbol name. Missing key means the default glyph.
struct FolderSymbolFile: Codable {
    var symbols: [String: String]
}

/// A sidebar shortcut: a folder (library-relative path), a note (library-relative
/// file path, the same string pins use), or a tag (exact name). Encoded with an
/// explicit key, never a string prefix. Not a pin: a note may be both.
enum Favourite: Hashable, Codable, Equatable {
    case folder(String)
    /// Library-relative file path (`LibraryPaths.relativePath` of the note URL).
    case note(String)
    /// Tag name. There is no tag-rename in v1; a future rename must retarget this list.
    case tag(String)

    enum CodingKeys: String, CodingKey {
        case folder, note, tag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .folder) {
            self = .folder(path)
        } else if let path = try container.decodeIfPresent(String.self, forKey: .note) {
            self = .note(path)
        } else if let name = try container.decodeIfPresent(String.self, forKey: .tag) {
            self = .tag(name)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Favourite needs a folder, note or tag key."
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let path):
            try container.encode(path, forKey: .folder)
        case .note(let path):
            try container.encode(path, forKey: .note)
        case .tag(let name):
            try container.encode(name, forKey: .tag)
        }
    }

    /// Folder → last path component; note → file stem; tag → the name.
    /// Unranked order uses the live title for a note when a record exists.
    var displayName: String {
        switch self {
        case .folder(let path):
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        case .note(let path):
            let file = (path as NSString).lastPathComponent
            let stem = (file as NSString).deletingPathExtension
            return stem.isEmpty ? (file.isEmpty ? path : file) : stem
        case .tag(let name):
            return name
        }
    }
}

struct FavouriteFile: Codable, Equatable {
    /// When true, `items` order is the rank for the whole list. Never mixed.
    var ranked: Bool
    var items: [Favourite]

    init(ranked: Bool, items: [Favourite]) {
        self.ranked = ranked
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ranked = try container.decodeIfPresent(Bool.self, forKey: .ranked) ?? false
        items = try container.decodeIfPresent([Favourite].self, forKey: .items) ?? []
    }
}

struct OriginRecord: Codable, Equatable {
    var folder: String
    var fileName: String
}

struct OriginFile: Codable {
    /// Path relative to the Trash directory → original folder and file name.
    /// A file at the Trash root is keyed by its file name (`Note.md`), so older
    /// `origins.json` files still decode. Nested leftovers use `Folder/Note.md`.
    var items: [String: OriginRecord]
    /// Trash leftover-folder name → original relative folder path (`OriginRecord.folder`).
    /// Optional so older `origins.json` files still decode.
    var folderResidue: [String: String]?
}
