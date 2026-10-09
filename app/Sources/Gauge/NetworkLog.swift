import SwiftUI

/// Every network request Gauge makes this session, so the status bar and privacy sheet can show them.
/// The only requests Gauge makes are Sparkle's: the update feed, and an update's download if one is installed.
/// Sparkle's delegate (in Updates.swift) records each one when it happens.
@MainActor @Observable
final class NetworkLog {
    static let shared = NetworkLog()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var date: Date
        var what: String
        var url: String
    }

    private(set) var entries: [Entry] = []

    func record(_ what: String, url: URL?) {
        entries.append(Entry(date: Date(), what: what, url: url?.absoluteString ?? "unknown address"))
    }

    var summary: String { "Network: \(entries.count) request\(entries.count == 1 ? "" : "s")" }
}

/// The privacy sheet's text, with the session's network requests listed underneath.
struct PrivacyDetails: View {
    var log = NetworkLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gauge reads system counters on this Mac, such as CPU load, memory, disk and network activity. Readings are saved to a history file in ~/Library/Application Support/Gauge and are never uploaded. Gauge has no analytics and no account. Its only network request is the optional update check, which downloads a small feed and sends nothing about your Mac. You can change how long history is kept, clear it, or turn off update checks in Settings.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.soft).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Network requests this session").font(.system(size: 12.5, weight: .medium))
                Hairline()
                if log.entries.isEmpty {
                    Text("None. Gauge hasn't contacted anything since it opened.")
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                } else {
                    ForEach(log.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.date.formatted(date: .omitted, time: .standard)).foregroundStyle(Theme.muted)
                            Text(entry.what).foregroundStyle(Theme.soft)
                            Text(entry.url).foregroundStyle(Theme.ink).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                        .font(Theme.mono(11.5))
                    }
                }
                Text("Local tools reading Gauge use a socket on this Mac, not the network, so they aren't counted here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
