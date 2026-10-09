import Foundation
import Testing
@testable import Gauge

@Suite struct InsightsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gb = Insights.gigabyte, mb = Insights.megabyte

    /// One point a minute for `minutes` minutes, ending now.
    func series(minutes: Int, _ bytes: (Int) -> Double) -> [Insights.MemoryPoint] {
        (0..<minutes).map { i in
            Insights.MemoryPoint(date: now.addingTimeInterval(Double(i - minutes + 1) * 60), bytes: bytes(i))
        }
    }

    // MARK: Memory growth

    @Test func recordsOnePointAMinuteAndForgetsQuitApps() {
        var trends: [String: [Insights.MemoryPoint]] = [:]
        let slack = AppUsage(name: "Slack", cpu: 0, memory: 600 * mb, cpuTime: 0)
        let system = AppUsage(name: "macOS", cpu: 0, memory: 4 * gb, cpuTime: 0)
        Insights.record(&trends, apps: [slack, system], at: now)
        Insights.record(&trends, apps: [slack], at: now.addingTimeInterval(30))
        Insights.record(&trends, apps: [slack], at: now.addingTimeInterval(60))
        #expect(trends["Slack"]?.count == 2)
        #expect(trends["macOS"] == nil)
        Insights.record(&trends, apps: [], at: now.addingTimeInterval(120))
        #expect(trends.isEmpty)
    }

    @Test func keepsSixHours() {
        var trends = ["Slack": series(minutes: 400) { _ in 600 * mb }]
        Insights.record(&trends, apps: [AppUsage(name: "Slack", cpu: 0, memory: 600 * mb, cpuTime: 0)], at: now.addingTimeInterval(60))
        let points = trends["Slack"] ?? []
        #expect(points.count == 361)
        #expect(now.addingTimeInterval(60).timeIntervalSince(points[0].date) <= Insights.trendWindow)
    }

    @Test func steadyGrowthIsFlagged() throws {
        // 600 MB to 3.1 GB over three hours, with a little jitter.
        let points = series(minutes: 181) { i in 600 * mb + Double(i) * (2.5 * gb / 180) + (i % 3 == 1 ? -2 * mb : 0) }
        let growth = try #require(Insights.growth("Slack", points))
        #expect(growth.since == points[0].date)
        let notice = Insights.growthNotice(growth, memoryTotal: 32 * gb)
        #expect(notice.title == "Slack's memory keeps growing")
        #expect(notice.body.hasPrefix("Slack has grown from 600 MB to 3.1 GB since \(Fmt.clock(points[0].date))."))
        #expect(notice.hot == false)
        #expect(notice.target == "Memory")
    }

    @Test func largeGrowthIsHot() throws {
        let points = series(minutes: 120) { i in 1 * gb + Double(i) * (8 * gb / 119) }
        let growth = try #require(Insights.growth("Chrome", points))
        #expect(Insights.growthNotice(growth, memoryTotal: 16 * gb).hot)
    }

    @Test func doublingCountsWhenUnderAGigabyte() {
        #expect(Insights.growth("Notes", series(minutes: 90) { i in 300 * mb + Double(i) * (400 * mb / 89) }) != nil)
        // Doubled, but only from 40 MB to 80 MB.
        #expect(Insights.growth("Notes", series(minutes: 90) { i in 40 * mb + Double(i) * (40 * mb / 89) }) == nil)
    }

    @Test func shortOrUnsteadyGrowthIsIgnored() {
        // Under an hour.
        #expect(Insights.growth("Slack", series(minutes: 50) { i in 600 * mb + Double(i) * 50 * mb }) == nil)
        // Flat.
        #expect(Insights.growth("Slack", series(minutes: 200) { _ in 2 * gb }) == nil)
        // One jump from loading a big document, not a steady climb.
        #expect(Insights.growth("Preview", series(minutes: 200) { i in i < 190 ? 500 * mb : 2.5 * gb }) == nil)
        // Sawtooth: grows and is released again.
        #expect(Insights.growth("Xcode", series(minutes: 200) { i in 1 * gb + Double(i % 20) * 100 * mb + Double(i) * 6 * mb }) == nil)
    }

    @Test func atMostTwoGrowthNoticesBiggestFirst() {
        let trends = [
            "A": series(minutes: 120) { i in 1 * gb + Double(i) * 10 * mb },
            "B": series(minutes: 120) { i in 1 * gb + Double(i) * 30 * mb },
            "C": series(minutes: 120) { i in 1 * gb + Double(i) * 20 * mb },
        ]
        #expect(Insights.growthNotices(trends, memoryTotal: 64 * gb).map(\.title) == ["B's memory keeps growing", "C's memory keeps growing"])
    }

    // MARK: This Mac's normal

    /// A week of minutes at 8% CPU, busier (30%) from 2 pm to 3 pm.
    func week(days: Double = 7, calendar: Calendar) -> [(date: Date, cpu: Double)] {
        stride(from: now.addingTimeInterval(-days * 86_400), to: now.addingTimeInterval(-3600), by: 60).map { date in
            (date, calendar.component(.hour, from: date) == 14 ? 30 : 8)
        }
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func normalIsPerHourOfDay() throws {
        // 1_800_000_000 is 08:00 UTC.
        let morning = try #require(Insights.cpuNormal(week(calendar: utc), now: now, calendar: utc))
        #expect(morning.hour == 8)
        #expect(morning.p90 == 8)
        let afternoon = try #require(Insights.cpuNormal(week(calendar: utc), now: now.addingTimeInterval(6 * 3600), calendar: utc))
        #expect(afternoon.hour == 14)
        #expect(afternoon.p90 == 30)
    }

    @Test func needsThreeDaysOfHistory() {
        #expect(Insights.cpuNormal(week(days: 2.5, calendar: utc), now: now, calendar: utc) == nil)
        #expect(Insights.cpuNormal([], now: now, calendar: utc) == nil)
        #expect(Insights.cpuNormal(week(days: 3.1, calendar: utc), now: now, calendar: utc) != nil)
    }

    @Test func unusualMeansWellAboveNormal() {
        let quiet = Insights.CPUNormal(hour: 9, p90: 10)
        #expect(!Insights.cpuUnusual(average: 30, normal: quiet))  // needs 20 points over
        #expect(Insights.cpuUnusual(average: 31, normal: quiet))
        let busy = Insights.CPUNormal(hour: 9, p90: 50)
        #expect(!Insights.cpuUnusual(average: 75, normal: busy))  // needs half again
        #expect(Insights.cpuUnusual(average: 76, normal: busy))
    }

    @Test func recentAverageNeedsFourMinutes() {
        func sample(_ secondsAgo: Double, _ cpu: Double) -> RecentSample {
            RecentSample(date: now.addingTimeInterval(-secondsAgo), cpu: cpu, memory: 0, memoryTotal: 0, gpu: 0,
                         diskRead: 0, diskWrite: 0, down: 0, up: 0, battery: nil)
        }
        #expect(Insights.recentCPU((0..<100).map { sample(Double($0) * 2, 50) }, now: now) == nil)
        let tenMinutes = (0..<300).map { sample(Double(299 - $0) * 2, $0 < 149 ? 90 : 40) }
        #expect(Insights.recentCPU(tenMinutes, now: now) == 40)
    }

    @Test func cpuNoticeNamesBusiestApps() {
        let apps = [AppUsage(name: "Safari", cpu: 42, memory: 0, cpuTime: 0), AppUsage(name: "Xcode", cpu: 310, memory: 0, cpuTime: 0),
                    AppUsage(name: "Notes", cpu: 1, memory: 0, cpuTime: 0)]
        let notice = Insights.cpuNotice(average: 64, normal: .init(hour: 15, p90: 22), apps: apps, now: now, since: now)
        #expect(notice.title == "CPU is higher than usual for this time of day")
        #expect(notice.body.hasPrefix("It averaged 64% over the last 5 min. Around "))
        #expect(notice.body.hasSuffix(" this Mac usually stays under 22%. Busiest now: Xcode and Safari."))
    }

    // MARK: Sleep

    func report(drop: Int, onBattery: Bool = true, wakes: Int = 23, wokeAgo: Double = 3600) -> SleepReport {
        SleepReport(slept: now.addingTimeInterval(-wokeAgo - 460 * 60), woke: now.addingTimeInterval(-wokeAgo),
                    chargeAtSleep: 86, chargeAtWake: 86 - drop, onBattery: onBattery, wakes: wakes,
                    reasons: [Tally(name: "scheduled background tasks", count: 14), Tally(name: "network activity", count: 6),
                              Tally(name: "other reasons", count: 3)],
                    requesters: [Tally(name: "dasd", count: 14), Tally(name: "mDNSResponder", count: 3)])
    }

    @Test func sleepDrainNotice() throws {
        let notice = try #require(Insights.sleepNotice(report(drop: 12), now: now))
        #expect(notice.title == "Battery dropped 12% while asleep")
        #expect(notice.body == "Over 7h 40m asleep it woke 23 times, mostly for scheduled background tasks (14) and network activity (6). "
            + "Wakes were requested by dasd and mDNSResponder.")
        #expect(notice.hot == false)
        #expect(notice.since == now.addingTimeInterval(-3600))
        #expect(Insights.sleepNotice(report(drop: 6, wakes: 0), now: now)?.body == "It didn't wake during 7h 40m asleep.")
    }

    @Test func sleepDrainNeedsFivePercentOnBatteryRecently() {
        #expect(Insights.sleepNotice(report(drop: 4), now: now) == nil)
        #expect(Insights.sleepNotice(report(drop: 12, onBattery: false), now: now) == nil)
        #expect(Insights.sleepNotice(report(drop: 12, wokeAgo: 13 * 3600), now: now) == nil)
    }

    @Test func sleepStat() {
        #expect(Insights.sleepStat(.unavailable).value == "Unavailable")
        #expect(Insights.sleepStat(.notRead).value == "–")
        #expect(Insights.sleepStat(.read(nil)).value == "–")
        #expect(Insights.sleepStat(.read(report(drop: 12))).value == "−12% in 7h 40m")
        #expect(Insights.sleepStat(.read(report(drop: 0, onBattery: false))).value == "On power, 7h 40m")
    }

    // MARK: Thermal

    @Test func thermalStateIsShownHonestly() {
        #expect(Insights.thermalLabel(.nominal) == "Nominal")
        #expect(Insights.thermalLabel(.critical) == "Critical")
        #expect(Insights.thermalNotice(.nominal, since: now) == nil)
        #expect(Insights.thermalNotice(.fair, since: now) == nil)
        let notice = Insights.thermalNotice(.serious, since: now)
        #expect(notice?.title == "macOS is slowing the processor to manage heat")
        #expect(notice?.body == "Thermal state is Serious. Apps may run slower until the Mac cools down.")
        #expect(notice?.hot == true)
    }
}
