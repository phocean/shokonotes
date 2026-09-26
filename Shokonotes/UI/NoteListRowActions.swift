import AppKit

/// The note list's `NSTableView` (`NSOutlineView`) and its swipe banner.
///
/// `.swipeActions` is `NSTableViewRowAction`. AppKit tracks the revealed strip
/// as a banner (`NSTableBannerRowData`) against a row index. `rowActionsVisible`
/// can be queried, and set to `false` to hide the actions. Setting it to `true`
/// throws — Apple's `NSTableView.h` contract.
///
/// Only the note list is registered. The folder column is a different
/// `NSOutlineView` (`SidebarOutlineView`) and is never written.
enum NoteListRowActions {
    private static weak var table: NSTableView?

    /// The table `dismiss()` will talk to, if any.
    static var registeredTable: NSTableView? { table }

    static func register(_ table: NSTableView) {
        guard !(table is SidebarOutlineView) else { return }
        self.table = table
    }

    /// Hides the swipe banner if it is showing. Never writes `true`.
    ///
    /// The registered table is the SwiftUI note list, which is view-based.
    /// Assigning `rowActionsVisible` on a cell-based table throws
    /// `NSInternalInconsistencyException`.
    static func dismiss() {
        guard let table, table.rowActionsVisible else { return }
        table.rowActionsVisible = false
    }

    static func reset() {
        table = nil
    }
}

/// View identity for one swipe session of a note-list row. `ForEach` still keys
/// the row on the note URL; this only drops the presented swipe on that row.
struct NoteListSwipeSession: Hashable {
    let url: URL
    let generation: Int
}
