import SwiftUI
import Sparkle

/// Owns Sparkle's updater. Update checks are the only network request Gauge makes: Sparkle asks the user
/// before checking automatically, sends no system profile, and verifies every update's EdDSA signature.
@MainActor
final class Updates: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    init() {
        // Snapshot runs and unbundled debug runs don't start the updater.
        let isApp = Bundle.main.bundleURL.pathExtension == "app"
        let start = isApp && Snapshot.folder == nil
        controller = start ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkNow() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }
}

/// "Check for Updates…" in the app menu.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updates: Updates
    var body: some View {
        Button("Check for Updates…") { updates.checkNow() }
            .disabled(!updates.canCheck)
    }
}
