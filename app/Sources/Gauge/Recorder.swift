import AppKit

// The flight recorder: which apps were busiest at each saved moment, and what happened around it
// (sleep, wake, app launches and quits, thermal changes). Everything stays in the local history file.

/// An app at one moment: CPU in percent of one core, like Activity Monitor, and memory in bytes.
struct MomentApp: Hashable, Sendable {
    var name: String
    var cpu: Double
    var memory: Double
}

/// Something that happened on the Mac, kept so the timeline can show what changed and when.
struct RecordedEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case sleep, wake, launch, quit, thermal }
    var date: Date
    var kind: Kind
    /// The app's name for launches and quits, the new state for thermal changes, empty otherwise.
    var detail = ""
    var id: String { "\(date.timeIntervalSince1970)-\(kind.rawValue)-\(detail)" }

    var label: String {
        switch kind {
        case .sleep: "Slept"
        case .wake: "Woke"
        case .launch: "Opened \(detail)"
        case .quit: "Quit \(detail)"
        case .thermal: "Thermal state \(detail.lowercased())"
        }
    }
}

/// One day's long-term readings, for the trends. Nil where Gauge couldn't take the reading.
struct DayRecord: Hashable, Sendable {
    /// Local midnight at the start of the day.
    var day: Date
    var batteryHealth: Double?
    var batteryCycles: Int?
    var diskUsed: Double?
    var diskTotal: Double?
}

/// Averages over the saved samples in a span.
struct SpanStats: Sendable {
    var averageCPU: Double?
    var peakMemory: Double?
    var memoryTotal: Double?
    /// Time covered by saved samples (each row covers 10 seconds).
    var seconds: Double = 0
}

enum Moments {
    static let topCount = 5

    /// The apps worth keeping from one history row: the top five by CPU and the top five by memory.
    /// The two lists usually overlap, so this is between five and ten apps.
    static func top(_ apps: [MomentApp]) -> [MomentApp] {
        let byCPU = apps.filter { $0.cpu >= 0.05 }.sorted { $0.cpu > $1.cpu }.prefix(topCount)
        let byMemory = apps.sorted { $0.memory > $1.memory }.prefix(topCount)
        var seen = Set<String>()
        return (byCPU + byMemory).filter { seen.insert($0.name).inserted }
    }

    /// Compact text for one row: "id:cpu:mem" per app, CPU in tenths of a percent and memory in MiB.
    /// App names are stored once in `app_names` and referenced by id.
    static func encode(_ apps: [(id: Int64, cpu: Double, memory: Double)]) -> String {
        apps.map { "\($0.id):\(Int(($0.cpu * 10).rounded())):\(Int(($0.memory / 1_048_576).rounded()))" }
            .joined(separator: ",")
    }

    static func decode(_ text: String) -> [(id: Int64, cpu: Double, memory: Double)] {
        text.split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":")
            guard parts.count == 3, let id = Int64(parts[0]), let cpu = Double(parts[1]), let mb = Double(parts[2]) else { return nil }
            return (id, cpu / 10, mb * 1_048_576)
        }
    }

    /// Combines several saved moments into one list. CPU is averaged over every moment (an app missing
    /// from a moment wasn't among its busiest, so it counts as near zero); memory is averaged over the
    /// moments the app appears in.
    static func summarize(_ moments: [[MomentApp]]) -> [MomentApp] {
        guard !moments.isEmpty else { return [] }
        var cpu: [String: Double] = [:], memory: [String: (sum: Double, count: Double)] = [:]
        for moment in moments {
            for app in moment {
                cpu[app.name, default: 0] += app.cpu
                memory[app.name, default: (0, 0)].sum += app.memory
                memory[app.name, default: (0, 0)].count += 1
            }
        }
        let n = Double(moments.count)
        return cpu.keys.sorted().map { name in
            let m = memory[name] ?? (0, 1)
            return MomentApp(name: name, cpu: cpu[name, default: 0] / n, memory: m.sum / max(m.count, 1))
        }
    }
}

/// Averages app readings between history rows (one row per five 2-second ticks).
struct MomentAccumulator {
    private var cpu: [String: Double] = [:]
    private var memory: [String: Double] = [:]
    private var count = 0

    mutating func add(_ apps: [AppUsage]) {
        count += 1
        for app in apps {
            cpu[app.name, default: 0] += app.cpu
            memory[app.name, default: 0] += app.memory
        }
    }

    /// The averaged top apps since the last call, then starts over.
    mutating func take() -> [MomentApp] {
        defer { self = MomentAccumulator() }
        guard count > 0 else { return [] }
        let n = Double(count)
        return Moments.top(cpu.map { MomentApp(name: $0.key, cpu: $0.value / n, memory: memory[$0.key, default: 0] / n) })
    }
}

/// Watches for sleep, wake, app launches and quits and thermal changes, and saves each history row's
/// busiest apps. Monitor feeds it readings; it writes to the same local history file.
@MainActor
final class Recorder {
    private var store: HistoryStore?
    private var moment = MomentAccumulator()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var thermal = ProcessInfo.processInfo.thermalState

    func start(store: HistoryStore) {
        guard self.store == nil else { return }
        self.store = store
        let workspace = NSWorkspace.shared.notificationCenter
        let watched: [(Notification.Name, RecordedEvent.Kind)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.didLaunchApplicationNotification, .launch), (NSWorkspace.didTerminateApplicationNotification, .quit),
        ]
        for (name, kind) in watched {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                var detail = ""
                if kind == .launch || kind == .quit {
                    // Only apps with a Dock icon, not helpers, agents and background tools.
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.activationPolicy == .regular, let appName = app.localizedName else { return }
                    detail = appName
                }
                store.addEvent(RecordedEvent(date: Date(), kind: kind, detail: detail))
            }
            observers.append((workspace, observer))
        }
        let center = NotificationCenter.default
        let observer = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        }
        observers.append((center, observer))
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        guard state != thermal else { return }
        thermal = state
        store?.addEvent(RecordedEvent(date: Date(), kind: .thermal, detail: Self.name(state)))
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// Every reading, so a row's top apps are averaged over the same ticks as the row.
    func add(_ r: Reading) {
        moment.add(r.apps)
    }

    /// Called when Monitor saves a history row at `t`.
    func saveMoment(at t: Int) {
        store?.insertMoment(t: t, apps: moment.take())
    }

    /// Battery health and disk use change over weeks, so one row a day is kept (updated through the day).
    func saveDay(_ r: Reading) {
        let used = r.disk.total > 0 ? max(0, r.disk.total - r.disk.available) : nil
        store?.upsertDay(DayRecord(day: Calendar.current.startOfDay(for: r.date),
                                   batteryHealth: r.battery?.health, batteryCycles: r.battery?.cycles,
                                   diskUsed: used, diskTotal: r.disk.total > 0 ? r.disk.total : nil))
    }
}
