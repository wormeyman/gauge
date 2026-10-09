import Foundation
import SQLite3
import Testing
@testable import Gauge

/// Flight recorder: pure helpers, plus the store additions against a temporary SQLite file, never the real history.
@Suite @MainActor struct RecorderTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GaugeTests-\(UUID().uuidString)")
    var file: URL { folder.appendingPathComponent("history.sqlite") }
    let mb = 1_048_576.0

    // MARK: Pure helpers

    @Test func topKeepsBusiestByCPUAndByMemory() {
        var apps = (0..<8).map { MomentApp(name: "CPU\($0)", cpu: Double(80 - $0 * 10), memory: 1e6) }
        apps += (0..<8).map { MomentApp(name: "Mem\($0)", cpu: 0, memory: Double(8 - $0) * 1e9) }
        let top = Moments.top(apps)
        #expect(top.count == 10)
        #expect(Set(top.map(\.name)) == Set((0..<5).map { "CPU\($0)" } + (0..<5).map { "Mem\($0)" }))
        // An app in both lists appears once.
        let both = Moments.top([MomentApp(name: "Xcode", cpu: 90, memory: 4e9), MomentApp(name: "Safari", cpu: 2, memory: 1e9)])
        #expect(both.map(\.name) == ["Xcode", "Safari"])
    }

    @Test func encodingRoundTrips() {
        let text = Moments.encode([(3, 12.34, 2048 * mb), (17, 0, 512.4 * mb)])
        #expect(text == "3:123:2048,17:0:512")
        let decoded = Moments.decode(text)
        #expect(decoded.map(\.id) == [3, 17])
        #expect(decoded[0].cpu == 12.3)
        #expect(decoded[1].memory == 512 * mb)
        #expect(Moments.decode("").isEmpty)
        #expect(Moments.decode("garbage,4:1").isEmpty)
    }

    @Test func summarizeAveragesCPUOverAllMomentsAndMemoryOverPresent() {
        let summary = Moments.summarize([
            [MomentApp(name: "A", cpu: 30, memory: 100), MomentApp(name: "B", cpu: 10, memory: 50)],
            [MomentApp(name: "A", cpu: 10, memory: 300)],
        ])
        let a = summary.first { $0.name == "A" }, b = summary.first { $0.name == "B" }
        #expect(a?.cpu == 20 && a?.memory == 200)
        #expect(b?.cpu == 5 && b?.memory == 50)
    }

    @Test func accumulatorAveragesTicksThenResets() {
        var acc = MomentAccumulator()
        acc.add([AppUsage(name: "Xcode", cpu: 100, memory: 2e9, cpuTime: 0)])
        acc.add([AppUsage(name: "Xcode", cpu: 50, memory: 4e9, cpuTime: 0), AppUsage(name: "Mail", cpu: 10, memory: 1e9, cpuTime: 0)])
        let first = acc.take()
        #expect(first.first { $0.name == "Xcode" }?.cpu == 75)
        #expect(first.first { $0.name == "Xcode" }?.memory == 3e9)
        #expect(first.first { $0.name == "Mail" }?.cpu == 5)
        #expect(acc.take().isEmpty)
    }

    // MARK: Store

    @Test func opensAHistoryFileFromBeforeTheRecorder() async {
        // A file with only the original tables and one reading.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        let t = Int(Date().addingTimeInterval(-60).timeIntervalSince1970)
        sqlite3_exec(db, """
            CREATE TABLE samples (t INTEGER PRIMARY KEY, cpu REAL, mem REAL, mem_total REAL, gpu REAL,
                down REAL, up REAL, disk_read REAL, disk_write REAL, battery REAL);
            CREATE TABLE app_cpu (hour INTEGER, app TEXT, seconds REAL, PRIMARY KEY (hour, app));
            INSERT INTO samples VALUES (\(t), 42, 8e9, 16e9, 0, 0, 0, 0, 0, NULL);
            """, nil, nil, nil)
        sqlite3_close(db)

        let store = HistoryStore(file: file)
        let points = await withCheckedContinuation { done in store.series(since: Date().addingTimeInterval(-3600)) { done.resume(returning: $0) } }
        #expect(points.map(\.cpu) == [42])
        store.addEvent(RecordedEvent(date: Date(), kind: .wake))
        #expect(await store.events(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(1)).map(\.kind) == [.wake])
    }

    @Test func momentsAreStoredAndSummarized() async {
        let store = HistoryStore(file: file)
        let now = Int(Date().timeIntervalSince1970)
        store.insertMoment(t: now - 20, apps: [MomentApp(name: "Xcode", cpu: 80, memory: 3000 * mb), MomentApp(name: "Safari", cpu: 4, memory: 1000 * mb)])
        store.insertMoment(t: now - 10, apps: [MomentApp(name: "Xcode", cpu: 40, memory: 3200 * mb)])
        store.insertMoment(t: now - 5000, apps: [MomentApp(name: "Old", cpu: 99, memory: 1)])
        let result = await store.moments(from: Date(timeIntervalSince1970: Double(now - 60)), to: Date())
        #expect(result.count == 2)
        let xcode = result.apps.first { $0.name == "Xcode" }
        #expect(xcode?.cpu == 60)
        #expect(xcode?.memory == 3100 * mb)
        #expect(result.apps.first { $0.name == "Safari" }?.cpu == 2)
        #expect(!result.apps.contains { $0.name == "Old" })
    }

    @Test func eventsComeBackInOrder() async {
        let store = HistoryStore(file: file)
        let now = Date()
        store.addEvent(RecordedEvent(date: now.addingTimeInterval(-30), kind: .launch, detail: "Xcode"))
        store.addEvent(RecordedEvent(date: now.addingTimeInterval(-90), kind: .sleep))
        store.addEvent(RecordedEvent(date: now.addingTimeInterval(-10), kind: .thermal, detail: "Serious"))
        let events = await store.events(from: now.addingTimeInterval(-120), to: now)
        #expect(events.map(\.kind) == [.sleep, .launch, .thermal])
        #expect(events[1].label == "Opened Xcode")
        #expect(events[2].detail == "Serious")
    }

    @Test func dailyRowsUpsertAndKeepMissingReadings() async {
        let store = HistoryStore(file: file)
        let today = Calendar.current.startOfDay(for: Date())
        store.upsertDay(DayRecord(day: today, batteryHealth: 95, batteryCycles: 200, diskUsed: 400e9, diskTotal: 1e12))
        store.upsertDay(DayRecord(day: today, batteryHealth: nil, batteryCycles: 201, diskUsed: 401e9, diskTotal: 1e12))
        store.upsertDay(DayRecord(day: today.addingTimeInterval(-86_400), batteryHealth: 96, batteryCycles: 199, diskUsed: nil, diskTotal: nil))
        let days = await store.days(since: today.addingTimeInterval(-7 * 86_400))
        #expect(days.count == 2)
        #expect(days.last?.batteryHealth == 95)
        #expect(days.last?.batteryCycles == 201)
        #expect(days.last?.diskUsed == 401e9)
        #expect(days.first?.diskUsed == nil)
    }

    @Test func pruneAndClearCoverRecorderTables() async {
        let store = HistoryStore(file: file)
        let old = Date().addingTimeInterval(-3 * 86_400)
        store.addEvent(RecordedEvent(date: old, kind: .wake))
        store.addEvent(RecordedEvent(date: Date(), kind: .sleep))
        store.insertMoment(t: Int(old.timeIntervalSince1970), apps: [MomentApp(name: "Old", cpu: 1, memory: 1)])
        store.upsertDay(DayRecord(day: Calendar.current.startOfDay(for: old), batteryHealth: 90))
        store.prune(keepingDays: 1)
        #expect(await store.events(from: .distantPast, to: Date()).map(\.kind) == [.sleep])
        #expect(await store.moments(from: .distantPast, to: Date()).count == 0)
        // Daily rows outlive the sample retention.
        #expect(await store.days(since: .distantPast).count == 1)

        await withCheckedContinuation { done in store.clear { done.resume() } }
        #expect(await store.events(from: .distantPast, to: Date()).isEmpty)
        #expect(await store.days(since: .distantPast).isEmpty)
    }

    @Test func spanStatsAverageSamples() async {
        let store = HistoryStore(file: file)
        let now = Int(Date().timeIntervalSince1970)
        for (i, cpu) in [10.0, 30.0].enumerated() {
            store.insert(.init(t: now - i * 10, cpu: cpu, memory: Double(i + 1) * 1e9, memoryTotal: 16e9, gpu: 0,
                               down: 0, up: 0, diskRead: 0, diskWrite: 0, battery: nil))
        }
        let stats = await store.spanStats(since: Date().addingTimeInterval(-3600))
        #expect(stats.averageCPU == 20)
        #expect(stats.peakMemory == 2e9)
        #expect(stats.seconds == 20)
        #expect(await store.spanStats(since: Date().addingTimeInterval(60)).averageCPU == nil)
    }
}
