import AppKit
import Foundation
import UniformTypeIdentifiers

/// What is being dragged over the sidebar. A folder carries its identity: the
/// drag is in-process and the session records its source, because the payload
/// itself arrives too late to shape the feedback while the mouse is still down.
enum SidebarDragPayload: Equatable {
    case folder(URL)
    case notes
}

/// The row the cursor is over, translated out of AppKit's geometry so the
/// decision below can be taken — and tested — without an `NSOutlineView`.
struct SidebarDropAim: Equatable {
    /// The folder this row stands for as a destination: a folder row's own URL,
    /// the library root for the Inbox row. Nil for a row that stands for no
    /// folder at all — All Notes, Untagged, Trash, a tag, a section header.
    let rowDestination: URL?
    /// The folder this row's siblings share, so an insertion line drawn among
    /// them reads as "at this level": the library root for a first-level folder.
    /// Nil when the row is not a folder row and has no level to speak of.
    let siblingParent: URL?
    /// The cursor is within a few points of the row's top or bottom edge.
    let onEdge: Bool

    init(rowDestination: URL?, siblingParent: URL?, onEdge: Bool) {
        self.rowDestination = rowDestination
        self.siblingParent = siblingParent
        self.onEdge = onEdge
    }

    /// Over no row at all — above the first one, past the last one, or on a
    /// section header.
    static let nowhere = SidebarDropAim(rowDestination: nil, siblingParent: nil, onEdge: false)
}

/// Where the drag would land, and how AppKit is to say so.
enum SidebarDropPlan: Equatable {
    /// Highlight the whole row: the dragged item goes *inside* `destination`.
    case onRow(destination: URL)
    /// Draw the insertion line among the children of `parent`, which AppKit
    /// indents to that parent's child level.
    ///
    /// The line never says a *rank*. Sibling folders are sorted by name on
    /// disk and no display order is persisted, so there is no order to choose:
    /// the line says a **level**, and nothing else.
    case between(parent: URL)
    /// Do not light up at all.
    case refuse
}

/// The sidebar's drop decision, and it alone: given what is dragged and where
/// the cursor is, what should light up and where would the item go.
///
/// Structural refusals are settled here, before the mouse is released, from
/// `FolderActions.plannedDestination`, which decides without touching a byte of
/// content. A drop the engine would refuse on structure never lights up.
///
/// `FolderMoveError.nameExists` is the one exception, and it is deliberate: a
/// collision is invisible to the eye, so it is accepted for display, the engine
/// refuses it, and the human is told why. That was the behaviour of the
/// retired `SidebarDropDelegate` and it does not change here.
enum SidebarOutlineDrop {

    static func plan(
        payload: SidebarDragPayload,
        aim: SidebarDropAim,
        validate: (URL, URL) -> FolderMoveError? = SidebarOutlineDrop.structuralVerdict
    ) -> SidebarDropPlan {
        switch payload {
        case .notes:
            // A note has no level to choose, so an edge aim is retargeted onto
            // the row itself: notes land *in* a folder or in the Inbox, never
            // between two folders.
            guard let destination = aim.rowDestination else { return .refuse }
            return .onRow(destination: destination)

        case .folder(let source):
            if aim.onEdge, let parent = aim.siblingParent {
                return welcome(source, in: parent, validate)
                    ? .between(parent: parent)
                    : .refuse
            }
            guard let destination = aim.rowDestination else { return .refuse }
            return welcome(source, in: destination, validate)
                ? .onRow(destination: destination)
                : .refuse
        }
    }

    /// Nil when the move is possible, otherwise the refusal — with no disk
    /// change either way.
    static func structuralVerdict(moving source: URL, into destination: URL) -> FolderMoveError? {
        do {
            _ = try FolderActions.plannedDestination(moving: source, into: destination)
            return nil
        } catch let error as FolderMoveError {
            return error
        } catch {
            return .invalidDestination
        }
    }

    private static func welcome(
        _ source: URL,
        in destination: URL,
        _ validate: (URL, URL) -> FolderMoveError?
    ) -> Bool {
        switch validate(source, destination) {
        case .none, .some(.nameExists):
            return true
        case .some:
            return false
        }
    }

    // MARK: - Reading what is being dragged

    /// One `NoteTransfer` payload. The single decodable step, shared by the
    /// synchronous pasteboard read and the asynchronous provider fallback — so
    /// what a test proves here holds for both.
    static func noteURL(from payload: Data) -> URL? {
        (try? JSONDecoder().decode(NoteTransfer.self, from: payload))?.url
    }

    /// The same, in bulk. Undecodable payloads are dropped, not substituted.
    static func noteURLs(from payloads: [Data]) -> [URL] {
        payloads.compactMap(noteURL(from:))
    }

    /// The folder on a drag pasteboard. Written eagerly by
    /// `pasteboardWriterForItem`, so this read always holds.
    static func folderURL(on pasteboard: NSPasteboard) -> URL? {
        let type = NSPasteboard.PasteboardType(UTType.shokonotesFolder.identifier)
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: type),
               let transfer = try? JSONDecoder().decode(FolderTransfer.self, from: data) {
                return transfer.url
            }
        }
        guard let data = pasteboard.data(forType: type),
              let transfer = try? JSONDecoder().decode(FolderTransfer.self, from: data)
        else { return nil }
        return transfer.url
    }

    /// The notes on a drag pasteboard, decoded from the same `NoteTransfer`
    /// payload the note list writes.
    ///
    /// This is the first path tried, and the one that should normally answer:
    /// it is synchronous, so the move happens inside `acceptDrop`. It can come
    /// back empty, though, and that is not a malformed drag. The note list
    /// drags through SwiftUI's `.draggable(NoteTransfer(...))`, whose
    /// `CodableRepresentation` registers its data **lazily**; a promised type
    /// satisfies `availableType(from:)`, which is all the row needed to light
    /// up, without `data(forType:)` having anything to hand over yet. When that
    /// happens, `loadNoteURLs(from:in:completion:)` is the fallback.
    static func noteURLs(on pasteboard: NSPasteboard) -> [URL] {
        let type = NSPasteboard.PasteboardType(UTType.shokonotesNote.identifier)
        let perItem = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: type) }
        let urls = noteURLs(from: perItem)
        if !urls.isEmpty { return urls }
        guard let data = pasteboard.data(forType: type) else { return [] }
        return noteURLs(from: [data])
    }

    /// The asynchronous fallback: ask the drag's `NSItemProvider`s to
    /// materialize what the pasteboard would not hand over synchronously.
    ///
    /// A note move has no reason to be synchronous — nothing about the drop
    /// depends on its result — so `acceptDrop` accepts and the move lands on the
    /// main actor once the bytes are in. This is the mechanism the retired
    /// `NoteDrop.perform` used on the SwiftUI `DropInfo` side, kept because the
    /// problem it solved is the same one.
    ///
    /// `completion` is called on the main queue, with whatever decoded — an
    /// empty array included, which means the drag carried no note reference
    /// after all.
    @MainActor
    static func loadNoteURLs(
        from info: NSDraggingInfo,
        in view: NSView,
        completion: @escaping @MainActor ([URL]) -> Void
    ) -> Bool {
        var providers: [NSItemProvider] = []
        info.enumerateDraggingItems(
            options: [], for: view, classes: [NSItemProvider.self], searchOptions: [:]
        ) { item, _, _ in
            guard let provider = item.item as? NSItemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.shokonotesNote.identifier)
            else { return }
            providers.append(provider)
        }
        guard !providers.isEmpty else { return false }

        let collector = NoteURLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadDataRepresentation(for: .shokonotesNote) { data, _ in
                defer { group.leave() }
                guard let data, let url = noteURL(from: data) else { return }
                collector.add(url)
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(collector.urls) }
        }
        return true
    }
}

/// Collects URLs off whatever queue each provider answers on. `NSItemProvider`
/// promises no ordering and no single thread, so the accumulation is locked.
private final class NoteURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func add(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(url)
    }
}
