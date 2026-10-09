import AppKit
import Observation
import UserNotifications

/// Decides which notices become macOS notifications. A notice qualifies once it is hot and has held
/// for 30 seconds; it is sent once while it lasts, and not again for an hour after it was last sent.
struct AlertSchedule {
    static let cooldown: TimeInterval = 3600

    private(set) var sent: [String: Date] = [:]
    /// Notices that qualified on the previous check, so an ongoing one is only sent when it starts.
    private var active: Set<String> = []

    mutating func due(_ notices: [Notice], now: Date) -> [Notice] {
        let ready = notices.filter { $0.hot && Notices.sustained($0.since, now: now) }
        defer { active = Set(ready.map(\.id)) }
        var list: [Notice] = []
        for notice in ready where !active.contains(notice.id) {
            if let last = sent[notice.id], now.timeIntervalSince(last) < Self.cooldown { continue }
            sent[notice.id] = now
            list.append(notice)
        }
        return list
    }
}

/// Posts notices that need attention as macOS notifications while they're turned on in Settings.
/// Clicking one opens Gauge on the notice's page.
@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let enabledKey = "notifications"

    weak var monitor: Monitor?
    /// Opens the main window; set by a view that can, since the window may be closed.
    @ObservationIgnored var openMain: (() -> Void)?
    /// Whether macOS lets Gauge show notifications. Nil until checked.
    private(set) var status: UNAuthorizationStatus?
    @ObservationIgnored private var schedule = AlertSchedule()

    /// The notification center needs an app bundle; `swift run` and tests don't have one.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func activate() {
        center?.delegate = self
        refreshStatus()
    }

    func refreshStatus() {
        guard let center else { return }
        Task {
            let status = await center.notificationSettings().authorizationStatus
            self.status = status
        }
    }

    /// Asks macOS for permission the first time notifications are turned on.
    func requestPermission() {
        guard let center else { return }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            refreshStatus()
        }
    }

    func consider(_ notices: [Notice], now: Date) {
        guard enabled, let center else { return }
        for notice in schedule.due(notices, now: now) {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.threadIdentifier = notice.tag
            content.userInfo = ["target": notice.target]
            center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
        }
    }

    // While Gauge is in front its own notices are on screen, so only file the notification.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let target = response.notification.request.content.userInfo["target"] as? String ?? "Overview"
        await MainActor.run {
            openMain?()
            NSApp.activate()
            monitor?.requestedPage = target
        }
    }
}
