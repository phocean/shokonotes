import AppKit
import Foundation
import UniformTypeIdentifiers

/// A favourite shortcut dragged inside the sidebar. Distinct from
/// `FolderTransfer`: dropping this on the folder tree must not move a folder
/// on disk.
struct FavouriteTransfer: Codable, Hashable {
    let item: Favourite
}

extension UTType {
    static let shokonotesFavourite = UTType(exportedAs: "com.jcbaptiste.shokonotes.favourite-reference")
}

/// What is actually being dragged in the sidebar. Broader than
/// `SidebarDragPayload`, which stays the tree planner's folder-or-notes input.
enum SidebarDragKind: Equatable {
    /// A folder row from the Folders tree — never a favourite shortcut.
    case folder(URL)
    case tag(String)
    /// A row already in Favourites, dragged to reorder.
    case favourite(Favourite)
    case notes
}

/// Which column of meaning the cursor is over.
enum SidebarDropTarget: Equatable {
    /// The folder tree (and every row that is not the Favourites section).
    /// The insertion line here still says a **level**, never a rank.
    case tree(SidebarDropAim)
    /// The Favourites section. The insertion line here is a **rank**.
    case favourites(SidebarFavouritesAim)
}

/// Where the cursor is inside the Favourites section.
enum SidebarFavouritesAim: Equatable {
    /// The Favourites header body. Add (engine order), not a rank.
    case header
    /// The body of a favourite row.
    case row(index: Int, item: Favourite)
    /// Insertion line among favourite rows — a rank, the exception the tree
    /// planner is forbidden to grow.
    case rank(index: Int)
}

/// What dropping on Favourites would do. Never a `moveFolder`.
enum SidebarFavouritesPlan: Equatable {
    /// `addFavourite` only. Engine sorts until ranked, then appends.
    case add(Favourite)
    /// Notes over the Favourites header. URLs arrive at accept; skip duplicates.
    case addNotes
    /// Add if needed, then `reorderFavourites` so the item lands at `index`
    /// (`toOffset` in SwiftUI `onMove` terms).
    case place(Favourite, at: Int)
    /// Notes over a rank line or a favourite note row. Add each, then place
    /// the first at `index`. URLs arrive at accept.
    case placeNotes(at: Int)
    /// `reorderFavourites(fromOffsets:toOffset:)`. The UI does not sort.
    case reorder(from: Int, to: Int)
    /// Notes land in this folder — the same folder the original row stands for.
    case moveNotes(into: URL)
    case refuse
}

/// The routed decision: tree move, favourites act, or refuse.
///
/// Two targets, two meanings. `SidebarOutlineDrop.plan` is untouched and still
/// the only author of a folder **move**. This router is the only author of a
/// favourite add/reorder, and it is the one that refuses a favourite shortcut
/// over the tree so that drag cannot move a folder on disk.
enum SidebarRoutedPlan: Equatable {
    case move(SidebarDropPlan)
    case favourite(SidebarFavouritesPlan)
    case refuse
}

enum SidebarFavouritesDrop {

    static func route(
        kind: SidebarDragKind,
        target: SidebarDropTarget,
        favourites: [Favourite] = [],
        root: URL? = nil
    ) -> SidebarRoutedPlan {
        switch (kind, target) {
        case (.tag, .tree), (.favourite, .tree):
            // A tag has no folder destination. A favourite is a shortcut, not
            // a folder in the tree: dropping it there must not call moveFolder.
            return .refuse
        case (.folder(let url), .tree(let aim)):
            return .move(SidebarOutlineDrop.plan(payload: .folder(url), aim: aim))
        case (.notes, .tree(let aim)):
            return .move(SidebarOutlineDrop.plan(payload: .notes, aim: aim))
        case (let kind, .favourites(let aim)):
            guard let root else { return .refuse }
            switch plan(kind: kind, aim: aim, favourites: favourites, root: root) {
            case .refuse:
                return .refuse
            case let favouritesPlan:
                return .favourite(favouritesPlan)
            }
        }
    }

    static func plan(
        kind: SidebarDragKind,
        aim: SidebarFavouritesAim,
        favourites: [Favourite],
        root: URL
    ) -> SidebarFavouritesPlan {
        switch (kind, aim) {
        case (.notes, .header):
            return .addNotes
        case (.notes, .rank(let index)):
            return .placeNotes(at: max(0, index))
        case (.notes, .row(let index, let item)):
            switch item {
            case .folder(let path):
                return .moveNotes(into: root.appendingPathComponent(path, isDirectory: true))
            case .note:
                return .placeNotes(at: max(0, index))
            case .tag:
                return .refuse
            }

        case (.folder(let url), .header):
            let item = favourite(fromFolder: url, root: root)
            return favourites.contains(item) ? .refuse : .add(item)
        case (.tag(let name), .header):
            let item = Favourite.tag(name)
            return favourites.contains(item) ? .refuse : .add(item)
        case (.favourite, .header):
            return .refuse

        case (.folder(let url), .rank(let index)):
            return placing(favourite(fromFolder: url, root: root), at: index, in: favourites)
        case (.folder(let url), .row(let index, _)):
            return placing(favourite(fromFolder: url, root: root), at: index, in: favourites)
        case (.tag(let name), .rank(let index)):
            return placing(.tag(name), at: index, in: favourites)
        case (.tag(let name), .row(let index, _)):
            return placing(.tag(name), at: index, in: favourites)

        case (.favourite(let item), .rank(let index)):
            return reordering(item, to: index, in: favourites)
        case (.favourite(let item), .row(let index, _)):
            return reordering(item, to: index, in: favourites)
        }
    }

    static func favourite(fromFolder url: URL, root: URL) -> Favourite {
        .folder(LibraryPaths.relativePath(of: url, to: root))
    }

    /// The tag on a drag pasteboard. Written eagerly by
    /// `pasteboardWriterForItem`, so this read always holds.
    static func tagName(on pasteboard: NSPasteboard) -> String? {
        let type = NSPasteboard.PasteboardType(UTType.shokonotesTag.identifier)
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: type),
               let transfer = try? JSONDecoder().decode(TagTransfer.self, from: data) {
                return transfer.name
            }
        }
        guard let data = pasteboard.data(forType: type),
              let transfer = try? JSONDecoder().decode(TagTransfer.self, from: data)
        else { return nil }
        return transfer.name
    }

    static func favourite(on pasteboard: NSPasteboard) -> Favourite? {
        let type = NSPasteboard.PasteboardType(UTType.shokonotesFavourite.identifier)
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: type),
               let transfer = try? JSONDecoder().decode(FavouriteTransfer.self, from: data) {
                return transfer.item
            }
        }
        guard let data = pasteboard.data(forType: type),
              let transfer = try? JSONDecoder().decode(FavouriteTransfer.self, from: data)
        else { return nil }
        return transfer.item
    }

    private static func placing(
        _ item: Favourite,
        at index: Int,
        in favourites: [Favourite]
    ) -> SidebarFavouritesPlan {
        if let from = favourites.firstIndex(of: item) {
            return reordering(from: from, to: index)
        }
        return .place(item, at: max(0, index))
    }

    private static func reordering(
        _ item: Favourite,
        to index: Int,
        in favourites: [Favourite]
    ) -> SidebarFavouritesPlan {
        guard let from = favourites.firstIndex(of: item) else { return .refuse }
        return reordering(from: from, to: index)
    }

    /// SwiftUI `onMove`: moving to `from` or `from + 1` is a no-op.
    private static func reordering(from: Int, to: Int) -> SidebarFavouritesPlan {
        if to == from || to == from + 1 { return .refuse }
        return .reorder(from: from, to: to)
    }
}
