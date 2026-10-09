import Foundation
import Testing
@testable import Gauge

@Suite struct NoticesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(apps: [AppUsage] = [], available: Double = 500e9, health: Double? = nil) -> Reading {
        var r = Reading()
        r.date = now
        r.apps = apps
        r.memory.total = 16 * 1_073_741_824
        r.disk = DiskReading(total: 1_000e9, available: available)
        if let health { r.battery = BatteryReading(percent: 80, charging: false, onAC: false, health: health, cycles: 900) }
        return r
    }

    func server(_ pid: Int32, _ name: String, _ ports: [Int], cpu: Double = 0, memory: Double = 1_073_741_824, isDev: Bool = true) -> DevServer {
        DevServer(pid: pid, name: name, folder: "site", ports: ports, cpu: cpu, memory: memory, isDev: isDev)
    }

    func build(_ r: Reading, memorySince: Date? = nil, busy: [String: Date] = [:], heavy: [String: Date] = [:],
               servers: [DevServer] = [], previous: [Notice] = []) -> [Notice] {
        Notices.build(reading: r, now: now, memoryWarningSince: memorySince, busyApps: busy, heavyApps: heavy,
                      servers: servers, previous: previous)
    }

    @Test func nothingToReportOnAQuietMac() {
        #expect(build(reading()).isEmpty)
    }

    @Test func conditionsMustHoldForThirtySeconds() {
        #expect(!Notices.sustained(nil, now: now))
        #expect(!Notices.sustained(now.addingTimeInterval(-29), now: now))
        #expect(Notices.sustained(now.addingTimeInterval(-30), now: now))
    }

    @Test func busyAppNoticeWaitsUntilSustained() {
        let apps = [AppUsage(name: "Xcode", cpu: 98, memory: 0, cpuTime: 0)]
        #expect(build(reading(apps: apps), busy: ["Xcode": now.addingTimeInterval(-10)]).isEmpty)
        let notices = build(reading(apps: apps), busy: ["Xcode": now.addingTimeInterval(-185)])
        #expect(notices.map(\.title) == ["Xcode is using a lot of CPU"])
        #expect(notices.first?.body == "98% of one core for the last 3 min.")
        #expect(notices.first?.hot == true)
    }

    @Test func memoryPressureNamesTheBiggestApps() {
        let apps = [AppUsage(name: "macOS", cpu: 0, memory: 9e9, cpuTime: 0),
                    AppUsage(name: "Safari", cpu: 0, memory: 2 * 1_073_741_824, cpuTime: 0),
                    AppUsage(name: "Slack", cpu: 0, memory: 1_073_741_824, cpuTime: 0),
                    AppUsage(name: "Notes", cpu: 0, memory: 1e8, cpuTime: 0)]
        let notice = build(reading(apps: apps), memorySince: now).first
        #expect(notice?.tag == "Memory")
        #expect(notice?.body == "The biggest users are Safari, 2.00 GB, and Slack, 1.00 GB.")
    }

    @Test func appHoldingAQuarterOfMemoryIsHeavy() {
        let gb = 1_073_741_824.0
        #expect(!Notices.heavy(AppUsage(name: "Safari", cpu: 0, memory: 3.9 * gb, cpuTime: 0), total: 16 * gb))
        #expect(Notices.heavy(AppUsage(name: "Safari", cpu: 0, memory: 4 * gb, cpuTime: 0), total: 16 * gb))
        #expect(!Notices.heavy(AppUsage(name: "macOS", cpu: 0, memory: 8 * gb, cpuTime: 0), total: 16 * gb))
        #expect(!Notices.heavy(AppUsage(name: "Safari", cpu: 0, memory: 4 * gb, cpuTime: 0), total: 0))
    }

    @Test func heavyAppNoticeWaitsUntilSustained() {
        let apps = [AppUsage(name: "Chrome", cpu: 0, memory: 6 * 1_073_741_824, cpuTime: 0)]
        #expect(build(reading(apps: apps), heavy: ["Chrome": now.addingTimeInterval(-10)]).isEmpty)
        let notice = build(reading(apps: apps), heavy: ["Chrome": now.addingTimeInterval(-125)]).first
        #expect(notice?.title == "Chrome is using a lot of memory")
        #expect(notice?.body == "6.00 GB, 38% of this Mac's memory, for the last 2 min.")
        #expect(notice?.tag == "Memory")
        #expect(notice?.hot == true)
        #expect(notice?.alert == .heavyApp)
    }

    @Test func lowDiskNoticeKeepsItsStartTime() {
        let earlier = now.addingTimeInterval(-600)
        let previous = [Notice(tag: "Disk", title: "", body: "", hot: true, since: earlier, target: "Disk")]
        #expect(build(reading(available: 50e9)).first?.since == now)
        #expect(build(reading(available: 50e9), previous: previous).first?.since == earlier)
    }

    @Test func lowDiskBelowTenPercentFree() {
        #expect(!Notices.diskLow(DiskReading(total: 1_000e9, available: 100e9)))
        #expect(Notices.diskLow(DiskReading(total: 1_000e9, available: 99e9)))
        #expect(!Notices.diskLow(DiskReading(total: 0, available: 0)))
        #expect(build(reading(available: 50e9)).first?.title == "Your startup disk is almost full")
    }

    @Test func devServersAreSummarisedByRuntime() {
        let servers = [server(1, "Node.js", [3001]), server(2, "Node.js", [3000], cpu: 4), server(3, "Python", [8000])]
        let notice = build(reading(), servers: servers).first
        #expect(notice?.title == "3 dev servers are running")
        #expect(notice?.body == "Node.js on 3000 and 3001; Python on 8000. Together they use 3.00 GB.")
        #expect(notice?.hot == false)
        #expect(notice?.alert == nil)
    }

    @Test func idleWordingAndSingular() {
        let notice = build(reading(), servers: [server(1, "Bun", [5173])]).first
        #expect(notice?.title == "A dev server is running but idle")
    }

    @Test func gameServersDontCountAsDevServers() {
        let minecraft = server(9, "Minecraft", [25565], isDev: false)
        #expect(build(reading(), servers: [minecraft]).isEmpty)
        let notice = build(reading(), servers: [minecraft, server(1, "Node.js", [3000])]).first
        #expect(notice?.title == "A dev server is running but idle")
        #expect(notice?.body == "Node.js on 3000. Together they use 1.00 GB.")
    }

    @Test func projectsNoticeKeepsItsStartTime() {
        let earlier = now.addingTimeInterval(-600)
        let previous = [Notice(tag: "Projects", title: "", body: "", hot: false, since: earlier, target: "Projects")]
        #expect(build(reading(), servers: [server(1, "Node.js", [3000])], previous: previous).first?.since == earlier)
    }

    @Test func wornBatteryIsMentioned() {
        #expect(build(reading(health: 85)).isEmpty)
        #expect(build(reading(health: 79)).first?.title == "Battery health is 79%")
    }

    @Test func statusLine() {
        func vital(_ name: String, _ flag: String? = nil) -> Vital {
            Vital(name: name, caption: "", value: "", unit: "", fraction: 0, scale: ("", ""), stats: [], trace: [], flag: flag, symbol: "")
        }
        let calm = Notices.status(vitals: ["CPU", "Memory", "Disk"].map { vital($0) })
        #expect(calm.map(\.text) == ["All 3 readings normal"])
        #expect(calm.allSatisfy { !$0.on })
        let busy = Notices.status(vitals: [vital("CPU", "High"), vital("Memory", "Elevated"), vital("Disk", "Low space"), vital("GPU")])
        #expect(busy.map(\.text) == ["CPU load high", "Memory pressure elevated", "Startup disk low on space", "1 readings normal"])
        #expect(busy.map(\.on) == [true, true, true, false])
    }
}
