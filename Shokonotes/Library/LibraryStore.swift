import Foundation

/// What a `stat` says about a note file. Both halves are needed: an editor
/// that rewrites a file in place can leave the size identical, and a copy can
/// land with the same size under a new date.
struct FileStamp: Equatable {
    var modified: Date
    var size: Int
}

struct NoteRecord: Equatable {
    var url: URL
    var title: String
    var excerpt: String
    var tags: [String]
    var modifiedAt: Date
    var createdAt: Date
    /// Markdown body, front matter removed. What the preview renders.
    var rawBody: String
    /// Title + tags + body, folded once for search.
    var searchHaystack: String
    var relativePath: String
    var isTrashed: Bool
    var folderURL: URL
    /// The stamp this record was read from. `rescan` reuses the record when the
    /// file still carries it. Nil when the file system did not answer, which
    /// makes the next pass read the file again.
    var stamp: FileStamp?
}

/// Disk-backed library. Not observable; `LibraryModel` publishes snapshots.
@MainActor
final class LibraryStore {
    private(set) var root: URL?
    private(set) var records: [URL: NoteRecord] = [:] {
        didSet {
            cachedCounts = nil
            cachedTagCounts = nil
        }
    }
    private var cachedCounts: SidebarCounts?
    private var cachedTagCounts: [TagCount]?
    private var pinned: Set<String> = []
    /// Relative folder path → SF Symbol name. Missing key is the default glyph.
    private var folderSymbols: [String: String] = [:]
    private var favouriteItems: [Favourite] = []
    /// When true, `favouriteItems` order is the rank for the whole list.
    private var favouritesRanked = false
    private var origins: [String: OriginRecord] = [:]
    /// Trash leftover-folder name → original relative folder path.
    private var folderResidue: [String: String] = [:]

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var notes: [NoteRecord] { Array(records.values) }

    /// The three sidebar badges. Computed in a single pass and memoized, since
    /// the view reads them several times per render and they only change when
    /// `records` does.
    struct SidebarCounts: Equatable {
        var trashed = 0
        var inbox = 0
        var untagged = 0
    }

    func counts() -> SidebarCounts {
        if let cachedCounts { return cachedCounts }
        var result = SidebarCounts()
        let inboxFolder = root?.standardizedFileURL
        for record in records.values {
            if record.isTrashed {
                result.trashed += 1
                continue
            }
            if record.tags.isEmpty { result.untagged += 1 }
            if let inboxFolder, record.folderURL.standardizedFileURL == inboxFolder {
                result.inbox += 1
            }
        }
        cachedCounts = result
        return result
    }

    func setRoot(_ url: URL?) {
        root = url?.standardizedFileURL
        records = [:]
        pinned = []
        folderSymbols = [:]
        favouriteItems = []
        favouritesRanked = false
        origins = [:]
        folderResidue = [:]
        if let root {
            ensureDirectory(LibraryPaths.trashURL(root: root))
            // `rescan` loads the sidecars itself; reading them twice at launch
            // bought nothing.
            rescan()
        }
    }

    /// Incremental. The pass still enumerates every file, so a note that was
    /// deleted, moved or renamed is gone from `next` exactly as before — a
    /// record survives only when the very same URL comes back carrying the
    /// stamp it was read from. Anything else is read in full. A pass in which
    /// nothing changed is therefore a run of `stat`s and no file read at all,
    /// which is what `reloadFromDisk` does every 15 seconds on the phone.
    func rescan() {
        guard let root else {
            records = [:]
            return
        }
        loadSidecars()
        // Settings that change how a file is *interpreted* (the title rule, the
        // attachment patterns, conflict resolution) make a cached record wrong
        // even though the file did not move. One changed setting costs one full
        // pass, and only one.
        let signature = interpretationSignature
        let mayReuse = signature == lastInterpretationSignature
        let previous = records
        var next: [URL: NoteRecord] = [:]
        var reused = 0
        enumerateNotes(from: root) { url, stamp in
            let key = url.standardizedFileURL
            if mayReuse, let stamp,
               let existing = previous[key], existing.stamp == stamp {
                next[key] = existing
                reused += 1
                return
            }
            if let record = readRecord(url: url, root: root) {
                next[record.url] = record
            }
        }
        records = next
        lastInterpretationSignature = signature
        reusedRecordCount = reused
        if let settings = optionalResolveConflicts(), settings {
            resolveNumberedCopies()
        }
        pruneFavourites()
    }

    /// How many records the last `rescan` reused instead of reading. A test
    /// proves an idle pass reads nothing.
    private(set) var reusedRecordCount = 0

    private var lastInterpretationSignature: String?

    /// Everything outside the file's own bytes that changes the record read
    /// from it. Adding a setting that alters interpretation means adding it here.
    private var interpretationSignature: String {
        "\(useFirstLineAsTitle)|\(conflictResolutionEnabled)|\(attachmentFolderPatterns.joined(separator: "\u{1}"))"
    }

    /// Used by tests to force conflict handling without AppSettings.shared.
    var conflictResolutionEnabled = false
    var useFirstLineAsTitle = true
    var attachmentFolderPatterns: [String] = LibraryPaths.defaultAttachmentFolderPatterns

    private func optionalResolveConflicts() -> Bool? {
        conflictResolutionEnabled
    }

    func snapshot(for url: URL) -> NoteSnapshot? {
        guard let record = records[url.standardizedFileURL] else { return nil }
        return makeSnapshot(record)
    }

    /// Snapshot for a library-relative path, trash included. Nil when no record matches.
    func snapshot(relativePath: String) -> NoteSnapshot? {
        guard let record = records.values.first(where: { $0.relativePath == relativePath }) else {
            return nil
        }
        return makeSnapshot(record)
    }

    func snapshots() -> [NoteSnapshot] {
        records.values.map(makeSnapshot)
    }

    func folders() -> [FolderSnapshot] {
        guard let root else { return [] }
        var childrenByParent: [URL: [URL]] = [:]
        var names: [URL: String] = [:]

        enumerateDirectories(from: root) { url in
            let parent = url.deletingLastPathComponent().standardizedFileURL
            childrenByParent[parent, default: []].append(url)
            names[url] = url.lastPathComponent
        }

        func build(_ url: URL) -> FolderSnapshot {
            let kids = (childrenByParent[url] ?? []).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            let key = LibraryPaths.relativePath(of: url, to: root)
            return FolderSnapshot(
                url: url,
                name: names[url] ?? url.lastPathComponent,
                parentURL: url.deletingLastPathComponent(),
                children: kids.isEmpty ? nil : kids.map(build),
                symbol: folderSymbols[key]
            )
        }

        let roots = (childrenByParent[root] ?? []).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return roots.map(build)
    }

    /// A tag and how many notes carry it. The count follows what clicking the
    /// tag shows, so trashed notes are not counted. A tag at 1 states a fact
    /// and the app draws no conclusion from it.
    struct TagCount: Hashable, Sendable, Identifiable {
        var id: String { name }
        let name: String
        let count: Int
    }

    /// Every tag in the library, alphabetical. Names come from every record,
    /// trash included.
    func tags() -> [String] {
        tagCounts().map(\.name)
    }

    /// Same list, with the per-note count. One pass over the records, memoized
    /// beside `counts()` and invalidated by the same `records` write, so
    /// asking for it on every render costs nothing.
    func tagCounts() -> [TagCount] {
        if let cachedTagCounts { return cachedTagCounts }
        var counts: [String: Int] = [:]
        for record in records.values {
            for tag in Set(record.tags) {
                counts[tag, default: 0] += record.isTrashed ? 0 : 1
            }
        }
        let result = counts
            .map { TagCount(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cachedTagCounts = result
        return result
    }

    // MARK: - Notes

    @discardableResult
    func createNote(named rawName: String, in folder: URL, extension ext: String, body: String) throws -> NoteRecord {
        guard let root else { throw LibraryError.noRoot }
        let name = FilenameSanitizer.sanitize(rawName)
        let unique = FilenameSanitizer.uniqueName(base: name, ext: ext, in: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(unique).appendingPathExtension(ext)
        try body.write(to: url, atomically: true, encoding: .utf8)
        guard let record = readRecord(url: url, root: root) else { throw LibraryError.renameFailed }
        records[record.url] = record
        return record
    }

    func rename(_ url: URL, to rawName: String, updateYAMLTitle: Bool) throws -> NoteRecord {
        guard let root, let record = records[url.standardizedFileURL] else { throw LibraryError.noRoot }
        let name = FilenameSanitizer.sanitize(rawName)
        guard !name.isEmpty else { throw LibraryError.invalidName }
        let folder = record.folderURL
        let ext = record.url.pathExtension
        let unique = FilenameSanitizer.uniqueName(base: name, ext: ext, in: folder, excluding: record.url)
        let destination = folder.appendingPathComponent(unique).appendingPathExtension(ext)
        if destination.standardizedFileURL != record.url.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                throw LibraryError.nameExists(unique)
            }
            try moveFile(record.url, to: destination)
        }
        if updateYAMLTitle, let text = try? String(contentsOf: destination, encoding: .utf8) {
            let rewritten = FrontMatterCodec.withTitle(text, title: name)
            try rewritten.write(to: destination, atomically: true, encoding: .utf8)
        }
        let newPath = LibraryPaths.relativePath(of: destination, to: root)
        retargetPin(from: record.relativePath, to: newPath)
        let remappedFavourite = retargetFavouriteNote(from: record.relativePath, to: newPath)
        if record.isTrashed {
            let newKey = originKey(for: destination)
            if let origin = takeOrigin(for: record.url) {
                origins[newKey] = origin
            }
            try persistOrigins()
        }
        try persistPins()
        if remappedFavourite { try persistFavourites() }
        records.removeValue(forKey: record.url)
        guard let updated = readRecord(url: destination, root: root) else { throw LibraryError.renameFailed }
        records[updated.url] = updated
        return updated
    }

    func move(_ urls: [URL], to folder: URL) throws {
        guard let root else { throw LibraryError.noRoot }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var remappedFavourites = false
        for url in urls {
            guard let record = records[url.standardizedFileURL] else { continue }
            if record.folderURL.standardizedFileURL == folder.standardizedFileURL { continue }
            let destination = uniqueDestination(for: record.url, in: folder)
            try moveFile(record.url, to: destination)
            let newPath = LibraryPaths.relativePath(of: destination, to: root)
            retargetPin(from: record.relativePath, to: newPath)
            remappedFavourites = retargetFavouriteNote(from: record.relativePath, to: newPath) || remappedFavourites
            records.removeValue(forKey: record.url)
            if let updated = readRecord(url: destination, root: root) {
                records[updated.url] = updated
            }
        }
        try persistPins()
        if remappedFavourites { try persistFavourites() }
    }

    func trash(_ urls: [URL]) throws {
        guard let root else { throw LibraryError.noRoot }
        let trash = LibraryPaths.trashURL(root: root)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        var remappedFavourites = false
        do {
            for url in urls {
                guard let record = records[url.standardizedFileURL], !record.isTrashed else { continue }
                let destination = uniqueDestination(for: record.url, in: trash)
                origins[originKey(for: destination)] = OriginRecord(
                    folder: LibraryPaths.relativePath(of: record.folderURL, to: root),
                    fileName: record.url.lastPathComponent
                )
                try moveFile(record.url, to: destination)
                let newPath = LibraryPaths.relativePath(of: destination, to: root)
                retargetPin(from: record.relativePath, to: newPath)
                remappedFavourites = retargetFavouriteNote(from: record.relativePath, to: newPath) || remappedFavourites
                records.removeValue(forKey: record.url)
                if let updated = readRecord(url: destination, root: root) {
                    records[updated.url] = updated
                }
            }
        } catch {
            // The loop only mutated memory, and memory already matches the files
            // that really moved. One best-effort write puts that state on disk,
            // then the original error wins.
            persistSidecarsBestEffort()
            throw error
        }
        try persistSidecars()
        if remappedFavourites { try persistFavourites() }
    }

    func restore(_ urls: [URL], fallback folder: URL) throws {
        guard let root else { throw LibraryError.noRoot }
        var remappedFavourites = false
        do {
            for url in urls {
                guard let record = records[url.standardizedFileURL], record.isTrashed else { continue }
                let origin = origin(for: record.url)
                let relative = origin?.folder ?? ""
                let destinationFolder: URL
                if relative.isEmpty {
                    destinationFolder = folder
                } else {
                    destinationFolder = root.appendingPathComponent(relative, isDirectory: true)
                }
                try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                let originalName = origin?.fileName ?? record.url.lastPathComponent
                let destination = uniqueDestination(fileName: originalName, in: destinationFolder)
                try moveFile(record.url, to: destination)
                _ = takeOrigin(for: record.url)
                let newPath = LibraryPaths.relativePath(of: destination, to: root)
                retargetPin(from: record.relativePath, to: newPath)
                remappedFavourites = retargetFavouriteNote(from: record.relativePath, to: newPath) || remappedFavourites
                records.removeValue(forKey: record.url)
                if let updated = readRecord(url: destination, root: root) {
                    records[updated.url] = updated
                }
                reuniteResidue(for: relative, into: destinationFolder, root: root)
            }
        } catch {
            persistSidecarsBestEffort()
            throw error
        }
        try persistSidecars()
        if remappedFavourites { try persistFavourites() }
    }

    func removeForever(_ urls: [URL]) throws {
        do {
            for url in urls {
                let key = url.standardizedFileURL
                if let record = records[key] {
                    try unlinkIfPresent(record.url)
                    pinned.remove(record.relativePath)
                    _ = takeOrigin(for: record.url)
                    records.removeValue(forKey: key)
                } else if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
            try pruneOrphanedResidue()
        } catch {
            persistSidecarsBestEffort()
            throw error
        }
        try persistSidecars()
        // Emptying the Trash is what makes a deleted folder unrecoverable, so
        // that is where its symbol is collected — not when it was deleted.
        // Only once the origins on disk agree: a glyph is never collected while
        // `origins.json` still describes a note that could restore into it.
        if pruneFolderSymbols() { persistFolderSymbols() }
        pruneFavourites()
    }

    /// Permanently deletes every trashed note and leftover residue directory.
    func emptyTrash() throws {
        try removeForever(records.values.filter(\.isTrashed).map(\.url))
    }

    func setPinned(_ url: URL, _ isPinned: Bool) throws {
        let previous = pinned
        guard applyPin(url, isPinned) else { return }
        do {
            try persistPins()
        } catch {
            pinned = previous
            throw error
        }
    }

    func togglePin(_ url: URL) throws {
        try togglePins([url])
    }

    /// One JSON encode and one atomic write for the whole selection, instead of
    /// one per note.
    func togglePins(_ urls: [URL]) throws {
        let previous = pinned
        var changed = false
        for url in urls {
            guard let record = records[url.standardizedFileURL] else { continue }
            changed = applyPin(url, !pinned.contains(record.relativePath)) || changed
        }
        guard changed else { return }
        do {
            try persistPins()
        } catch {
            pinned = previous
            throw error
        }
    }

    /// Returns true when the pin set actually changed.
    @discardableResult
    private func applyPin(_ url: URL, _ isPinned: Bool) -> Bool {
        guard let record = records[url.standardizedFileURL] else { return false }
        if isPinned {
            return pinned.insert(record.relativePath).inserted
        }
        return pinned.remove(record.relativePath) != nil
    }

    /// Empty string (after trim) is nil: the default `folder` glyph.
    func setFolderSymbol(_ url: URL, _ name: String?) {
        setFolderSymbols([(url, name)])
    }

    /// One JSON encode and one atomic write for the whole batch.
    func setFolderSymbols(_ updates: [(URL, String?)]) {
        var changed = false
        for (url, name) in updates {
            changed = applyFolderSymbol(url, name) || changed
        }
        if changed { persistFolderSymbols() }
    }

    /// Returns true when the map actually changed.
    @discardableResult
    private func applyFolderSymbol(_ url: URL, _ name: String?) -> Bool {
        guard let root else { return false }
        let folder = url.standardizedFileURL
        guard folder != root else { return false }
        guard LibraryPaths.isInside(folder, folder: root),
              !LibraryPaths.isInsideTrash(folder, root: root) else { return false }
        guard directoryExists(folder) else { return false }
        let key = LibraryPaths.relativePath(of: folder, to: root)
        guard !key.isEmpty else { return false }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        if folderSymbols[key] == value { return false }
        if let value {
            folderSymbols[key] = value
        } else {
            folderSymbols.removeValue(forKey: key)
        }
        return true
    }

    func writeTitle(_ url: URL, title: String) throws {
        guard let root, records[url.standardizedFileURL] != nil else { throw LibraryError.noRoot }
        let text = try String(contentsOf: url, encoding: .utf8)
        let rewritten = FrontMatterCodec.withTitle(text, title: title)
        try rewritten.write(to: url, atomically: true, encoding: .utf8)
        if let updated = readRecord(url: url, root: root) {
            records[updated.url] = updated
        }
    }

    func applyTag(_ tag: String, add: Bool, to urls: [URL]) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let root else { return }
        for url in urls {
            guard var record = records[url.standardizedFileURL], !record.isTrashed else { continue }
            guard let text = try? String(contentsOf: record.url, encoding: .utf8) else { continue }
            var tags = record.tags
            if add {
                if !tags.contains(where: { $0.compare(cleaned, options: .caseInsensitive) == .orderedSame }) {
                    tags.append(cleaned)
                }
            } else {
                tags.removeAll { $0.compare(cleaned, options: .caseInsensitive) == .orderedSame }
            }
            let rewritten = FrontMatterCodec.withTags(text, tags: tags)
            do {
                try rewritten.write(to: record.url, atomically: true, encoding: .utf8)
            } catch {
                continue
            }
            if let updated = readRecord(url: record.url, root: root) {
                records[updated.url] = updated
            }
        }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named rawName: String, parent: URL) throws -> URL {
        let name = FilenameSanitizer.sanitize(rawName)
        guard !LibraryPaths.isReservedFolderName(name) else { throw LibraryError.invalidName }
        var destination = parent.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            for index in 2...999 {
                destination = parent.appendingPathComponent("\(name) \(index)", isDirectory: true)
                if !fileManager.fileExists(atPath: destination.path) { break }
            }
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination.standardizedFileURL
    }

    func renameFolder(_ url: URL, to rawName: String) throws -> URL {
        guard let root else { throw LibraryError.noRoot }
        let name = FilenameSanitizer.sanitize(rawName)
        guard !LibraryPaths.isReservedFolderName(name) else { throw LibraryError.invalidName }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        if destination.standardizedFileURL == url.standardizedFileURL { return url }
        if fileManager.fileExists(atPath: destination.path) { throw LibraryError.nameExists(name) }
        try fileManager.moveItem(at: url, to: destination)
        retargetPins(under: url, to: destination, root: root)
        retargetFolderSymbols(under: url, to: destination, root: root)
        retargetFavourites(under: url, to: destination, root: root)
        retargetOrigins(under: url, to: destination, root: root)
        try persistPins()
        persistFolderSymbols()
        try persistFavourites()
        try persistOrigins()
        rescan()
        return destination.standardizedFileURL
    }

    /// Moves a folder into another folder, or onto the library root. A real
    /// move on disk: notes travel with it, no body and no YAML is touched.
    /// Refusals come back as `FolderMoveError`. Never called from the watcher.
    @discardableResult
    func moveFolder(_ url: URL, into destination: URL) throws -> URL {
        guard let root else { throw LibraryError.noRoot }
        let source = url.standardizedFileURL
        let target = try FolderActions.plannedDestination(
            moving: source, into: destination, fileManager: fileManager
        )
        try fileManager.moveItem(at: source, to: target)
        retargetPins(under: source, to: target, root: root)
        retargetFolderSymbols(under: source, to: target, root: root)
        retargetFavourites(under: source, to: target, root: root)
        retargetOrigins(under: source, to: target, root: root)
        try persistPins()
        persistFolderSymbols()
        try persistFavourites()
        try persistOrigins()
        rescan()
        return target
    }

    func deleteFolder(_ url: URL) throws {
        guard let root else { throw LibraryError.noRoot }
        let notes = records.values.filter {
            LibraryPaths.isInside($0.folderURL, folder: url) && !$0.isTrashed
        }
        try trash(notes.map(\.url))
        // A failed listing is not empty: `?? []` would `removeItem` and destroy
        // hidden files. Hidden leftovers must also keep the folder (no
        // `.skipsHiddenFiles`). `removeItem` only when the directory is gone
        // or truly empty.
        let leftovers: [URL]?
        do {
            leftovers = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            leftovers = nil
        }
        if let leftovers {
            if leftovers.isEmpty {
                try? fileManager.removeItem(at: url)
            } else {
                try trashLeftoverFolder(url, root: root)
            }
        } else if directoryExists(url) {
            try trashLeftoverFolder(url, root: root)
        }
        rescan()
        // The symbol is not dropped here: the notes went to the Trash with
        // their origin, so restoring one recreates this folder and the glyph
        // must come back with it, exactly as the pin does. Only folders that
        // nothing can restore into are collected.
        if pruneFolderSymbols() { persistFolderSymbols() }
        pruneFavourites()
    }

    // MARK: - Favourites

    /// Display order: alphabetical by name when unranked, otherwise the stored rank.
    func favourites() -> [Favourite] {
        displayedFavourites()
    }

    func isFavourite(_ item: Favourite) -> Bool {
        guard let item = Self.normalized(item) else { return false }
        return favouriteItems.contains(item)
    }

    func addFavourite(_ item: Favourite) throws {
        guard root != nil else { throw LibraryError.noRoot }
        guard let item = Self.normalized(item) else { return }
        if favouriteItems.contains(item) { return }
        favouriteItems.append(item)
        if !favouritesRanked {
            favouriteItems = sortedFavourites(favouriteItems)
        }
        try persistFavourites()
    }

    func removeFavourite(_ item: Favourite) throws {
        guard root != nil else { throw LibraryError.noRoot }
        let item = Self.normalized(item) ?? item
        guard let index = favouriteItems.firstIndex(of: item) else { return }
        favouriteItems.remove(at: index)
        if favouriteItems.isEmpty { favouritesRanked = false }
        try persistFavourites()
    }

    /// `toOffset` is the insertion index before the source is removed, same as SwiftUI `onMove`.
    /// The first call seeds rank from the alphabetical order then in force.
    func reorderFavourites(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        guard root != nil else { throw LibraryError.noRoot }
        var items = displayedFavourites()
        guard !items.isEmpty, !source.isEmpty,
              source.allSatisfy({ items.indices.contains($0) }) else { return }
        let dest = min(max(destination, 0), items.count)
        let alreadyRanked = favouritesRanked
        items.move(fromOffsets: source, toOffset: dest)
        if alreadyRanked, items == favouriteItems { return }
        favouritesRanked = true
        favouriteItems = items
        try persistFavourites()
    }

    /// Counts atomic writes of `favourites.json`.
    private(set) var favouriteWriteCount = 0

    /// Drops folder entries nothing can restore, tag entries no record carries,
    /// and note entries gone from records and from disk. Trashed notes stay.
    /// Persists best-effort when the list changed. Returns whether it changed.
    @discardableResult
    func pruneFavourites() -> Bool {
        guard let root, !favouriteItems.isEmpty else { return false }
        // A root that momentarily cannot be read would make every folder look
        // deleted. Stored intent is never thrown away on that evidence.
        guard directoryExists(root) else { return false }

        let restorable = restorableFavouriteFolders()
        let knownTags = Set(tagCounts().map(\.name))
        let knownNotes = Set(records.values.map(\.relativePath))
        let kept = favouriteItems.filter { item in
            switch item {
            case .folder(let path):
                return restorable.contains(path)
                    || directoryExists(root.appendingPathComponent(path, isDirectory: true))
            case .note(let path):
                if knownNotes.contains(path) { return true }
                return fileManager.fileExists(
                    atPath: root.appendingPathComponent(path).path
                )
            case .tag(let name):
                return knownTags.contains(name)
            }
        }
        guard kept != favouriteItems else { return false }
        favouriteItems = kept
        if favouriteItems.isEmpty { favouritesRanked = false }
        persistFavouritesBestEffort()
        return true
    }

    // MARK: - Internals

    private func makeSnapshot(_ record: NoteRecord) -> NoteSnapshot {
        NoteSnapshot(
            url: record.url,
            title: record.title,
            excerpt: record.excerpt,
            tags: record.tags,
            modifiedAt: record.modifiedAt,
            createdAt: record.createdAt,
            isPinned: pinned.contains(record.relativePath),
            folderURL: record.folderURL,
            relativePath: record.relativePath,
            isTrashed: record.isTrashed,
            rawBody: record.rawBody,
            searchHaystack: record.searchHaystack,
            fileStemDiffersFromTitle: NoteSnapshot.stemDiffersFromTitle(
                url: record.url, title: record.title
            )
        )
    }

    private func readRecord(url: URL, root: URL) -> NoteRecord? {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        if let values,
           !Self.shouldReadNoteFile(
               isUbiquitous: values.isUbiquitousItem,
               downloadingStatus: values.ubiquitousItemDownloadingStatus
           ) {
            // Request the copy; a later rescan picks it up. Do not wait.
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        let url = url.standardizedFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = FrontMatterCodec.parse(text)
        let modified = values?.contentModificationDate ?? Date()
        let createdFromFile = values?.creationDate ?? modified
        let created = parseCreated(parsed.frontMatter?.created) ?? createdFromFile
        // Read from the same keys the enumerator prefetches, so the comparison
        // in `rescan` is between two values of the same kind.
        let stamp = Self.stamp(from: values)
        let folder = url.deletingLastPathComponent().standardizedFileURL
        let title = NoteExcerpt.title(
            from: parsed,
            fileName: url.deletingPathExtension().lastPathComponent,
            useFirstLine: useFirstLineAsTitle
        )
        let tags = parsed.frontMatter?.tags ?? []
        return NoteRecord(
            url: url,
            title: title,
            excerpt: NoteExcerpt.make(from: parsed.body),
            tags: tags,
            modifiedAt: modified,
            createdAt: created,
            rawBody: parsed.body,
            // `bodyForSearch` keeps the YAML title and tags in the haystack even
            // when the displayed title comes from the first line or the file
            // name, exactly as the previous search did.
            searchHaystack: NoteSnapshot.haystack(
                title: title, tags: tags, body: parsed.bodyForSearch
            ),
            relativePath: LibraryPaths.relativePath(of: url, to: root),
            isTrashed: LibraryPaths.isInsideTrash(url, root: root),
            folderURL: folder,
            stamp: stamp
        )
    }

    private static func stamp(from values: URLResourceValues?) -> FileStamp? {
        guard let modified = values?.contentModificationDate,
              let size = values?.fileSize else { return nil }
        return FileStamp(modified: modified, size: size)
    }

    private func parseCreated(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    /// `visit` also receives the file's stamp, prefetched by the enumerator, so
    /// the incremental rescan costs one `stat` per note and no file read.
    private func enumerateNotes(from root: URL, visit: (URL, FileStamp?) -> Void) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .contentModificationDateKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == LibraryPaths.sidecarFolderName {
                enumerator.skipDescendants()
                continue
            }
            // Asked from the enumerator's own URL, which carries the prefetched
            // values: the `fileExists` stat per entry was pure waste. Trash
            // notes are kept on purpose — the Trash view reads them from
            // `records`.
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            if isDirectory == true { continue }
            if item.pathExtension.lowercased() == "icloud" { continue }
            guard Self.isNoteFile(item) else { continue }
            let values = try? item.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey
            ])
            visit(item, Self.stamp(from: values))
        }
    }

    private func enumerateDirectories(from root: URL, visit: (URL) -> Void) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let trash = LibraryPaths.trashURL(root: root).standardizedFileURL
        while let item = enumerator.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let url = item.standardizedFileURL
            if url.lastPathComponent == LibraryPaths.sidecarFolderName {
                enumerator.skipDescendants()
                continue
            }
            if LibraryPaths.isAttachmentFolderName(url.lastPathComponent, patterns: attachmentFolderPatterns) {
                enumerator.skipDescendants()
                continue
            }
            if url == trash || url.path.hasPrefix(trash.path + "/") {
                enumerator.skipDescendants()
                continue
            }
            visit(url)
        }
    }

    nonisolated static func isNoteFile(_ url: URL) -> Bool {
        ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())
    }

    /// `String(contentsOf:)` hydrates an iCloud placeholder on this thread.
    nonisolated static func shouldReadNoteFile(
        isUbiquitous: Bool?,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        guard isUbiquitous == true else { return true }
        guard let downloadingStatus else { return true }
        return downloadingStatus == .current
    }

    private func uniqueDestination(for source: URL, in folder: URL) -> URL {
        uniqueDestination(fileName: source.lastPathComponent, in: folder, excluding: source)
    }

    private func uniqueDestination(fileName: String, in folder: URL, excluding: URL? = nil) -> URL {
        let asURL = URL(fileURLWithPath: fileName)
        let ext = asURL.pathExtension
        let base = asURL.deletingPathExtension().lastPathComponent
        let unique = FilenameSanitizer.uniqueName(base: base, ext: ext, in: folder, excluding: excluding)
        if ext.isEmpty {
            return folder.appendingPathComponent(unique)
        }
        return folder.appendingPathComponent(unique).appendingPathExtension(ext)
    }

    private func moveFile(_ source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw LibraryError.nameExists(destination.deletingPathExtension().lastPathComponent)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func ensureDirectory(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func loadSidecars() {
        guard let root else { return }
        if let data = try? Data(contentsOf: LibraryPaths.pinsURL(root: root)),
           let file = try? JSONDecoder().decode(PinFile.self, from: data) {
            pinned = Set(file.paths)
        }
        if let data = try? Data(contentsOf: LibraryPaths.folderSymbolsURL(root: root)),
           let file = try? JSONDecoder().decode(FolderSymbolFile.self, from: data) {
            folderSymbols = file.symbols.reduce(into: [:]) { result, pair in
                let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pair.key.isEmpty, !name.isEmpty else { return }
                result[pair.key] = name
            }
        }
        if let data = try? Data(contentsOf: LibraryPaths.favouritesURL(root: root)),
           let file = try? JSONDecoder().decode(FavouriteFile.self, from: data) {
            favouriteItems = Self.uniqued(file.items.compactMap(Self.normalized))
            favouritesRanked = file.ranked && !favouriteItems.isEmpty
        }
        if let data = try? Data(contentsOf: LibraryPaths.originsURL(root: root)),
           let file = try? JSONDecoder().decode(OriginFile.self, from: data) {
            origins = file.items
            folderResidue = file.folderResidue ?? [:]
        }
    }

    /// Counts atomic writes of `pins.json`, so a test can prove that pinning K
    /// notes costs one write and not K.
    private(set) var pinWriteCount = 0

    private func persistPins() throws {
        guard let root else { return }
        let dir = LibraryPaths.sidecarURL(root: root)
        ensureDirectory(dir)
        let file = PinFile(paths: Array(pinned).sorted())
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: LibraryPaths.pinsURL(root: root), options: .atomic)
            pinWriteCount += 1
        } catch {
            throw LibraryError.sidecarWriteFailed
        }
    }

    /// Counts atomic writes of `origins.json`, so a test can prove that
    /// trashing N notes costs one write and not N.
    private(set) var originWriteCount = 0

    private func persistOrigins() throws {
        guard let root else { return }
        ensureDirectory(LibraryPaths.trashURL(root: root))
        let file = OriginFile(
            items: origins,
            folderResidue: folderResidue.isEmpty ? nil : folderResidue
        )
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: LibraryPaths.originsURL(root: root), options: .atomic)
            originWriteCount += 1
        } catch {
            throw LibraryError.sidecarWriteFailed
        }
    }

    private func persistSidecars() throws {
        try persistOrigins()
        try persistPins()
    }

    private func persistSidecarsBestEffort() {
        try? persistOrigins()
        try? persistPins()
        try? persistFavourites()
    }

    /// Counts atomic writes of `folderSymbols.json`.
    private(set) var folderSymbolWriteCount = 0

    private func persistFolderSymbols() {
        guard let root else { return }
        folderSymbolWriteCount += 1
        let dir = LibraryPaths.sidecarURL(root: root)
        ensureDirectory(dir)
        let file = FolderSymbolFile(symbols: folderSymbols)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: LibraryPaths.folderSymbolsURL(root: root), options: .atomic)
        }
    }

    private func persistFavourites() throws {
        guard let root else { return }
        let dir = LibraryPaths.sidecarURL(root: root)
        ensureDirectory(dir)
        if !favouritesRanked {
            favouriteItems = sortedFavourites(favouriteItems)
        }
        let file = FavouriteFile(ranked: favouritesRanked, items: favouriteItems)
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: LibraryPaths.favouritesURL(root: root), options: .atomic)
            favouriteWriteCount += 1
        } catch {
            throw LibraryError.sidecarWriteFailed
        }
    }

    private func persistFavouritesBestEffort() {
        try? persistFavourites()
    }

    private func retargetPin(from old: String, to new: String) {
        if pinned.remove(old) != nil {
            pinned.insert(new)
        }
    }

    /// Path of a trashed file relative to the Trash directory. A file at the
    /// Trash root is `Note.md`, matching older `origins.json` keys.
    private func originKey(for url: URL) -> String {
        guard let root else { return url.lastPathComponent }
        let relative = LibraryPaths.relativePath(of: url, to: LibraryPaths.trashURL(root: root))
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    /// Looks up by trash-relative path, then by `lastPathComponent` so older
    /// sidecars and in-flight maps still resolve.
    private func origin(for url: URL) -> OriginRecord? {
        let key = originKey(for: url)
        if let record = origins[key] { return record }
        let fallback = url.lastPathComponent
        guard fallback != key else { return nil }
        return origins[fallback]
    }

    @discardableResult
    private func takeOrigin(for url: URL) -> OriginRecord? {
        let key = originKey(for: url)
        if let record = origins.removeValue(forKey: key) { return record }
        let fallback = url.lastPathComponent
        guard fallback != key else { return nil }
        return origins.removeValue(forKey: fallback)
    }

    /// `removeItem` of a path that is already gone is success; a busy or
    /// permission failure on a file that is still there must throw.
    private func unlinkIfPresent(_ url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            if fileManager.fileExists(atPath: url.path) { throw error }
        }
    }

    /// Drops leftover residue directories whose original folder nothing still
    /// in the Trash would reunite into. Same spirit as `pruneFolderSymbols`.
    private func pruneOrphanedResidue() throws {
        guard let root, !folderResidue.isEmpty else { return }
        var restorable: Set<String> = []
        for record in records.values where record.isTrashed {
            if let folder = origin(for: record.url)?.folder {
                restorable.insert(folder)
            }
        }
        let trash = LibraryPaths.trashURL(root: root)
        for (trashName, originalRelative) in folderResidue {
            if restorable.contains(originalRelative) { continue }
            let residueDir = trash.appendingPathComponent(trashName, isDirectory: true)
            if directoryExists(residueDir) {
                try unlinkIfPresent(residueDir)
            }
            folderResidue.removeValue(forKey: trashName)
        }
    }

    private func retargetOrigins(under oldFolder: URL, to newFolder: URL, root: URL) {
        let oldPrefix = LibraryPaths.relativePath(of: oldFolder, to: root)
        let newPrefix = LibraryPaths.relativePath(of: newFolder, to: root)
        for (key, origin) in origins {
            guard let next = LibraryPaths.remappedRelativePath(
                origin.folder, from: oldPrefix, to: newPrefix
            ) else { continue }
            origins[key] = OriginRecord(folder: next, fileName: origin.fileName)
        }
        for (key, path) in folderResidue {
            guard let next = LibraryPaths.remappedRelativePath(
                path, from: oldPrefix, to: newPrefix
            ) else { continue }
            folderResidue[key] = next
        }
    }

    /// Moves the remaining folder into Trash and records it so restore can
    /// reunite leftover files with the original relative path.
    private func trashLeftoverFolder(_ url: URL, root: URL) throws {
        let trash = LibraryPaths.trashURL(root: root)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let dest = uniqueDestination(fileName: url.lastPathComponent, in: trash)
        let originalRelative = LibraryPaths.relativePath(of: url, to: root)
        try fileManager.moveItem(at: url, to: dest)
        folderResidue[dest.lastPathComponent] = originalRelative
        try persistOrigins()
    }

    /// Moves leftover files (and nested leftover folders) from the Trash
    /// residue directory into the restored origin folder. Never overwrites a
    /// live file: a name that already exists is unique-renamed.
    private func reuniteResidue(for relativeFolder: String, into destinationFolder: URL, root: URL) {
        let matching = folderResidue.filter { $0.value == relativeFolder }
        guard !matching.isEmpty else { return }
        let trash = LibraryPaths.trashURL(root: root)
        for (trashName, _) in matching {
            let residueDir = trash.appendingPathComponent(trashName, isDirectory: true)
            guard directoryExists(residueDir) else {
                folderResidue.removeValue(forKey: trashName)
                continue
            }
            let items: [URL]
            do {
                items = try fileManager.contentsOfDirectory(
                    at: residueDir,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                continue
            }
            for item in items {
                let dest = uniqueDestination(fileName: item.lastPathComponent, in: destinationFolder)
                try? fileManager.moveItem(at: item, to: dest)
            }
            let remaining: [URL]
            do {
                remaining = try fileManager.contentsOfDirectory(
                    at: residueDir,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                continue
            }
            if remaining.isEmpty {
                try? fileManager.removeItem(at: residueDir)
                folderResidue.removeValue(forKey: trashName)
            }
        }
    }

    private func retargetPins(under oldFolder: URL, to newFolder: URL, root: URL) {
        let oldPrefix = LibraryPaths.relativePath(of: oldFolder, to: root)
        let newPrefix = LibraryPaths.relativePath(of: newFolder, to: root)
        for path in Array(pinned) {
            guard let next = LibraryPaths.remappedRelativePath(
                path, from: oldPrefix, to: newPrefix
            ) else { continue }
            pinned.remove(path)
            pinned.insert(next)
        }
    }

    private func retargetFolderSymbols(under oldFolder: URL, to newFolder: URL, root: URL) {
        let oldPrefix = LibraryPaths.relativePath(of: oldFolder, to: root)
        let newPrefix = LibraryPaths.relativePath(of: newFolder, to: root)
        for (path, name) in Array(folderSymbols) {
            guard let next = LibraryPaths.remappedRelativePath(
                path, from: oldPrefix, to: newPrefix
            ) else { continue }
            folderSymbols.removeValue(forKey: path)
            folderSymbols[next] = name
        }
    }

    private func retargetFavourites(under oldFolder: URL, to newFolder: URL, root: URL) {
        let oldPrefix = LibraryPaths.relativePath(of: oldFolder, to: root)
        let newPrefix = LibraryPaths.relativePath(of: newFolder, to: root)
        favouriteItems = Self.uniqued(favouriteItems.map { item in
            switch item {
            case .folder(let path):
                guard let next = LibraryPaths.remappedRelativePath(
                    path, from: oldPrefix, to: newPrefix
                ) else { return item }
                return .folder(next)
            case .note(let path):
                guard let next = LibraryPaths.remappedRelativePath(
                    path, from: oldPrefix, to: newPrefix
                ) else { return item }
                return .note(next)
            case .tag:
                return item
            }
        })
    }

    @discardableResult
    private func retargetFavouriteNote(from old: String, to new: String) -> Bool {
        guard old != new else { return false }
        var changed = false
        favouriteItems = Self.uniqued(favouriteItems.map { item in
            guard case .note(let path) = item, path == old else { return item }
            changed = true
            return .note(new)
        })
        return changed
    }

    private func displayedFavourites() -> [Favourite] {
        favouritesRanked ? favouriteItems : sortedFavourites(favouriteItems)
    }

    private static func normalized(_ item: Favourite) -> Favourite? {
        switch item {
        case .folder(let path):
            let trimmed = path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else { return nil }
            return .folder(trimmed)
        case .note(let path):
            let trimmed = path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else { return nil }
            return .note(trimmed)
        case .tag(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .tag(trimmed)
        }
    }

    private static func uniqued(_ items: [Favourite]) -> [Favourite] {
        var seen = Set<Favourite>()
        return items.filter { seen.insert($0).inserted }
    }

    private func sortedFavourites(_ items: [Favourite]) -> [Favourite] {
        var titles: [String: String] = [:]
        for record in records.values { titles[record.relativePath] = record.title }
        return items.sorted { a, b in
            let names = Self.sortName(a, titles: titles).localizedStandardCompare(Self.sortName(b, titles: titles))
            if names != .orderedSame { return names == .orderedAscending }
            switch (a, b) {
            case (.folder(let p1), .folder(let p2)):
                return p1.localizedStandardCompare(p2) == .orderedAscending
            case (.note(let p1), .note(let p2)):
                return p1.localizedStandardCompare(p2) == .orderedAscending
            case (.tag(let t1), .tag(let t2)):
                return t1.localizedStandardCompare(t2) == .orderedAscending
            case (.folder, .note), (.folder, .tag), (.note, .tag):
                return true
            case (.note, .folder), (.tag, .folder), (.tag, .note):
                return false
            }
        }
    }

    /// Live title for a note when a record exists; otherwise the file stem.
    private static func sortName(_ item: Favourite, titles: [String: String]) -> String {
        switch item {
        case .folder, .tag:
            return item.displayName
        case .note(let path):
            if let title = titles[path] { return title }
            return item.displayName
        }
    }

    /// Folders a trashed note or leftover residue could recreate on restore,
    /// including every ancestor `restore` would mkdir.
    private func restorableFavouriteFolders() -> Set<String> {
        var restorable: Set<String> = []
        func insertAncestors(_ path: String) {
            var path = path
            while !path.isEmpty, path != "." {
                restorable.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        for record in records.values where record.isTrashed {
            guard let origin = origin(for: record.url) else { continue }
            insertAncestors(origin.folder)
        }
        for path in folderResidue.values {
            insertAncestors(path)
        }
        return restorable
    }

    /// Collects symbol keys no folder can claim any more: the directory is gone
    /// from disk *and* no note left in the Trash would recreate it on restore.
    /// A deleted folder therefore keeps its glyph for as long as the Trash can
    /// bring it back, and `folderSymbols.json` still cannot grow without bound.
    /// Returns true when the map actually changed.
    @discardableResult
    private func pruneFolderSymbols() -> Bool {
        guard let root, !folderSymbols.isEmpty else { return false }
        // A root that momentarily cannot be read would make every folder look
        // deleted. Stored intent is never thrown away on that evidence.
        guard directoryExists(root) else { return false }

        var restorable: Set<String> = []
        for record in records.values where record.isTrashed {
            guard let origin = origin(for: record.url) else { continue }
            // `restore` creates intermediate directories, so every ancestor of
            // the origin folder comes back too.
            var path = origin.folder
            while !path.isEmpty, path != "." {
                restorable.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }

        let kept = folderSymbols.filter { key, _ in
            restorable.contains(key)
                || directoryExists(root.appendingPathComponent(key, isDirectory: true))
        }
        guard kept.count != folderSymbols.count else { return false }
        folderSymbols = kept
        return true
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Only iCloud "conflicted copy" names, never `Untitled Note 2`.
    private func resolveNumberedCopies() {
        var losers: [URL] = []
        for record in records.values where !record.isTrashed {
            let name = record.url.deletingPathExtension().lastPathComponent
            guard name.lowercased().contains("conflicted copy") else { continue }
            let sibling = record.folderURL
                .appendingPathComponent(strippedConflictName(name))
                .appendingPathExtension(record.url.pathExtension)
            if records[sibling.standardizedFileURL] != nil || fileManager.fileExists(atPath: sibling.path) {
                losers.append(record.url)
            }
        }
        if !losers.isEmpty {
            try? trash(losers)
        }
    }

    private func strippedConflictName(_ name: String) -> String {
        if let range = name.range(of: " (conflicted copy", options: .caseInsensitive) {
            return String(name[..<range.lowerBound])
        }
        return name
    }
}
