import Foundation

/// Snapshot aid only: with GAUGE_SNAPSHOT_DEMO=1 and GAUGE_SNAPSHOT_SHEET=Timeline, the timeline is
/// rendered from made-up readings so a fresh install has something to show. The readings go into a
/// throwaway store in the temporary folder, never the real history file, and the page labels itself
/// "Sample data". Nothing in the running app calls this.
enum TimelineDemo {
    static var requested: Bool { ProcessInfo.processInfo.environment["GAUGE_SNAPSHOT_DEMO"] == "1" }

    static func store(now: Date = Date()) -> HistoryStore {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("GaugeDemo-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        let store = HistoryStore(file: file)
        seed(store, now: now)
        return store
    }

    /// Which apps are open when (hours before now), and roughly what they use.
    private struct App { var name: String; var open: ClosedRange<Double>; var cpu: Double; var memory: Double }

    private static func seed(_ store: HistoryStore, now: Date) {
        var random = SplitMix(seed: 7)
        let gib = 1_073_741_824.0
        let asleep = 9.0...17.0
        let apps = [
            App(name: "Safari", open: 0...26, cpu: 4, memory: 1.6 * gib),
            App(name: "Mail", open: 0...26, cpu: 0.6, memory: 0.4 * gib),
            App(name: "WindowServer", open: 0...26, cpu: 6, memory: 0.9 * gib),
            App(name: "Final Cut Pro", open: 19.9...21.6, cpu: 9, memory: 3.1 * gib),
            App(name: "Slack", open: 0...8.8, cpu: 1.5, memory: 0.8 * gib),
            App(name: "Music", open: 3.0...8.7, cpu: 1.2, memory: 0.35 * gib),
            App(name: "Xcode", open: 0...6.0, cpu: 3, memory: 2.4 * gib),
            App(name: "Figma", open: 2.1...4.6, cpu: 5, memory: 1.2 * gib),
        ]
        // Bursts: (hours ago, minutes long, app, CPU at peak).
        let bursts: [(Double, Double, String, Double)] = [
            (21.2, 26, "Final Cut Pro", 640), (5.1, 9, "Xcode", 520), (3.3, 7, "Xcode", 470),
            (1.6, 11, "Xcode", 560), (0.45, 6, "Xcode", 430),
        ]
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        var hoursAgo = 26.0
        while hoursAgo > 0 {
            defer { hoursAgo -= 10.0 / 3600 }
            if asleep.contains(hoursAgo) { continue }
            var moment: [MomentApp] = []
            for app in apps where app.open.contains(hoursAgo) {
                var cpu = app.cpu * (0.6 + random.next() * 0.8)
                for burst in bursts where burst.2 == app.name && hoursAgo <= burst.0 && hoursAgo >= burst.0 - burst.1 / 60 {
                    cpu = burst.3 * (0.75 + random.next() * 0.25)
                }
                moment.append(MomentApp(name: app.name, cpu: cpu, memory: app.memory * (0.92 + random.next() * 0.16)))
            }
            moment.append(MomentApp(name: "macOS", cpu: 3 + random.next() * 2, memory: 2.2 * gib))
            // Whole-Mac CPU is a share of 10 cores; memory adds wired and compressed pages on top of apps.
            let cpu = min(100, moment.map(\.cpu).reduce(0, +) / 10 + random.next() * 2)
            let memory = min(15.5 * gib, moment.map(\.memory).reduce(0, +) + 2.8 * gib)
            let t = Int(ago(hoursAgo).timeIntervalSince1970)
            store.insert(.init(t: t, cpu: cpu, memory: memory, memoryTotal: 16 * gib, gpu: cpu * 0.3,
                               down: 40_000 + random.next() * 200_000, up: 8_000, diskRead: 0, diskWrite: 0, battery: nil))
            store.insertMoment(t: t, apps: Moments.top(moment))
        }

        var events = [RecordedEvent(date: ago(17), kind: .sleep), RecordedEvent(date: ago(9), kind: .wake),
                      RecordedEvent(date: ago(21.2), kind: .thermal, detail: "Fair"),
                      RecordedEvent(date: ago(20.7), kind: .thermal, detail: "Nominal")]
        for app in apps where app.open.upperBound < 26 {
            events.append(RecordedEvent(date: ago(app.open.upperBound), kind: .launch, detail: app.name))
            if app.open.lowerBound > 0 { events.append(RecordedEvent(date: ago(app.open.lowerBound), kind: .quit, detail: app.name)) }
        }
        events.forEach(store.addEvent)

        // A week of hourly CPU time, so "busiest app" has something to add up.
        for hour in 0..<(7 * 24) {
            let date = ago(Double(hour))
            store.addCPUTime(["Xcode": 60 + random.next() * 240, "Safari": 50 + random.next() * 90,
                              "WindowServer": 70, "Slack": 15 + random.next() * 15], at: date)
        }

        // Seven months of daily trend rows: slowly fading battery, a disk that fills up.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for day in 0..<210 {
            guard let date = calendar.date(byAdding: .day, value: -day, to: today) else { continue }
            let age = Double(210 - day) / 210
            let recent = day < 30 ? Double(30 - day) / 30 * 18e9 : 0
            store.upsertDay(DayRecord(day: date, batteryHealth: (100 - 7.4 * pow(age, 1.2)).rounded(),
                                      batteryCycles: 118 + Int(age * 160),
                                      diskUsed: 382e9 + age * 30e9 + recent + sin(Double(day) / 3) * 1.5e9,
                                      diskTotal: 994.66e9))
        }
    }
}

/// Small deterministic generator, so demo screenshots come out the same each run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    /// A value in 0..<1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
