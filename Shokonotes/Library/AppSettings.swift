import Foundation
#if os(macOS)
import AppKit
#endif

enum NamingMode: String, CaseIterable, Identifiable {
    case untitled
    case followTitle
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}

enum SortKey: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared: AppSettings = {
        #if os(iOS)
        AppGroup.migrateBookmarkIfNeeded()
        return AppSettings(defaults: .standard, groupDefaults: AppGroup.defaults)
        #else
        return AppSettings(defaults: .standard)
        #endif
    }()

    private let defaults: UserDefaults
    /// When non-nil (iOS host), every bookmark save is mirrored so the share
    /// extension can write the file itself.
    private let groupDefaults: UserDefaults?

    private enum Key {
        static let bookmark = AppGroup.bookmarkKey
        #if os(macOS)
        static let editorBundle = "externalEditorBundle"
        #endif
        static let naming = "namingMode"
        static let appearance = "appearanceMode"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let showExcerpt = "showExcerpt"
        static let showDate = "showDate"
        static let resolveConflicts = "resolveICloudConflicts"
        static let fileExtension = "noteExtension"
        static let showInboxBadge = "showInboxBadge"
        // A fresh opt-in: ignore the retired "quitOnWindowClose" preference.
        static let quitOnWindowClose = "quitOnLibraryWindowClose"
        static let previewCodeTheme = "previewCodeTheme"
        static let previewTheme = "previewTheme"
        #if os(macOS)
        static let quickNoteShortcut = "quickNoteShortcut"
        static let activateShortcut = "activateShortcut"
        #endif
        static let previewFontSize = "previewFontSize"
        static let previewMeasure = "previewMeasure"
        static let previewFont = "previewFont"
        static let previewLineHeight = "previewLineHeight"
        static let previewImages = "previewImages"
        static let previewHardBreaks = "previewHardBreaks"
        static let previewSmartPunctuation = "previewSmartPunctuation"
        static let previewShowTitle = "previewShowTitle"
        static let compactRows = "compactRows"
        static let openEditorOnCreate = "openEditorOnCreate"
        static let useFirstLineAsTitle = "useFirstLineAsTitle"
        static let showTagsInList = "showTagsInList"
        static let includeFolderDescendants = "includeFolderDescendants"
        static let lastSidebar = "lastSidebarToken"
        static let lastSelectedTags = "lastSelectedTags"
        static let lastNotePath = "lastNoteRelativePath"
        static let expandedFolders = "expandedFolderPaths"
        static let attachmentFolders = "attachmentFolderPatternsText"
    }

    init(defaults: UserDefaults, groupDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.groupDefaults = groupDefaults
        if defaults.object(forKey: Key.showExcerpt) == nil {
            defaults.set(true, forKey: Key.showExcerpt)
        }
        if defaults.object(forKey: Key.showDate) == nil {
            defaults.set(true, forKey: Key.showDate)
        }
        if defaults.object(forKey: Key.sortAscending) == nil {
            defaults.set(false, forKey: Key.sortAscending)
        }
        #if os(macOS)
        if defaults.string(forKey: Key.editorBundle) == nil {
            defaults.set(ExternalEditors.defaultBundleIdentifier(), forKey: Key.editorBundle)
        }
        #endif
        if defaults.string(forKey: Key.fileExtension) == nil {
            defaults.set("md", forKey: Key.fileExtension)
        }
        #if os(macOS)
        if defaults.object(forKey: Key.quickNoteShortcut) == nil {
            encodeChord(KeyChord.quickNoteDefault, key: Key.quickNoteShortcut)
        }
        if defaults.object(forKey: Key.activateShortcut) == nil {
            encodeChord(KeyChord.activateDefault, key: Key.activateShortcut)
        }
        #endif
        if defaults.object(forKey: Key.previewFontSize) == nil {
            defaults.set(17, forKey: Key.previewFontSize)
        }
        if defaults.object(forKey: Key.useFirstLineAsTitle) == nil {
            defaults.set(true, forKey: Key.useFirstLineAsTitle)
        }
        if defaults.object(forKey: Key.showTagsInList) == nil {
            defaults.set(true, forKey: Key.showTagsInList)
        }
        if defaults.object(forKey: Key.previewSmartPunctuation) == nil {
            defaults.set(true, forKey: Key.previewSmartPunctuation)
        }
        if defaults.object(forKey: Key.previewShowTitle) == nil {
            defaults.set(true, forKey: Key.previewShowTitle)
        }
        if defaults.object(forKey: Key.openEditorOnCreate) == nil {
            defaults.set(true, forKey: Key.openEditorOnCreate)
        }
        if defaults.object(forKey: Key.includeFolderDescendants) == nil {
            defaults.set(true, forKey: Key.includeFolderDescendants)
        }
    }

    var storageBookmark: Data? {
        get { defaults.data(forKey: Key.bookmark) }
        set {
            defaults.set(newValue, forKey: Key.bookmark)
            AppGroup.mirrorBookmark(newValue, onto: groupDefaults)
            objectWillChange.send()
        }
    }

    #if os(macOS)
    var externalEditorBundle: String {
        get { defaults.string(forKey: Key.editorBundle) ?? ExternalEditors.textEditBundle }
        set { defaults.set(newValue, forKey: Key.editorBundle); objectWillChange.send() }
    }
    #endif

    var naming: NamingMode {
        get { NamingMode(rawValue: defaults.string(forKey: Key.naming) ?? "") ?? .untitled }
        set { defaults.set(newValue.rawValue, forKey: Key.naming); objectWillChange.send() }
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            #if os(macOS)
            applyAppearance()
            #endif
            objectWillChange.send()
        }
    }

    var sortKey: SortKey {
        get { SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .modified }
        set { defaults.set(newValue.rawValue, forKey: Key.sortKey); objectWillChange.send() }
    }

    var sortAscending: Bool {
        get { defaults.bool(forKey: Key.sortAscending) }
        set { defaults.set(newValue, forKey: Key.sortAscending); objectWillChange.send() }
    }

    var showExcerpt: Bool {
        get { defaults.bool(forKey: Key.showExcerpt) }
        set { defaults.set(newValue, forKey: Key.showExcerpt); objectWillChange.send() }
    }

    var showDate: Bool {
        get { defaults.bool(forKey: Key.showDate) }
        set { defaults.set(newValue, forKey: Key.showDate); objectWillChange.send() }
    }

    var resolveICloudConflicts: Bool {
        get { defaults.bool(forKey: Key.resolveConflicts) }
        set { defaults.set(newValue, forKey: Key.resolveConflicts); objectWillChange.send() }
    }

    var showInboxBadge: Bool {
        get { defaults.bool(forKey: Key.showInboxBadge) }
        set {
            defaults.set(newValue, forKey: Key.showInboxBadge)
            #if os(macOS)
            DockBadge.refresh()
            #endif
            objectWillChange.send()
        }
    }

    var quitOnWindowClose: Bool {
        get { defaults.bool(forKey: Key.quitOnWindowClose) }
        set { defaults.set(newValue, forKey: Key.quitOnWindowClose); objectWillChange.send() }
    }

    var previewCodeTheme: PreviewCodeTheme {
        get { PreviewCodeTheme(rawValue: defaults.string(forKey: Key.previewCodeTheme) ?? "") ?? .github }
        set { defaults.set(newValue.rawValue, forKey: Key.previewCodeTheme); objectWillChange.send() }
    }

    var previewTheme: PreviewTheme {
        get { PreviewTheme(rawValue: defaults.string(forKey: Key.previewTheme) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.previewTheme); objectWillChange.send() }
    }

    #if os(macOS)
    var quickNoteShortcut: KeyChord? {
        get { decodeChord(Key.quickNoteShortcut) }
        set {
            encodeChord(newValue, key: Key.quickNoteShortcut)
            GlobalShortcuts.register()
            objectWillChange.send()
        }
    }

    var activateShortcut: KeyChord? {
        get { decodeChord(Key.activateShortcut) }
        set {
            encodeChord(newValue, key: Key.activateShortcut)
            GlobalShortcuts.register()
            objectWillChange.send()
        }
    }
    #endif

    var previewFontSize: Int {
        get {
            let value = defaults.integer(forKey: Key.previewFontSize)
            return value == 0 ? 17 : min(24, max(13, value))
        }
        set { defaults.set(newValue, forKey: Key.previewFontSize); objectWillChange.send() }
    }

    var previewMeasure: PreviewMeasure {
        get {
            guard defaults.object(forKey: Key.previewMeasure) != nil else { return .medium }
            return PreviewMeasure(rawValue: defaults.integer(forKey: Key.previewMeasure)) ?? .medium
        }
        set { defaults.set(newValue.rawValue, forKey: Key.previewMeasure); objectWillChange.send() }
    }

    var useFirstLineAsTitle: Bool {
        get { defaults.bool(forKey: Key.useFirstLineAsTitle) }
        set { defaults.set(newValue, forKey: Key.useFirstLineAsTitle); objectWillChange.send() }
    }

    var showTagsInList: Bool {
        get { defaults.bool(forKey: Key.showTagsInList) }
        set { defaults.set(newValue, forKey: Key.showTagsInList); objectWillChange.send() }
    }

    /// Folder sidebar lists: own notes plus descendants. Inbox stays root-only.
    var includeFolderDescendants: Bool {
        get { defaults.bool(forKey: Key.includeFolderDescendants) }
        set { defaults.set(newValue, forKey: Key.includeFolderDescendants); objectWillChange.send() }
    }

    var previewFont: PreviewFont {
        get { PreviewFont(rawValue: defaults.string(forKey: Key.previewFont) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.previewFont); objectWillChange.send() }
    }

    var previewLineHeight: PreviewLineHeight {
        get { PreviewLineHeight(rawValue: defaults.string(forKey: Key.previewLineHeight) ?? "") ?? .comfortable }
        set { defaults.set(newValue.rawValue, forKey: Key.previewLineHeight); objectWillChange.send() }
    }

    var previewImages: PreviewImageSize {
        get { PreviewImageSize(rawValue: defaults.string(forKey: Key.previewImages) ?? "") ?? .full }
        set { defaults.set(newValue.rawValue, forKey: Key.previewImages); objectWillChange.send() }
    }

    var previewHardBreaks: Bool {
        get { defaults.bool(forKey: Key.previewHardBreaks) }
        set { defaults.set(newValue, forKey: Key.previewHardBreaks); objectWillChange.send() }
    }

    var previewSmartPunctuation: Bool {
        get { defaults.bool(forKey: Key.previewSmartPunctuation) }
        set { defaults.set(newValue, forKey: Key.previewSmartPunctuation); objectWillChange.send() }
    }

    var previewShowTitle: Bool {
        get { defaults.bool(forKey: Key.previewShowTitle) }
        set { defaults.set(newValue, forKey: Key.previewShowTitle); objectWillChange.send() }
    }

    var compactRows: Bool {
        get { defaults.bool(forKey: Key.compactRows) }
        set { defaults.set(newValue, forKey: Key.compactRows); objectWillChange.send() }
    }

    var openEditorOnCreate: Bool {
        get { defaults.bool(forKey: Key.openEditorOnCreate) }
        set { defaults.set(newValue, forKey: Key.openEditorOnCreate); objectWillChange.send() }
    }

    var attachmentFoldersText: String {
        get {
            if let stored = defaults.string(forKey: Key.attachmentFolders) {
                return stored
            }
            return LibraryPaths.defaultAttachmentFolderPatterns.joined(separator: "\n")
        }
        set { defaults.set(newValue, forKey: Key.attachmentFolders); objectWillChange.send() }
    }

    var attachmentFolderPatterns: [String] {
        attachmentFoldersText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var lastSidebarToken: String {
        get { defaults.string(forKey: Key.lastSidebar) ?? "all" }
        set { defaults.set(newValue, forKey: Key.lastSidebar) }
    }

    var lastSelectedTags: [String] {
        get { defaults.stringArray(forKey: Key.lastSelectedTags) ?? [] }
        set { defaults.set(newValue, forKey: Key.lastSelectedTags) }
    }

    var lastNoteRelativePath: String? {
        get { defaults.string(forKey: Key.lastNotePath) }
        set { defaults.set(newValue, forKey: Key.lastNotePath) }
    }

    var expandedFolderPaths: [String] {
        get { defaults.stringArray(forKey: Key.expandedFolders) ?? [] }
        set { defaults.set(newValue, forKey: Key.expandedFolders) }
    }

    var previewStyle: PreviewStyle {
        PreviewStyle(
            fontSize: previewFontSize,
            maxWidthEm: previewMeasure.rawValue,
            font: previewFont,
            lineHeight: previewLineHeight,
            images: previewImages,
            hardLineBreaks: previewHardBreaks,
            smartPunctuation: previewSmartPunctuation,
            showTitle: previewShowTitle,
            theme: previewTheme
        )
    }

    var noteExtension: String {
        get {
            let value = defaults.string(forKey: Key.fileExtension) ?? "md"
            return value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty ? "md" : value
        }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            defaults.set(cleaned.isEmpty ? "md" : cleaned, forKey: Key.fileExtension)
            objectWillChange.send()
        }
    }

    #if os(macOS)
    func applyAppearance() {
        switch appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }

    private func decodeChord(_ key: String) -> KeyChord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyChord.self, from: data)
    }

    private func encodeChord(_ chord: KeyChord?, key: String) {
        if let chord, let data = try? JSONEncoder().encode(chord) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
    #endif
}
