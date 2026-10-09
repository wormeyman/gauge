import AppKit

/// Notices that need more than the current reading: an app whose memory keeps growing, CPU that's
/// unusual for this Mac at this hour, battery lost while asleep, and macOS slowing the processor
/// for heat. The rules are pure functions so they can be tested; InsightTracker keeps their state.
enum Insights {
    // MARK: Memory that keeps growing

    struct MemoryPoint: Equatable {
        var date: Date
        var bytes: Double
    }

    /// One footprint per app per minute, for the last six hours.
    static let trendInterval: TimeInterval = 60
    static let trendWindow: TimeInterval = 6 * 3600

    static func record(_ trends: inout [String: [MemoryPoint]], apps: [AppUsage], at date: Date) {
        var next: [String: [MemoryPoint]] = [:]
        for app in apps where app.name != "macOS" {
            // An app that quit drops out here, so it starts over when it reopens.
            var points = trends[app.name] ?? []
            if points.last.map({ date.timeIntervalSince($0.date) >= trendInterval - 1 }) ?? true {
                points.append(MemoryPoint(date: date, bytes: app.memory))
            }
            if let keep = points.firstIndex(where: { date.timeIntervalSince($0.date) <= trendWindow }), keep > 0 {
                points.removeFirst(keep)
            }
            next[app.name] = points
        }
        trends = next
    }

    struct Growth: Equatable {
        var app: String
        var from: Double
        var to: Double
        var since: Date
    }

    /// Memory that has grown steadily for at least an hour: rising in most minutes, close to a straight
    /// line, and up by 1 GB or more, or to double where it started.
    static func growth(_ app: String, _ points: [MemoryPoint]) -> Growth? {
        guard points.count >= 30, let first = points.first, let last = points.last,
              last.date.timeIntervalSince(first.date) >= 3600 else { return nil }
        let grown = last.bytes - first.bytes
        guard grown >= gigabyte || (last.bytes >= first.bytes * 2 && grown >= 256 * megabyte) else { return nil }
        // A minute counts as rising unless it fell by more than 1% (footprints jitter).
        let rising = zip(points, points.dropFirst()).count { $1.bytes >= $0.bytes * 0.99 }
        guard Double(rising) / Double(points.count - 1) >= 0.7 else { return nil }
        let x = points.map { $0.date.timeIntervalSince(first.date) }, y = points.map(\.bytes)
        let n = Double(points.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        let sxy = zip(x, y).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let sxx = x.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        let syy = y.map { ($0 - my) * ($0 - my) }.reduce(0, +)
        guard sxx > 0, syy > 0, sxy > 0, sxy * sxy / (sxx * syy) >= 0.8 else { return nil }
        return Growth(app: app, from: first.bytes, to: last.bytes, since: first.date)
    }

    static func growthNotice(_ g: Growth, memoryTotal: Double) -> Notice {
        Notice(tag: "Memory", title: "\(g.app)'s memory keeps growing",
               body: "\(g.app) has grown from \(short(g.from)) to \(short(g.to)) since \(Fmt.clock(g.since)). "
                   + "If it isn't doing anything for you right now, quitting and reopening it gives the memory back.",
               hot: g.to >= max(4 * gigabyte, memoryTotal * 0.25), since: g.since, target: "Memory")
    }

    /// The two apps that grew most.
    static func growthNotices(_ trends: [String: [MemoryPoint]], memoryTotal: Double) -> [Notice] {
        trends.compactMap { growth($0.key, $0.value) }
            .sorted { $0.to - $0.from > $1.to - $1.from }
            .prefix(2)
            .map { growthNotice($0, memoryTotal: memoryTotal) }
    }

    /// "600 MB", "3.1 GB": rounder than the readouts, for sentences.
    static func short(_ bytes: Double) -> String {
        bytes >= gigabyte ? String(format: "%.1f GB", bytes / gigabyte) : String(format: "%.0f MB", bytes / megabyte)
    }

    static let gigabyte = 1_073_741_824.0
    static let megabyte = 1_048_576.0

    // MARK: This Mac's normal CPU

    /// How busy this Mac usually is at an hour of the day: 90% of its minutes then were at or below `p90`.
    struct CPUNormal: Equatable {
        var hour: Int
        var p90: Double
    }

    /// Needs three days of history and at least an hour of minutes at this hour of day; nil otherwise.
    static func cpuNormal(_ minutes: [(date: Date, cpu: Double)], now: Date, calendar: Calendar = .current) -> CPUNormal? {
        guard let oldest = minutes.map(\.date).min(), now.timeIntervalSince(oldest) >= 3 * 86_400 else { return nil }
        let hour = calendar.component(.hour, from: now)
        let values = minutes.filter { calendar.component(.hour, from: $0.date) == hour }.map(\.cpu).sorted()
        guard values.count >= 60 else { return nil }
        return CPUNormal(hour: hour, p90: values[Int((Double(values.count - 1) * 0.9).rounded())])
    }

    /// Well above normal: half again over the usual ceiling, and at least 20 points over it.
    static func cpuUnusual(average: Double, normal: CPUNormal) -> Bool {
        average > max(normal.p90 * 1.5, normal.p90 + 20)
    }

    /// Average CPU over the last five minutes; nil until four minutes of readings exist.
    static func recentCPU(_ recent: [RecentSample], now: Date) -> Double? {
        let window = recent.filter { now.timeIntervalSince($0.date) <= 300 }
        guard let first = window.first, now.timeIntervalSince(first.date) >= 240 else { return nil }
        return window.map(\.cpu).reduce(0, +) / Double(window.count)
    }

    static func cpuNotice(average: Double, normal: CPUNormal, apps: [AppUsage], now: Date, since: Date) -> Notice {
        let busiest = apps.filter { $0.cpu >= 5 }.sorted { $0.cpu > $1.cpu }.prefix(3).map(\.name)
        let hour = Calendar.current.date(bySettingHour: normal.hour, minute: 0, second: 0, of: now) ?? now
        var body = "It averaged \(Fmt.percent(average)) over the last 5 min. Around \(Fmt.clock(hour)) "
            + "this Mac usually stays under \(Fmt.percent(normal.p90))."
        if !busiest.isEmpty { body += " Busiest now: \(busiest.formatted(.list(type: .and)))." }
        return Notice(tag: "CPU", title: "CPU is higher than usual for this time of day", body: body,
                      hot: false, since: since, target: "CPU")
    }

    // MARK: Battery used while asleep

    /// Shown for half a day after waking, when the Mac slept on battery and lost 5% or more.
    static func sleepNotice(_ report: SleepReport, now: Date) -> Notice? {
        guard report.onBattery, report.drop >= 5, now.timeIntervalSince(report.woke) <= 12 * 3600 else { return nil }
        let asleep = Fmt.minutes(report.minutes)
        var body: String
        if report.wakes == 0 {
            body = "It didn't wake during \(asleep) asleep."
        } else {
            let reasons = report.reasons.prefix(2).map { "\($0.name) (\($0.count))" }.formatted(.list(type: .and))
            body = "Over \(asleep) asleep it woke \(report.wakes == 1 ? "once" : "\(report.wakes) times"), mostly for \(reasons)."
            let requesters = report.requesters.prefix(3).map(\.name)
            if !requesters.isEmpty { body += " Wakes were requested by \(requesters.formatted(.list(type: .and)))." }
        }
        return Notice(tag: "Battery", title: "Battery dropped \(report.drop)% while asleep", body: body,
                      hot: false, since: report.woke, target: "Battery")
    }

    /// The battery page's reading for the last sleep.
    static func sleepStat(_ status: SleepLog.Status) -> Stat {
        switch status {
        case .unavailable: Stat(label: "Last sleep", value: "Unavailable")
        case .read(let report?) where report.onBattery:
            Stat(label: "Last sleep", value: "\(report.drop >= 0 ? "−" : "+")\(abs(report.drop))% in \(Fmt.minutes(report.minutes))")
        case .read(let report?): Stat(label: "Last sleep", value: "On power, \(Fmt.minutes(report.minutes))")
        case .read(nil), .notRead: Stat(label: "Last sleep", value: "–")
        }
    }

    // MARK: Thermal state

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    static func thermalNotice(_ state: ProcessInfo.ThermalState, since: Date) -> Notice? {
        guard state == .serious || state == .critical else { return nil }
        return Notice(tag: "Thermal", title: "macOS is slowing the processor to manage heat",
                      body: "Thermal state is \(thermalLabel(state)). Apps may run slower until the Mac cools down.",
                      hot: true, since: since, target: "CPU")
    }
}

/// Keeps what the insight rules need between readings. Monitor feeds it every reading.
@MainActor
final class InsightTracker {
    private(set) var trends: [String: [Insights.MemoryPoint]] = [:]
    private var lastTrend = Date.distantPast
    private var cpuNormal: Insights.CPUNormal?
    private var lastNormalQuery = Date.distantPast
    private var cpuUnusualSince: Date?
    private var thermalSince: Date?
    private(set) var sleep: SleepLog.Status = .notRead
    private var lastSleepRead = Date.distantPast
    private var readingSleep = false
    private var wokeAt: Date?
    private var wakeObserver: NSObjectProtocol?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeAt = Date() }
        }
    }

    func ingest(_ r: Reading, recent: [RecentSample], store: HistoryStore) {
        if r.date.timeIntervalSince(lastTrend) >= Insights.trendInterval {
            lastTrend = r.date
            Insights.record(&trends, apps: r.apps, at: r.date)
        }
        // History changes slowly, so this Mac's normal is looked up every 5 minutes, not every reading.
        if r.date.timeIntervalSince(lastNormalQuery) >= 300 {
            lastNormalQuery = r.date
            let now = r.date
            store.cpuMinutes(since: now.addingTimeInterval(-7 * 86_400), before: now.addingTimeInterval(-3600)) { [weak self] minutes in
                self?.cpuNormal = Insights.cpuNormal(minutes, now: now)
            }
        }
        if let normal = cpuNormal, let average = Insights.recentCPU(recent, now: r.date),
           Insights.cpuUnusual(average: average, normal: normal) {
            cpuUnusualSince = cpuUnusualSince ?? r.date
        } else {
            cpuUnusualSince = nil
        }
        thermalSince = r.thermal == .serious || r.thermal == .critical ? (thermalSince ?? r.date) : nil
        // The power log is read hourly, and a minute after each wake once macOS has logged it. Laptops only.
        let afterWake = wokeAt.map { r.date.timeIntervalSince($0) >= 60 } ?? false
        if r.battery != nil, !readingSleep, afterWake || r.date.timeIntervalSince(lastSleepRead) >= 3600 {
            readingSleep = true
            wokeAt = nil
            lastSleepRead = r.date
            DispatchQueue.global(qos: .utility).async {
                let status: SleepLog.Status = SleepLog.read().map { .read(SleepLog.parse($0)) } ?? .unavailable
                DispatchQueue.main.async { [weak self] in
                    self?.sleep = status
                    self?.readingSleep = false
                }
            }
        }
    }

    func notices(_ r: Reading, recent: [RecentSample], now: Date) -> [Notice] {
        var list: [Notice] = []
        if let since = thermalSince, let notice = Insights.thermalNotice(r.thermal, since: since) { list.append(notice) }
        if let since = cpuUnusualSince, let normal = cpuNormal, let average = Insights.recentCPU(recent, now: now) {
            list.append(Insights.cpuNotice(average: average, normal: normal, apps: r.apps, now: now, since: since))
        }
        list += Insights.growthNotices(trends, memoryTotal: r.memory.total)
        if case .read(let report?) = sleep, let notice = Insights.sleepNotice(report, now: now) { list.append(notice) }
        if InsightDemo.enabled { list += InsightDemo.notices(now: now) }
        return list
    }
}

/// Snapshot-only sample data: with GAUGE_SNAPSHOT and GAUGE_SNAPSHOT_DEMO=1, example insight notices are
/// added to the overview so they can be screenshotted. Never active in normal use.
enum InsightDemo {
    static let enabled = ProcessInfo.processInfo.environment["GAUGE_SNAPSHOT"] != nil
        && ProcessInfo.processInfo.environment["GAUGE_SNAPSHOT_DEMO"] == "1"

    static func notices(now: Date) -> [Notice] {
        let woke = now.addingTimeInterval(-2 * 3600)
        let sleep = SleepReport(slept: woke.addingTimeInterval(-(7 * 3600 + 40 * 60)), woke: woke, chargeAtSleep: 86, chargeAtWake: 74,
                                onBattery: true, wakes: 23,
                                reasons: [Tally(name: "scheduled background tasks", count: 14), Tally(name: "network activity", count: 9)],
                                requesters: [Tally(name: "dasd", count: 14), Tally(name: "mDNSResponder", count: 3)])
        let calendar = Calendar.current
        return [
            Insights.thermalNotice(.serious, since: now.addingTimeInterval(-240)),
            Insights.cpuNotice(average: 64, normal: Insights.CPUNormal(hour: calendar.component(.hour, from: now), p90: 22),
                               apps: [AppUsage(name: "Xcode", cpu: 310, memory: 0, cpuTime: 0),
                                      AppUsage(name: "Safari", cpu: 42, memory: 0, cpuTime: 0)],
                               now: now, since: now.addingTimeInterval(-420)),
            Insights.growthNotice(Insights.Growth(app: "Slack", from: 600 * Insights.megabyte, to: 3.1 * Insights.gigabyte,
                                                  since: now.addingTimeInterval(-3 * 3600 - 1200)), memoryTotal: 32 * Insights.gigabyte),
            Insights.sleepNotice(sleep, now: now),
        ].compactMap { $0 }
    }
}
