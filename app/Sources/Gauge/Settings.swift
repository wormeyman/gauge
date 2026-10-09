import ServiceManagement
import SwiftUI
import UserNotifications

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", notifications = "Notifications", history = "History", updates = "Updates", privacy = "Privacy"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .history: "clock.arrow.circlepath"
        case .updates: "arrow.down.circle"
        case .privacy: "lock"
        }
    }
}

/// Settings in the instrument style: a rail of panes, and hairline rows with monospaced values.
struct SettingsView: View {
    @ObservedObject var updates: Updates
    @Environment(Monitor.self) private var monitor
    @AppStorage("settingsPane") private var pane = SettingsPane.general

    var body: some View {
        HStack(spacing: 0) {
            rail
            Hairline(axis: .vertical)
            ScrollView {
                Group {
                    switch pane {
                    case .general: GeneralPane(monitor: monitor)
                    case .notifications: NotificationsPane(notifier: .shared)
                    case .history: HistoryPane(monitor: monitor)
                    case .updates: UpdatesPane(updates: updates)
                    case .privacy: PrivacyPane()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 720, height: 620)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .containerBackground(Theme.bg, for: .window)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle("Gauge Settings")
        .toolbar(removing: .title)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { item in
                RailButton(pane: item, selected: item == pane) { pane = item }
            }
            Spacer()
            HStack(spacing: 8) {
                GaugeMark(size: 16)
                Text("Gauge \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(width: 188)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.raise.opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

private struct RailButton: View {
    var pane: SettingsPane
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol).font(.system(size: 13)).frame(width: 18)
                Text(pane.rawValue).font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.ink : Theme.soft)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.raise2 : hovering ? Theme.raise : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.line2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Building blocks

/// A pane's title, a one-line summary, and a live readout on the right.
private struct PaneHeader<Readout: View>: View {
    var title: String
    var summary: String
    @ViewBuilder var readout: Readout

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                readout
            }
            Hairline()
        }
    }
}

extension PaneHeader where Readout == EmptyView {
    init(title: String, summary: String) {
        self.init(title: title, summary: summary) { EmptyView() }
    }
}

/// A setting: title and explanation on the left, its control on the right, a hairline below.
private struct Row<Control: View>: View {
    var title: String
    var detail: String?
    var dot: Color?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 } }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 13))
                        if let detail {
                            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 12)
                control.fixedSize()
            }
            .padding(.vertical, 13)
            Hairline()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small heading between groups of rows.
private struct GroupLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 26).padding(.bottom, 2)
    }
}

/// A note under a group of rows.
private struct Note: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
    }
}

/// A monospaced value, as on the instrument readouts.
private struct Value: View {
    var text: String
    var tone: Color = Theme.ink
    var body: some View { Text(text).font(Theme.mono(12)).foregroundStyle(tone).lineLimit(1).textSelection(.enabled) }
}

/// A status lamp with a label: orange when it needs attention.
private struct Lamp: View {
    var text: String
    var lit: Bool
    var attention = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(attention ? Theme.signal : lit ? Theme.ink : .clear)
                .strokeBorder(attention ? Theme.signal : lit ? Theme.ink : Theme.faint, lineWidth: 1)
                .frame(width: 7, height: 7)
            Text(text).font(Theme.mono(11.5)).foregroundStyle(attention ? Theme.signal : lit ? Theme.ink : Theme.muted)
        }
    }
}

/// A flat switch: ink when on, a hairline track when off.
struct InstrumentSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        var configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Theme.ink : Theme.raise2)
                    Capsule().strokeBorder(on ? Theme.ink : Theme.line2)
                    Circle().fill(on ? Theme.bg : Theme.muted).frame(width: 14, height: 14).padding(3)
                }
                .frame(width: 36, height: 20)
                .animation(.smooth(duration: 0.18), value: on)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.35)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

private extension Toggle where Label == Text {
    /// A switch whose title is carried by its row; the label is for accessibility.
    init(row title: String, isOn: Binding<Bool>) {
        self.init(title, isOn: isOn)
    }
}

// MARK: General

private struct GeneralPane: View {
    var monitor: Monitor
    @AppStorage(AppDelegate.menuBarKey) private var showInMenuBar = true
    @State private var login = LoginItem()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "General", summary: "Where Gauge lives, and when it starts.")
            Row(title: "Show Gauge in the menu bar",
                detail: "CPU in the menu bar, all six vitals a click away. While it's on, closing the window keeps Gauge running.") {
                Toggle(row: "Show Gauge in the menu bar", isOn: $showInMenuBar).toggleStyle(InstrumentSwitch())
            }
            Row(title: "Menu bar reading", detail: "What sits in the menu bar right now.") {
                let cpu = monitor.cpuNow.map { String(format: "%.0f%%", $0) } ?? "–"
                Text("\(Image(systemName: "gauge.with.needle")) \(cpu)")
                    .font(Theme.mono(12)).monospacedDigit()
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise2))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2))
                    .opacity(showInMenuBar ? 1 : 0.35)
            }
            Row(title: "Open Gauge at login",
                detail: login.needsApproval ? "Waiting for approval in System Settings › General › Login Items."
                                            : "Keeps history and notifications going from the moment you log in.") {
                Toggle(row: "Open Gauge at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .toggleStyle(InstrumentSwitch())
                    .disabled(!login.isAvailable)
            }
            if let error = login.error { Note(text: error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}

/// Gauge as a login item, through ServiceManagement.
@MainActor @Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "macOS didn't accept the change: \(error.localizedDescription)"
        }
        refresh()
    }
}

// MARK: Notifications

private struct NotificationsPane: View {
    var notifier: Notifier
    @AppStorage(Notifier.enabledKey) private var enabled = false
    @AppStorage(AlertKind.heavyApp.defaultsKey) private var heavyApp = true
    @AppStorage(AlertKind.memoryPressure.defaultsKey) private var memoryPressure = true
    @AppStorage(AlertKind.busyApp.defaultsKey) private var busyApp = true
    @AppStorage(AlertKind.diskLow.defaultsKey) private var diskLow = true

    private var blocked: Bool { notifier.status == .denied }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Notifications", summary: "A tap on the shoulder when something on this Mac needs a look.") {
                Lamp(text: blocked && enabled ? "Blocked" : enabled ? "On" : "Off", lit: enabled, attention: blocked && enabled)
            }
            Row(title: "Send notifications", detail: "Each alert is sent once while it lasts, and at most once an hour. Click one to open its page.") {
                Toggle(row: "Send notifications", isOn: $enabled).toggleStyle(InstrumentSwitch())
                    .disabled(!notifier.isAvailable)
            }
            if enabled {
                Row(title: "macOS permission", detail: permissionDetail) {
                    HStack(spacing: 12) {
                        if blocked {
                            Button("Open System Settings", action: openSystemSettings).buttonStyle(QuietButtonStyle())
                        }
                        Lamp(text: permissionText, lit: notifier.status == .authorized || notifier.status == .provisional,
                             attention: blocked)
                    }
                }
            }

            GroupLabel(text: "Notify me when")
            kind(.heavyApp, $heavyApp)
            kind(.memoryPressure, $memoryPressure)
            kind(.busyApp, $busyApp)
            kind(.diskLow, $diskLow)

            HStack(spacing: 14) {
                Button("Send a Test Notification") { notifier.sendTest() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!enabled || blocked)
                Text("Check that notifications reach you, and see how they look.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
        }
        .animation(.smooth(duration: 0.2), value: enabled)
        .onChange(of: enabled) { _, on in if on { notifier.requestPermission() } }
        .onAppear { notifier.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifier.refreshStatus()
        }
    }

    private func kind(_ kind: AlertKind, _ isOn: Binding<Bool>) -> some View {
        Row(title: kind.title, detail: kind.detail, dot: Theme.tone(kind.metric)) {
            Toggle(row: kind.title, isOn: isOn).toggleStyle(InstrumentSwitch()).disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.55)
    }

    private var permissionText: String {
        switch notifier.status {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Turned off"
        case .notDetermined: "Not asked yet"
        default: "Checking"
        }
    }

    private var permissionDetail: String {
        blocked ? "Notifications for Gauge are turned off in System Settings, so nothing will appear."
                : "Banners and Notification Centre, as set in System Settings › Notifications."
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: History

private struct HistoryPane: View {
    var monitor: Monitor
    @AppStorage("historyRetentionDays") private var days = 30
    @State private var confirmClear = false
    @State private var size = HistoryStore.sizeOnDisk

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "History", summary: "Readings averaged every 10 seconds, kept on this Mac.") {
                Value(text: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), tone: Theme.soft)
            }
            Row(title: "Keep history for", detail: "Older readings are removed automatically.") {
                Segmented(options: [(1, "1 day", nil), (7, "7 days", nil), (30, "30 days", nil), (90, "90 days", nil)],
                          selection: $days, accessibilityName: "Keep history for")
            }
            Row(title: "Oldest reading") {
                Value(text: monitor.oldestSample.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet",
                      tone: Theme.soft)
            }
            Row(title: "Stored at", detail: "~/Library/Application Support/Gauge") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.file]) }
                    .buttonStyle(QuietButtonStyle())
            }
            Row(title: "Clear history", detail: "Removes every saved reading from this Mac. Live readings carry on.") {
                Button("Clear History…") { confirmClear = true }.buttonStyle(QuietButtonStyle())
            }
        }
        .onChange(of: days) { _, new in
            monitor.store.prune(keepingDays: new)
            monitor.reloadHistory()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { size = HistoryStore.sizeOnDisk }
        }
        .onAppear { size = HistoryStore.sizeOnDisk }
        .confirmationDialog("Clear all saved history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                monitor.clearHistory()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { size = HistoryStore.sizeOnDisk }
            }
        } message: {
            Text("This removes every saved reading from this Mac. It can't be undone.")
        }
    }
}

// MARK: Updates

private struct UpdatesPane: View {
    @ObservedObject var updates: Updates

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Updates", summary: "Signed updates, checked against one small feed.") {
                Value(text: updates.version, tone: Theme.soft)
            }
            Row(title: "Check for updates automatically", detail: "Once a day, in the background.") {
                Toggle(row: "Check for updates automatically",
                       isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                    .toggleStyle(InstrumentSwitch())
                    .disabled(!updates.isAvailable)
            }
            Row(title: "Installed version") { Value(text: updates.version, tone: Theme.soft) }
            Row(title: "Last checked") {
                HStack(spacing: 14) {
                    Value(text: updates.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet",
                          tone: Theme.soft)
                    Button("Check Now") { updates.checkNow() }.buttonStyle(QuietButtonStyle()).disabled(!updates.canCheck)
                }
            }
            Note(text: "Checking downloads a small feed from gauge.alex.codes. Gauge sends no information about your Mac, and every update is signed and verified before it installs.")
        }
    }
}

// MARK: Privacy

private struct PrivacyPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Privacy", summary: "Gauge reads system counters locally. Nothing leaves this Mac.")
            Row(title: "History", detail: "~/Library/Application Support/Gauge") { Lamp(text: "On this Mac", lit: true) }
            Row(title: "Network requests", detail: "The update check, if it's on.") { Lamp(text: "Updates only", lit: true) }
            Row(title: "Analytics and telemetry") { Lamp(text: "None", lit: false) }
            Row(title: "Account and sync") { Lamp(text: "None", lit: false) }
            Row(title: "Administrator access", detail: "Other users' processes and temperature sensors stay unread.") {
                Lamp(text: "Not needed", lit: false)
            }
        }
    }
}
