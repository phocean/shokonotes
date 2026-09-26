import UserNotifications

/// Home Screen badge via `UNUserNotificationCenter.setBadgeCount`.
/// Badge-only authorization — no alert, no sound, no background mode.
/// The share extension does not set this (no App Group); the host updates
/// on open, become-active, and the 15s poll.
@MainActor
enum InboxBadge {
    private static let showInboxBadgeKey = "showInboxBadge"
    private static var didRequestAuthorization = false

    /// First iOS launch: on. Mac defaults off via `bool(forKey:)`.
    static func applyLaunchDefault() {
        if UserDefaults.standard.object(forKey: showInboxBadgeKey) == nil {
            AppSettings.shared.showInboxBadge = true
        }
    }

    static func refresh() {
        applyLaunchDefault()
        requestAuthorizationOnce()
        let count = AppSettings.shared.showInboxBadge ? LibraryModel.shared.inboxCount : 0
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    private static func requestAuthorizationOnce() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { refresh() }
        }
    }
}
