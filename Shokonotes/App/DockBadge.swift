import AppKit

@MainActor
enum DockBadge {
    /// `badgeLabel` only. No `dockTile.contentView` — that path restored a stale icon.
    /// Ad-hoc signed builds often show nothing; a Developer ID / App Store build can.
    static func refresh() {
        let tile = NSApp.dockTile
        let count = AppSettings.shared.showInboxBadge ? LibraryModel.shared.inboxCount : 0
        tile.badgeLabel = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
        tile.display()
    }
}
