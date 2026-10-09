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
                .task { Snapshot.monitor = monitor; Notifier.shared.monitor = monitor; monitor.start(); LocalAPI.shared.attach(monitor) }
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
