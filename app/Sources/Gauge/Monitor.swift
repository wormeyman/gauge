import AppKit
import Observation

struct Stat: Hashable { var label: String; var value: String }

struct Vital: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var caption: String
    var value: String
    var unit: String
    /// Position on the channel's ruler, 0...1.
    var fraction: Double
    var scale: (String, String)
    var stats: [Stat]
    /// Recent trace, normalised to 0...1.
    var trace: [Double]
    var flag: String?
    var symbol: String

    static func == (a: Vital, b: Vital) -> Bool {
        a.name == b.name && a.caption == b.caption && a.value == b.value && a.unit == b.unit && a.fraction == b.fraction
            && a.scale == b.scale && a.stats == b.stats && a.trace == b.trace && a.flag == b.flag && a.symbol == b.symbol
    }
}

struct Notice: Identifiable, Equatable {
    var id: String { tag + title }
    var tag: String
    var title: String
    var body: String
    var hot: Bool
    var since: Date
    var target: String
}

struct Slice: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var value: String
    var share: Double
    var hot = false
}

struct Breakdown: Identifiable, Equatable {
    var id: String { title }
    /// The metric whose colour the ring uses.
    var metric: String
    var title: String
    var subtitle: String
    var center: String
    var centerCaption: String
    var slices: [Slice]
}

struct HardwareCard: Identifiable, Equatable {
    var id: String { title }
    /// Colour key for the card's dot.
    var tone: String
    var title: String
    var rows: [Stat]
    var note: String?
}

/// A stop request on a dev server that hasn't finished.
enum ServerStop: Equatable {
    case stopping
    /// Still running a few seconds after the stop request; it can be forced.
    case stillRunning
    /// Owned by another user, such as a server started with sudo.
    case notPermitted
}

struct StatusItem: Identifiable, Equatable {
    var id: String { text }
    var on: Bool
    var text: String
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory", network = "Network"
    var id: String { rawValue }
}

enum HistoryPeriod: Int, CaseIterable, Identifiable {
    case hour = 3600, sixHours = 21_600, twelveHours = 43_200, day = 86_400, week = 604_800
    var id: Int { rawValue }
    var short: String {
        switch self {
        case .hour: "1h"
        case .sixHours: "6h"
        case .twelveHours: "12h"
        case .day: "24h"
        case .week: "7d"
        }
    }
    var label: String {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .twelveHours: "12 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }
}

/// A recent reading kept in memory for channel traces and detail sheets.
struct RecentSample {
    var date: Date
    var cpu: Double
    var memory: Double
    var memoryTotal: Double
    var gpu: Double
    var diskRead: Double
    var diskWrite: Double
    var down: Double
    var up: Double
    var battery: Double?
    var diskIO: Double { diskRead + diskWrite }
}

@MainActor @Observable
final class Monitor {
    static let tabs = ["Overview", "CPU", "Memory", "Disk", "Network", "GPU", "Battery", "Projects"]

    var ready = false
    var vitals: [Vital] = []
    var notices: [Notice] = []
    var dismissed: Set<String> = []
    var breakdowns: [Breakdown] = []
    var hardware: [HardwareCard] = []
    var apps: [AppUsage] = []
    var servers: [DevServer] = []
    var serverStops: [Int32: ServerStop] = [:]
    /// Apps Gauge can quit, under the names the process list uses. Refreshed when apps launch or quit.
    private(set) var quittable: [String: [NSRunningApplication]] = [:]
    var status: [StatusItem] = []
    var processCount = 0
    var appCount = 0
    var machine = ""
    var recent: [RecentSample] = []
    /// Whole-percent CPU for the menu bar label. Updated every tick, even while no window is visible,
    /// but only changes (and redraws the label) when the rounded value does.
    var cpuNow: Int?
    /// A page the menu bar panel asked the main window to show; the window clears it.
    var requestedPage: String?
    /// Gauge's own cost, averaged over the last 30 seconds.
    var selfUsage = SelfUsage()

    var historyMetric: HistoryMetric = .cpu
    var period: HistoryPeriod = .twelveHours { didSet { reloadHistory() } }
    var history: [HistoryPoint] = []
    var topApps: [(String, Double)] = []
    var oldestSample: Date?

    @ObservationIgnored let store = HistoryStore()
    @ObservationIgnored let sampler = Sampler()
    // Bookkeeping no view reads directly, kept out of observation tracking.
    @ObservationIgnored private let queue = DispatchQueue(label: "gauge.sampler", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    private(set) var latest: Reading?
    @ObservationIgnored private var pending: [Reading] = []
    @ObservationIgnored private var pendingCPU: [String: Double] = [:]
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var serverList: [DevServer] = []
    @ObservationIgnored private var memoryWarningSince: Date?
    @ObservationIgnored private var busyApps: [String: Date] = [:]
    @ObservationIgnored private var cpuHighSince: Date?
    @ObservationIgnored private var gpuPeak = 0.0
    @ObservationIgnored private var selfSamples: [SelfUsage] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    var visibleNotices: [Notice] { notices.filter { !dismissed.contains($0.id) } }

    /// False while no Gauge window is visible: sampling and history continue, view updates pause.
    @ObservationIgnored private var windowVisible = true
    /// True while the menu bar panel is open.
    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private var occlusionObservers: [NSObjectProtocol] = []

    /// True while a Gauge window (the main window or Settings) is on screen and not fully covered. The
    /// menu bar's status item and panel don't count; the panel reports itself through setPanelVisible.
    private func updateWindowVisibility() {
        // The key window counts too, so a window the user is working in always updates.
        let visible = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && ($0.occlusionState.contains(.visible) || $0.isKeyWindow) }
        guard visible != windowVisible else { return }
        windowVisible = visible
        visibilityChanged()
        if visible, let latest { publish(latest) }
    }

    /// Whether anything on screen shows the full reading.
    private var showing: Bool { windowVisible || panelVisible || Snapshot.folder != nil }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        visibilityChanged()
        if visible, let latest { publish(latest) }
    }

    /// Readings only shown on screen are skipped while nothing is visible, and resume on the next tick.
    private func visibilityChanged() {
        let sampler = sampler, detail = showing
        queue.async { sampler.detail = detail }
    }

    func start() {
        guard timer == nil else { return }
        machine = "\(sampler.chip) · \(sampler.cores) cores · \(Int(sampler.memoryTotal / 1_073_741_824)) GB"
        store.prune(keepingDays: Self.retentionDays)
        let sampler = sampler
        queue.async { _ = sampler.read() }  // prime the counters so the first delta is real
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updateWindowVisibility()
            self?.tick()
        }
        reloadHistory()
        // Window-level, not NSApp.occlusionState: the menu bar extra's status item is always visible, so the
        // app as a whole never counts as hidden and views would keep updating behind a closed window.
        let center = NotificationCenter.default
        occlusionObservers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                              NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                // After the current event, so a closing window has left the window list.
                DispatchQueue.main.async { self?.updateWindowVisibility() }
            }
        }
        // Running apps change only when apps launch or quit, so they're counted then rather than every tick.
        refreshRunningApps()
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            workspace.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            }
        }
    }

    private func refreshRunningApps() {
        update(\.appCount, NSWorkspace.shared.runningApplications.reduce(0) { $0 + ($1.activationPolicy == .regular ? 1 : 0) })
        update(\.quittable, ProcessControl.quittableApps())
    }

    /// Assigns only when the value changed: every assignment to an observed property redraws the views
    /// that read it, even when the new value is the same.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Monitor, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    static var retentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        return days > 0 ? days : 30
    }

    private func tick() {
        let sampler = sampler
        queue.async {
            let reading = sampler.read()
            DispatchQueue.main.async { [weak self] in self?.ingest(reading) }
        }
    }

    // MARK: Ingest

    private func ingest(_ r: Reading) {
        guard r.cpuUser != nil else { return }
        latest = r
        ticks += 1
        if let servers = r.servers {
            serverList = servers
            update(\.serverStops, serverStops.filter { pid, _ in servers.contains { $0.pid == pid } })
        }

        let cpu = (r.cpuUser ?? 0) + (r.cpuSystem ?? 0)
        update(\.cpuNow, Int(cpu.rounded()))
        gpuPeak = max(gpuPeak, r.gpuUtilization ?? 0)
        selfSamples.append(r.selfUsage)
        if selfSamples.count > 15 { selfSamples.removeFirst(selfSamples.count - 15) }
        updateFlags(r, cpu: cpu)
        persist(r)
        if ticks % 1800 == 0 { store.prune(keepingDays: Self.retentionDays) }
        recent.append(RecentSample(date: r.date, cpu: cpu, memory: r.memory.used, memoryTotal: r.memory.total,
                                   gpu: r.gpuUtilization ?? 0, diskRead: r.disk.readRate, diskWrite: r.disk.writeRate,
                                   down: r.network.downRate, up: r.network.upRate, battery: r.battery?.percent))
        if recent.count > 300 { recent.removeFirst(recent.count - 300) }
        if showing || !ready { publish(r) }
    }

    /// Rebuilds everything the views show from a reading.
    private func publish(_ r: Reading) {
        let cpu = (r.cpuUser ?? 0) + (r.cpuSystem ?? 0)
        update(\.processCount, r.processCount)
        update(\.apps, r.apps.sorted { $0.cpu > $1.cpu })
        update(\.servers, serverList)
        let n = Double(max(selfSamples.count, 1))
        update(\.selfUsage, SelfUsage(cpu: selfSamples.map(\.cpu).reduce(0, +) / n, memory: r.selfUsage.memory))
        update(\.vitals, buildVitals(r, cpu: cpu))
        update(\.notices, Notices.build(reading: r, now: Date(), memoryWarningSince: memoryWarningSince, busyApps: busyApps,
                                         servers: serverList, previous: notices))
        update(\.breakdowns, buildBreakdowns(r, cpu: cpu))
        update(\.hardware, buildHardware(r))
        update(\.status, Notices.status(vitals: vitals))
        update(\.ready, true)
        if ticks % 15 == 1 { reloadHistory() }
    }

    /// The visible notices for the latest reading, built fresh so they're current even while no window
    /// shows them. The local API reads these, passing servers it just scanned.
    func currentNotices(servers: [DevServer]) -> [Notice] {
        guard let latest else { return [] }
        return Notices.build(reading: latest, now: Date(), memoryWarningSince: memoryWarningSince, busyApps: busyApps,
                             servers: servers, previous: notices).filter { !dismissed.contains($0.id) }
    }

    private func persist(_ r: Reading) {
        pending.append(r)
        for (app, seconds) in r.cpuSecondsDelta { pendingCPU[app, default: 0] += seconds }
        if pending.count >= 5 {
            let n = Double(pending.count)
            func avg(_ f: (Reading) -> Double) -> Double { pending.map(f).reduce(0, +) / n }
            let batteries = pending.compactMap { $0.battery?.percent }
            store.insert(.init(t: Int(r.date.timeIntervalSince1970),
                               cpu: avg { ($0.cpuUser ?? 0) + ($0.cpuSystem ?? 0) },
                               memory: avg { $0.memory.used }, memoryTotal: r.memory.total,
                               gpu: avg { $0.gpuUtilization ?? 0 },
                               down: avg { $0.network.downRate }, up: avg { $0.network.upRate },
                               diskRead: avg { $0.disk.readRate }, diskWrite: avg { $0.disk.writeRate },
                               battery: batteries.isEmpty ? nil : batteries.reduce(0, +) / Double(batteries.count)))
            pending.removeAll()
        }
        if ticks % 30 == 0 {
            store.addCPUTime(pendingCPU, at: r.date)
            pendingCPU.removeAll()
        }
    }

    func reloadHistory() {
        let since = Date().addingTimeInterval(-Double(period.rawValue))
        store.series(since: since) { [weak self] points in self?.update(\.history, points) }
        store.topApps(since: since) { [weak self] apps in
            guard let self, !apps.elementsEqual(topApps, by: ==) else { return }
            topApps = apps
        }
        store.oldestSample { [weak self] date in self?.update(\.oldestSample, date) }
    }

    func clearHistory() {
        store.clear { [weak self] in
            self?.history = []
            self?.topApps = []
            self?.oldestSample = nil
        }
    }

    // MARK: Stopping servers and quitting apps

    func canQuit(_ app: String) -> Bool { quittable[app] != nil }

    /// Asks an app to quit, like its Quit menu item, so it can still offer to save documents.
    /// A forced quit ends it immediately and loses unsaved changes.
    func quit(_ app: String, force: Bool) {
        for running in quittable[app] ?? [] { _ = force ? running.forceTerminate() : running.terminate() }
        quittable[app] = nil
        // If the app is still running a moment later (say, its user cancelled a save prompt), it's offered again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshRunningApps() }
    }

    /// Sends a server the stop signal (SIGKILL when forced), then watches for it to exit.
    func stop(_ server: DevServer, force: Bool = false) {
        switch ProcessControl.signal(server.pid, started: server.started, force: force) {
        case .notPermitted: serverStops[server.pid] = .notPermitted; return
        case .gone: removeServer(server); return
        case .sent: serverStops[server.pid] = .stopping
        }
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if !ProcessControl.isRunning(server.pid, started: server.started) { self.removeServer(server); return }
            }
            self?.serverStops[server.pid] = .stillRunning
        }
    }

    private func removeServer(_ server: DevServer) {
        serverStops[server.pid] = nil
        serverList.removeAll { $0.pid == server.pid }
        if let latest { publish(latest) }
        let sampler = sampler
        queue.async { sampler.rescanServersSoon() }
    }

    // MARK: Flags

    private var memoryFlag: String? {
        guard let p = latest?.memory.pressure else { return nil }
        return p >= 4 ? "Critical" : p >= 2 ? "Elevated" : nil
    }

    private var diskLow: Bool { latest.map { Notices.diskLow($0.disk) } ?? false }

    private func updateFlags(_ r: Reading, cpu: Double) {
        memoryWarningSince = r.memory.pressure >= 2 ? (memoryWarningSince ?? r.date) : nil
        cpuHighSince = cpu >= 85 ? (cpuHighSince ?? r.date) : nil
        var busy: [String: Date] = [:]
        for app in r.apps where app.cpu >= 90 && app.name != "macOS" { busy[app.name] = busyApps[app.name] ?? r.date }
        busyApps = busy
    }

    private func sustained(_ since: Date?) -> Bool { Notices.sustained(since, now: Date()) }

    // MARK: Vitals

    private func trace(_ f: (RecentSample) -> Double, scale: Double? = nil) -> [Double] {
        let values = recent.suffix(58).map(f)
        let top = scale ?? max(values.max() ?? 1, 1)
        return values.map { min(1, max(0, $0 / top)) }
    }

    private func buildVitals(_ r: Reading, cpu: Double) -> [Vital] {
        let cpuAverage = recent.map(\.cpu).reduce(0, +) / Double(max(recent.count, 1))
        let mem = r.memory
        let (memValue, memUnit) = Fmt.memory(mem.used)
        let gpu = r.gpuUtilization
        let gpuAverage = recent.map(\.gpu).reduce(0, +) / Double(max(recent.count, 1))
        let diskUsed = max(0, r.disk.total - r.disk.available)
        let (usedValue, usedUnit) = Fmt.storage(diskUsed)
        let (downValue, downUnit) = Fmt.rate(r.network.downRate)
        let netScale = Fmt.rateScale(recent.suffix(58).map(\.down).max() ?? 0)

        var list = [
            Vital(name: "CPU", caption: "Now", value: String(format: "%.0f", cpu), unit: "%",
                  fraction: cpu / 100, scale: ("0", "100%"),
                  stats: [Stat(label: "User", value: Fmt.percent(r.cpuUser ?? 0)),
                          Stat(label: "System", value: Fmt.percent(r.cpuSystem ?? 0)),
                          Stat(label: "Average", value: Fmt.percent(cpuAverage))],
                  trace: trace(\.cpu, scale: 100), flag: sustained(cpuHighSince) ? "High" : nil, symbol: "cpu"),
            Vital(name: "Memory", caption: "In use of \(Int(mem.total / 1_073_741_824)) GB", value: memValue, unit: memUnit,
                  fraction: mem.total > 0 ? mem.used / mem.total : 0, scale: ("0", "\(Int(mem.total / 1_073_741_824)) GB"),
                  stats: [Stat(label: "App", value: Fmt.memoryText(mem.app)),
                          Stat(label: "Wired", value: Fmt.memoryText(mem.wired)),
                          Stat(label: "Compressed", value: Fmt.memoryText(mem.compressed))],
                  trace: trace(\.memory, scale: mem.total), flag: memoryFlag, symbol: "memorychip"),
            Vital(name: "GPU", caption: sampler.chip, value: gpu.map { String(format: "%.0f", $0) } ?? "–", unit: "%",
                  fraction: (gpu ?? 0) / 100, scale: ("0", "100%"),
                  stats: [Stat(label: "Memory", value: r.gpuMemory.map(Fmt.memoryText) ?? "–"),
                          Stat(label: "Average", value: Fmt.percent(gpuAverage)),
                          Stat(label: "Peak", value: Fmt.percent(gpuPeak))],
                  trace: trace(\.gpu, scale: 100), symbol: "square.stack.3d.up"),
            // Used, not free, so a fuller bar means the same thing on every channel.
            Vital(name: "Disk", caption: "Used of \(Fmt.storageText(r.disk.total))", value: usedValue, unit: usedUnit,
                  fraction: r.disk.total > 0 ? diskUsed / r.disk.total : 0, scale: ("0", Fmt.storageText(r.disk.total)),
                  stats: [Stat(label: "Free", value: Fmt.storageText(r.disk.available)),
                          Stat(label: "Reading", value: Fmt.rateText(r.disk.readRate)),
                          Stat(label: "Writing", value: Fmt.rateText(r.disk.writeRate))],
                  trace: trace(\.diskIO), flag: diskLow ? "Low space" : nil, symbol: "internaldrive"),
            Vital(name: "Network", caption: "Downloading", value: downValue, unit: downUnit,
                  fraction: r.network.downRate / netScale, scale: ("0", Fmt.rateText(netScale)),
                  stats: [Stat(label: "Uploading", value: Fmt.rateText(r.network.upRate)),
                          Stat(label: "Received", value: Fmt.storageText(r.network.receivedSinceLaunch)),
                          Stat(label: "Sent", value: Fmt.storageText(r.network.sentSinceLaunch))],
                  trace: trace(\.down), symbol: "network"),
        ]

        if let b = r.battery {
            let caption = b.charging ? "Charging" : b.onAC ? "On power adapter" : "On battery"
            let time = b.charging ? b.minutesToFull.map(Fmt.minutes) : b.minutesToEmpty.map(Fmt.minutes)
            list.append(Vital(name: "Battery", caption: caption, value: String(format: "%.0f", b.percent), unit: "%",
                              fraction: b.percent / 100, scale: ("0", "100%"),
                              stats: [Stat(label: b.charging ? "Until full" : "Remaining", value: time ?? "–"),
                                      Stat(label: "Power", value: b.watts.map { String(format: "%.1f W", $0) } ?? "–"),
                                      Stat(label: "Health", value: b.health.map(Fmt.percent) ?? "–")],
                              trace: trace({ $0.battery ?? 0 }, scale: 100),
                              flag: !b.onAC && b.percent < 15 ? "Low" : nil, symbol: "battery.75percent"))
        } else {
            list.append(Vital(name: "Battery", caption: "No battery", value: "AC", unit: "power", fraction: 0,
                              scale: ("0", "100%"), stats: [Stat(label: "Source", value: "Power adapter")],
                              trace: [], symbol: "powerplug"))
        }
        return list
    }

    // MARK: Breakdowns

    private func buildBreakdowns(_ r: Reading, cpu: Double) -> [Breakdown] {
        let m = r.memory
        let total = max(m.total, 1)
        let types: [(String, Double)] = [("App", m.app), ("Wired", m.wired), ("Compressed", m.compressed), ("Cached", m.cached), ("Free", m.free)]
        let memoryByType = Breakdown(metric: "Memory", title: "Memory by type", subtitle: "\(Fmt.percent(m.used / total * 100)) in use",
                                     center: Fmt.percent(m.used / total * 100), centerCaption: "in use",
                                     slices: types.map { Slice(name: $0.0, value: Fmt.memoryText($0.1), share: $0.1 / total,
                                                               hot: $0.0 == "Compressed" && memoryFlag != nil) })

        // App footprints include shared and compressed pages, so they can add up to more than
        // "memory used". Shares are taken of whichever total is larger so the ring never overflows.
        let byMemory = r.apps.sorted { $0.memory > $1.memory }
        let topMemory = Array(byMemory.prefix(5))
        let topTotal = topMemory.map(\.memory).reduce(0, +)
        let otherMemory = max(0, m.used - topTotal)
        let ringTotal = max(m.used, topTotal, 1)
        let (usedValue, usedUnit) = Fmt.memory(m.used)
        var appSlices = topMemory.map { Slice(name: $0.name, value: Fmt.memoryText($0.memory), share: $0.memory / ringTotal) }
        if otherMemory / ringTotal >= 0.01 {
            appSlices.append(Slice(name: "Other & system", value: Fmt.memoryText(otherMemory), share: otherMemory / ringTotal))
        }
        let memoryByApp = Breakdown(metric: "Memory", title: "Memory by app", subtitle: "\(usedValue) \(usedUnit) in use",
                                    center: usedValue, centerCaption: usedUnit, slices: appSlices)

        let byCPU = r.apps.sorted { $0.cpu > $1.cpu }
        let topCPU = Array(byCPU.prefix(4))
        let otherCPU = byCPU.dropFirst(4).map(\.cpu).reduce(0, +)
        let cpuSum = max(topCPU.map(\.cpu).reduce(0, +) + otherCPU, 0.01)
        let cpuByApp = Breakdown(metric: "CPU", title: "CPU by app", subtitle: "\(Fmt.percent(cpu)) in use",
                                 center: Fmt.percent(cpu), centerCaption: "in use",
                                 slices: topCPU.map { Slice(name: $0.name, value: String(format: "%.1f%%", $0.cpu), share: $0.cpu / cpuSum) }
                                     + [Slice(name: "Other", value: String(format: "%.1f%%", otherCPU), share: otherCPU / cpuSum)])

        let d = r.disk
        let diskTotal = max(d.total, 1)
        let disk = Breakdown(metric: "Disk", title: "Startup disk", subtitle: d.name,
                             center: Fmt.percent((d.total - d.available) / diskTotal * 100), centerCaption: "used",
                             slices: [Slice(name: "Used", value: Fmt.storageText(d.total - d.available), share: (d.total - d.available) / diskTotal),
                                      Slice(name: "Available", value: Fmt.storageText(d.available), share: d.available / diskTotal, hot: diskLow)])
        return [memoryByType, memoryByApp, cpuByApp, disk]
    }

    // MARK: Hardware

    private func buildHardware(_ r: Reading) -> [HardwareCard] {
        var audioRows = [Stat(label: "Playing", value: r.audioPlaying ? "Yes" : "Nothing")]
        if let device = r.audioDevice { audioRows.append(Stat(label: "Output", value: device)) }
        let accessories = r.accessories.map { Stat(label: $0.name, value: "\($0.percent)%") }
        return [
            HardwareCard(tone: "Disk", title: "Temperature & fans", rows: [Stat(label: "Sensors", value: "Not available yet")],
                         note: "Reading temperature sensors needs a privileged helper, which Gauge doesn't have yet."),
            HardwareCard(tone: "GPU", title: "Audio activity", rows: audioRows,
                         note: r.audioPlaying ? "Audio is playing through this output." : "Nothing is playing."),
            HardwareCard(tone: "CPU", title: "Bluetooth batteries",
                         rows: accessories.isEmpty ? [Stat(label: "Accessories", value: "None")] : accessories,
                         note: accessories.isEmpty ? "Apple keyboards, mice and trackpads show their battery here when connected." : nil),
        ]
    }

    // MARK: Export

    func csv() -> String {
        var lines = ["time,cpu_percent,memory_used_gb,download_bytes_per_second"]
        let formatter = ISO8601DateFormatter()
        for p in history {
            lines.append("\(formatter.string(from: p.date)),\(String(format: "%.1f", p.cpu)),\(String(format: "%.2f", p.memoryUsed / 1_073_741_824)),\(String(format: "%.0f", p.download))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
