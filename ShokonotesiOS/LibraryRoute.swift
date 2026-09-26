import Foundation

/// One step on the iOS library stack. Root is the sources list; a collection
/// may be followed by a note. Favourite notes push `.note` directly.
enum LibraryRoute: Hashable {
    case inbox
    case all
    case untagged
    case trash
    case folder(URL)
    case tag(String)
    case note(URL)

    var isCollection: Bool {
        if case .note = self { return false }
        return true
    }

    /// Writes `sidebarSelection` and `selectedTags` so `library.notes` matches.
    /// Tag sources use All Notes plus that tag — `.tag` is row identity only.
    @MainActor
    func apply(to library: LibraryModel) {
        let selection: LibraryModel.SidebarItem
        let tags: Set<String>
        switch self {
        case .inbox:
            selection = .inbox
            tags = []
        case .all:
            selection = .all
            tags = []
        case .untagged:
            selection = .untagged
            tags = []
        case .trash:
            selection = .trash
            tags = []
        case .folder(let url):
            selection = .project(url.standardizedFileURL)
            tags = []
        case .tag(let name):
            selection = .all
            tags = [name]
        case .note:
            return
        }
        if library.sidebarSelection != selection {
            library.sidebarSelection = selection
        }
        if library.selectedTags != tags {
            library.selectedTags = tags
        }
    }
}
