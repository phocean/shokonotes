import Foundation

/// Canned first-launch library. Lives in Application Support, never in a
/// folder the user picked. Sidecars travel with the tree (`.shokonotes`).
enum SampleLibrary {
    static let directoryName = "Sample Library"
    static let bundleFolderName = "SampleLibrary"

    /// Folder name under `SampleLibrary/` for a preferred localization.
    /// Unknown languages fall back to English.
    static func localeCode(from preferredLocalization: String) -> String {
        let tag = preferredLocalization.lowercased().replacingOccurrences(of: "_", with: "-")
        if tag.hasPrefix("zh-hans") || tag.hasPrefix("zh-cn") || tag == "zh" { return "zh-Hans" }
        if tag.hasPrefix("pt") { return "pt-BR" }
        if tag.hasPrefix("fr") { return "fr" }
        if tag.hasPrefix("de") { return "de" }
        if tag.hasPrefix("es") { return "es" }
        if tag.hasPrefix("it") { return "it" }
        if tag.hasPrefix("ja") { return "ja" }
        if tag.hasPrefix("ko") { return "ko" }
        if tag.hasPrefix("ru") { return "ru" }
        return "en"
    }

    static func defaultDestinationURL(
        locale: String = "en",
        fileManager: FileManager = .default
    ) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Shokonotes", isDirectory: true)
            .appendingPathComponent("\(directoryName)-\(locale)", isDirectory: true)
    }

    static func containsNotes(at url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == LibraryPaths.sidecarFolderName {
                enumerator.skipDescendants()
                continue
            }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                continue
            }
            if LibraryStore.isNoteFile(item) { return true }
        }
        return false
    }

    /// `copyItem` refuses an existing destination, so an empty leftover is replaced.
    static func copy(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        try decodeNames(in: destination, fileManager: fileManager)
        try installSharedImages(from: source, into: destination, fileManager: fileManager)
    }

    /// The bundle stores every non-ASCII file and folder name percent-encoded
    /// (`%EB%A9%94%EB%AA%A8.md` for `메모.md`). App Store Connect rejects a Mac
    /// package whose paths mix Unicode normalization forms, and Xcode's resource
    /// copy writes folder names decomposed while leaving file names composed.
    /// ASCII in the bundle sidesteps it; the user's copy gets the real names.
    /// Deepest paths first, so a folder is renamed after its contents.
    private static func decodeNames(in root: URL, fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        let items = enumerator.compactMap { $0 as? URL }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for item in items {
            let name = item.lastPathComponent
            guard name.contains("%"), let decoded = name.removingPercentEncoding, decoded != name else {
                continue
            }
            try fileManager.moveItem(at: item, to: item.deletingLastPathComponent().appendingPathComponent(decoded))
        }
    }

    /// Preview images live once under `SampleLibrary/_shared`, not in every locale tree.
    private static func installSharedImages(
        from source: URL,
        into destination: URL,
        fileManager: FileManager
    ) throws {
        let shared = source.deletingLastPathComponent().appendingPathComponent("_shared", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        while let item = enumerator.nextObject() as? URL {
            guard LibraryStore.isNoteFile(item),
                  let text = try? String(contentsOf: item, encoding: .utf8) else { continue }
            for name in referencedImageNames(in: text) {
                let destImage = item.deletingLastPathComponent().appendingPathComponent(name)
                if fileManager.fileExists(atPath: destImage.path) { continue }
                let srcImage = shared.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: srcImage.path) else { continue }
                try fileManager.copyItem(at: srcImage, to: destImage)
            }
        }
    }

    private static func referencedImageNames(in markdown: String) -> [String] {
        let pattern = #"\(([^/)]+\.(?:png|jpe?g|gif|webp))\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: markdown) else { return nil }
            return String(markdown[r])
        }
    }
}
