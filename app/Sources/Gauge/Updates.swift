import SwiftUI
import Sparkle

/// Owns Sparkle's updater. Update checks are the only network request Gauge makes: Sparkle asks the user
/// before checking automatically, sends no system profile, and verifies every update's EdDSA signature.
@MainActor
final class Updates: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    /// Sparkle holds its delegate weakly.
    private let delegate = UpdateRequestLog()
    @Published private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    init() {
        // Snapshot runs and unbundled debug runs don't start the updater.
        let isApp = Bundle.main.bundleURL.pathExtension == "app"
        let start = isApp && Snapshot.folder == nil
        controller = start ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil) : nil
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

/// Records the requests Sparkle actually makes in NetworkLog. Scheduling a check isn't a request, and a check
/// can stop before the feed is fetched, so the feed is counted once it loaded or failed to download.
final class UpdateRequestLog: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let url = updater.feedURL
        MainActor.assumeIsolated { NetworkLog.shared.record("Update feed", url: url) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // SUAppcastError: the feed request was made but didn't complete, such as when offline.
        guard let error = error as NSError?, error.domain == SUSparkleErrorDomain, error.code == Int(SUError.appcastError.rawValue) else { return }
        let url = updater.feedURL
        MainActor.assumeIsolated { NetworkLog.shared.record("Update feed (failed)", url: url) }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let url = request.url
        MainActor.assumeIsolated { NetworkLog.shared.record("Update download", url: url) }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        // Gauge's feed carries its notes inline; a separate notes link would be one more request.
        if let url = updateItem.releaseNotesURL {
            MainActor.assumeIsolated { NetworkLog.shared.record("Release notes", url: url) }
        }
        return true
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

/// Settings section for updates.
struct UpdatesSettings: View {
    @ObservedObject var updates: Updates

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks },
                                                                     set: { updates.automaticallyChecks = $0 }))
                .disabled(!updates.isAvailable)
            LabeledContent("Version", value: updates.version)
            HStack {
                Text(updates.lastChecked.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not checked yet")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updates.checkNow() }.disabled(!updates.canCheck)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Checking downloads a small feed from gauge.alex.codes. Gauge sends no information about your Mac, and every update is signed and verified before it installs.")
                .foregroundStyle(.secondary)
        }
    }
}
