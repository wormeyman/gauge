import SwiftUI

@main
struct GaugeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = Monitor()
    @StateObject private var updates = Updates()
    @AppStorage(AppDelegate.menuBarKey) private var showInMenuBar = true

    var body: some Scene {
        Window("Gauge", id: "main") {
            ContentView()
                .environment(monitor)
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.dark)
                .containerBackground(Theme.bg, for: .window)
                .task { Snapshot.monitor = monitor; Notifier.shared.monitor = monitor; monitor.start() }
        }
        .defaultSize(width: 1280, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesCommand(updates: updates) }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("Export History…") { NotificationCenter.default.post(name: .gaugeExport, object: nil) }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarPanel(monitor: monitor)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(updates: updates)
                .environment(monitor)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let menuBarKey = "showInMenuBar"

    /// With the menu bar extra on, closing the window leaves Gauge running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: Self.menuBarKey) as? Bool == false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Notifier.shared.activate()
            Snapshot.scheduleIfRequested()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var updates: Updates
    @Environment(Monitor.self) private var monitor
    @AppStorage("historyRetentionDays") private var days = 30
    @AppStorage(AppDelegate.menuBarKey) private var showInMenuBar = true
    @State private var confirmClear = false
    @State private var size = HistoryStore.sizeOnDisk

    var body: some View {
        Form {
            Section {
                Picker("Keep history for", selection: $days) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                LabeledContent("Stored at") {
                    Text("~/Library/Application Support/Gauge").font(Theme.mono(11.5)).textSelection(.enabled)
                }
                LabeledContent("Size on disk", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.file]) }
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("History")
            } footer: {
                Text("History stays on your Mac. Readings are averaged every 10 seconds and older entries are removed automatically.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show Gauge in the menu bar", isOn: $showInMenuBar)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Shows CPU in the menu bar, with all six vitals a click away. While it's on, closing the window keeps Gauge running.")
                    .foregroundStyle(.secondary)
            }
            NotificationSettings(notifier: .shared)
            UpdatesSettings(updates: updates)
            Section("Privacy") {
                Text("Gauge reads system counters locally. It has no analytics, no account and no sync. Its only network request is the update check above.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: days) { _, new in
            monitor.store.prune(keepingDays: new)
            monitor.reloadHistory()
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

/// Settings section for notifications.
struct NotificationSettings: View {
    var notifier: Notifier
    @AppStorage(Notifier.enabledKey) private var enabled = false

    var body: some View {
        Section {
            Toggle("Notify me when something needs a look", isOn: $enabled)
            if enabled && notifier.status == .denied {
                HStack {
                    Text("Notifications for Gauge are turned off in System Settings.").foregroundStyle(Theme.signal)
                    Spacer()
                    Button("Open System Settings") {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Sends a notification when an app holds a quarter of your memory or pins a core, memory pressure stays elevated, or the startup disk is almost full. Each is sent once while it lasts, and at most once an hour.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: enabled) { _, on in if on { notifier.requestPermission() } }
        .onAppear { notifier.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifier.refreshStatus()
        }
    }
}
