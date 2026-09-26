import Foundation

enum LibraryPane: Hashable {
    case sidebar
    case notes
    case preview
}

/// The pure half of the library's keyboard. The horizontal contract is **not**
/// here: moving between columns is three guarded handlers — the note list's and
/// the preview's `.onKeyPress` in `LibraryView`, and `SidebarOutlineView.keyDown`
/// through the coordinator's `rightArrow()` / `leftArrow()`. Each carries a
/// condition no pure function can hold (an empty note list, a hidden sidebar,
/// `PreviewBridge.becomeFirstResponder()`), so a `movePane` next to them could
/// only ever have been a second, weaker copy of the decision — which is what it
/// became: dead code with six passing assertions. It was removed with them.
enum LibraryKeyboard {
    enum SidebarArrow {
        case expand(Set<URL>)
        case collapse(Set<URL>)
        case select(LibraryModel.SidebarItem)
        case moveToNotes
        case ignored
    }

    /// Finder / NetNewsWire: right expands, or moves to the list when already open / leaf.
    static func sidebarRight(
        _ selection: LibraryModel.SidebarItem,
        in folders: [FolderSnapshot],
        expanded: Set<URL>
    ) -> SidebarArrow {
        guard case .project(let url) = selection,
              let folder = folder(url, in: folders),
              folder.hasChildren else {
            return .moveToNotes
        }
        if !expanded.contains(url) {
            var next = expanded
            next.insert(url)
            return .expand(next)
        }
        return .moveToNotes
    }

    /// Left collapses; if already closed, select the parent folder.
    static func sidebarLeft(
        _ selection: LibraryModel.SidebarItem,
        in folders: [FolderSnapshot],
        expanded: Set<URL>
    ) -> SidebarArrow {
        guard case .project(let url) = selection,
              let selected = folder(url, in: folders) else {
            return .ignored
        }
        if selected.hasChildren, expanded.contains(url) {
            var next = expanded
            next.remove(url)
            return .collapse(next)
        }
        if let parent = selected.parentURL,
           folder(parent, in: folders) != nil {
            return .select(.project(parent))
        }
        return .ignored
    }

    /// `nil` if Space does not apply (not a folder, or a leaf).
    static func toggling(
        _ selection: LibraryModel.SidebarItem,
        in folders: [FolderSnapshot],
        expanded: Set<URL>
    ) -> Set<URL>? {
        guard case .project(let url) = selection else { return nil }
        guard let folder = folder(url, in: folders), folder.hasChildren else { return nil }
        var next = expanded
        if next.contains(url) {
            next.remove(url)
        } else {
            next.insert(url)
        }
        return next
    }

    static func folder(_ url: URL, in folders: [FolderSnapshot]) -> FolderSnapshot? {
        for item in folders {
            if item.url == url { return item }
            if let children = item.children, let found = folder(url, in: children) {
                return found
            }
        }
        return nil
    }

    /// Letters, digits, punctuation, symbols, and space — what a search field
    /// would accept. Tab, Return, and Delete stay out so the list keeps them.
    static let searchJumpCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.formUnion(.punctuationCharacters)
        set.formUnion(.symbols)
        set.insert(charactersIn: " ")
        return set
    }()

    /// Text to put in the library search field when the note list sees this key.
    /// `nil` if it is a menu chord (⌘F, ⌘A, …) or not a search character.
    static func searchInsertion(
        characters: String,
        command: Bool,
        control: Bool,
        option: Bool
    ) -> String? {
        guard !command, !control, !option else { return nil }
        guard !characters.isEmpty else { return nil }
        guard characters.unicodeScalars.allSatisfy({ searchJumpCharacters.contains($0) }) else {
            return nil
        }
        return characters
    }
}
