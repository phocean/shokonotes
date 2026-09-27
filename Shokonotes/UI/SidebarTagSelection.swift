import AppKit
import Foundation

/// How a source list with two dimensions — one collection, many tags — turns
/// AppKit's proposed selection into exactly one collection plus a tag set.
///
/// Collection rows stay single. Tag rows are multiple. A proposal that mixes
/// both, or that contains only tags, is resolved here so the outline never
/// highlights two folders and never highlights tags without their collection.
enum SidebarTagSelection {

    enum Kind: Equatable {
        case collection(LibraryModel.SidebarItem)
        case tag(String)
        /// A favourite note row. Not a collection; `resolve` ignores it.
        case note

        static func of(_ item: LibraryModel.SidebarItem) -> Kind {
            switch item {
            case .tag(let name): return .tag(name)
            case .note: return .note
            default: return .collection(item)
            }
        }

        var collection: LibraryModel.SidebarItem? {
            if case .collection(let item) = self { return item }
            return nil
        }

        var tag: String? {
            if case .tag(let name) = self { return name }
            return nil
        }
    }

    enum Modifier: Equatable {
        /// Plain click or arrow: AppKit proposes a single row.
        case replace
        /// ⌘-click: AppKit proposes the current set plus or minus one row.
        case toggle
        /// Shift-click or shift-arrow: AppKit proposes the range from the anchor.
        case extend
    }

    struct Resolution: Equatable {
        var collection: LibraryModel.SidebarItem
        var tags: Set<String>
    }

    static func modifier(from flags: NSEvent.ModifierFlags) -> Modifier {
        let bits = flags.intersection([.shift, .command])
        if bits.contains(.shift) { return .extend }
        if bits.contains(.command) { return .toggle }
        return .replace
    }

    static func resolve(
        proposed: [Kind],
        currentCollection: LibraryModel.SidebarItem,
        currentTags: Set<String>,
        modifier: Modifier
    ) -> Resolution {
        let currentCollection = Self.collection(from: currentCollection)
        let collections = proposed.compactMap(\.collection).map { Self.collection(from: $0) }
        let proposedTags = Set(proposed.compactMap(\.tag))
        let shape = Shape.of(collections: collections, tags: proposedTags)

        var collection: LibraryModel.SidebarItem
        var tags: Set<String>

        switch (modifier, shape) {
        case (_, .empty):
            collection = currentCollection
            tags = currentTags

        case (.replace, .collectionOnly):
            collection = pick(collections, current: currentCollection, preferCurrent: true)
            tags = currentTags

        case (.replace, .tagOnly):
            collection = currentCollection
            tags = replacingTags(proposed, current: currentTags, allProposed: proposedTags)

        case (.replace, .mixed):
            collection = pick(collections, current: currentCollection, preferCurrent: true)
            tags = proposedTags

        case (.toggle, .collectionOnly):
            collection = pick(collections, current: currentCollection, preferCurrent: false)
            tags = currentTags

        case (.toggle, .tagOnly):
            collection = currentCollection
            tags = proposedTags

        case (.toggle, .mixed):
            collection = pick(collections, current: currentCollection, preferCurrent: false)
            tags = proposedTags

        case (.extend, .collectionOnly):
            collection = pick(collections, current: currentCollection, preferCurrent: true)
            tags = currentTags

        case (.extend, .tagOnly):
            collection = currentCollection
            tags = proposedTags

        case (.extend, .mixed):
            collection = pick(collections, current: currentCollection, preferCurrent: true)
            tags = proposedTags
        }

        return applyingUntaggedPolicy(
            collection: collection,
            tags: tags,
            shape: shape,
            modifier: modifier,
            collections: collections
        )
    }

    // MARK: - Internals

    private enum Shape {
        case empty
        case collectionOnly
        case tagOnly
        case mixed

        static func of(collections: [LibraryModel.SidebarItem], tags: Set<String>) -> Shape {
            switch (collections.isEmpty, tags.isEmpty) {
            case (true, true): return .empty
            case (true, false): return .tagOnly
            case (false, true): return .collectionOnly
            case (false, false): return .mixed
            }
        }
    }

    /// `.tag` and `.note` are row identity, never a live collection.
    static func collection(from item: LibraryModel.SidebarItem) -> LibraryModel.SidebarItem {
        switch item {
        case .tag, .note: return .all
        default: return item
        }
    }

    /// Plain click / arrow onto a tag: isolate it, or clear it if it was the
    /// only one already selected.
    private static func replacingTags(
        _ proposed: [Kind],
        current: Set<String>,
        allProposed: Set<String>
    ) -> Set<String> {
        if proposed.count == 1, let name = proposed[0].tag {
            return current == [name] ? [] : [name]
        }
        return allProposed
    }

    /// Exactly one collection. `preferCurrent` keeps the one already selected
    /// when it is in the proposal (shift-range); otherwise the last collection
    /// is the one the user moved toward. Turning that off is ⌘-click: switch
    /// to the collection that was not current.
    private static func pick(
        _ collections: [LibraryModel.SidebarItem],
        current: LibraryModel.SidebarItem,
        preferCurrent: Bool
    ) -> LibraryModel.SidebarItem {
        if collections.isEmpty { return current }
        if preferCurrent, collections.contains(where: { sameCollection($0, current) }) {
            return current
        }
        if !preferCurrent, let other = collections.last(where: { !sameCollection($0, current) }) {
            return other
        }
        return collections.last ?? current
    }

    static func sameCollection(_ lhs: LibraryModel.SidebarItem, _ rhs: LibraryModel.SidebarItem) -> Bool {
        if case .project(let left) = lhs, case .project(let right) = rhs {
            return left.standardizedFileURL == right.standardizedFileURL
        }
        return lhs == rhs
    }

    /// Highlight All Notes + the tags when the user picked tags while on
    /// Untagged. Highlight Untagged alone when they picked that collection:
    /// the model clears the tag set in that case.
    private static func applyingUntaggedPolicy(
        collection: LibraryModel.SidebarItem,
        tags: Set<String>,
        shape: Shape,
        modifier: Modifier,
        collections: [LibraryModel.SidebarItem]
    ) -> Resolution {
        guard collection == .untagged, !tags.isEmpty else {
            return Resolution(collection: collection, tags: tags)
        }
        let choseUntaggedCollection: Bool
        switch shape {
        case .collectionOnly, .empty:
            choseUntaggedCollection = true
        case .tagOnly:
            choseUntaggedCollection = false
        case .mixed:
            // ⌘-clicking Untagged while another collection is still in the
            // proposal is choosing that collection, not adding tags.
            choseUntaggedCollection = modifier == .toggle
                && collections.contains { $0 != .untagged }
        }
        if choseUntaggedCollection {
            return Resolution(collection: .untagged, tags: [])
        }
        return Resolution(collection: .all, tags: tags)
    }
}
