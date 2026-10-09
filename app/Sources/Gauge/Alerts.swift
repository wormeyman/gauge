import AppKit
import Observation
import UserNotifications

/// The notices that can become macOS notifications, each turned on or off in Settings.
enum AlertKind: String, CaseIterable, Identifiable {
    case heavyApp, memoryPressure, busyApp, diskLow
    var id: String { rawValue }

    var title: String {
        switch self {
        case .heavyApp: "An app holds a quarter of memory"
        case .memoryPressure: "Memory pressure stays elevated"
        case .busyApp: "An app pins a CPU core"
        case .diskLow: "The startup disk is almost full"
        }
    }

    var detail: String {
        switch self {
        case .heavyApp: "One app's footprint reaches 25% of this Mac's memory for 30 seconds."
        case .memoryPressure: "macOS is compressing memory to keep up, for 30 seconds or more."
        case .busyApp: "One app uses more than 90% of a core for 30 seconds."
        case .diskLow: "Less than 10% of the startup disk is free."
        }
    }

    /// The metric whose colour marks this kind in Settings.
    var metric: String {
        switch self {
        case .heavyApp, .memoryPressure: "Memory"
        case .busyApp: "CPU"
        case .diskLow: "Disk"
        }
    }

    var defaultsKey: String { "notify.\(rawValue)" }

    /// On unless turned off in Settings.
    var isOn: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
}

/// Decides which notices become macOS notifications. A notice qualifies once it is an alert and has held
/// for 30 seconds; it is sent once while it lasts, and not again for an hour after it was last sent.
struct AlertSchedule {
    static let cooldown: TimeInterval = 3600

    private(set) var sent: [String: Date] = [:]
    /// Notices that qualified on the previous check, so an ongoing one is only sent when it starts.
    private var active: Set<String> = []

    mutating func due(_ notices: [Notice], now: Date) -> [Notice] {
        let ready = notices.filter { $0.alert != nil && Notices.sustained($0.since, now: now) }
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

    /// Whether notifications can be sent from this build at all.
    var isAvailable: Bool { center != nil }

    /// Posts a sample so the user can see what Gauge's notifications look like.
    func sendTest() {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Notifications are on"
        content.body = "Gauge will tell you when an app holds a lot of memory or something else needs a look."
        content.userInfo = ["target": "Overview"]
        center.add(UNNotificationRequest(identifier: "test", content: content, trigger: nil))
    }

    func consider(_ notices: [Notice], now: Date) {
        guard enabled, let center else { return }
        let wanted = notices.filter { $0.alert?.isOn == true }
        for notice in schedule.due(wanted, now: now) {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.threadIdentifier = notice.tag
            content.userInfo = ["target": notice.target]
            center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
        }
    }

    // While Gauge is in front its own notices are on screen, so only file the notification.
    // The test from Settings is always sent with Gauge in front, so it shows as a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        notification.request.identifier == "test" ? [.banner, .list] : [.list]
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
