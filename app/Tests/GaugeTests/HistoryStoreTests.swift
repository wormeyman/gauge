import Foundation
import Testing
@testable import Gauge

/// Runs against a temporary SQLite file, never the real history.
@Suite @MainActor struct HistoryStoreTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GaugeTests-\(UUID().uuidString)")
    var store: HistoryStore { HistoryStore(file: folder.appendingPathComponent("history.sqlite")) }

    func row(_ t: Date, cpu: Double, battery: Double? = nil) -> HistoryStore.Row {
        .init(t: Int(t.timeIntervalSince1970), cpu: cpu, memory: 8e9, memoryTotal: 16e9, gpu: 0,
              down: 1_000, up: 100, diskRead: 0, diskWrite: 0, battery: battery)
    }

    func series(_ store: HistoryStore, since: Date) async -> [HistoryPoint] {
        await withCheckedContinuation { done in store.series(since: since) { done.resume(returning: $0) } }
    }

    @Test func storesAndAveragesReadings() async {
        let store = store
        let start = Date().addingTimeInterval(-600)
        for i in 0..<6 { store.insert(row(start.addingTimeInterval(Double(i * 10)), cpu: Double(i * 10), battery: i < 3 ? 50 : nil)) }
        let points = await series(store, since: start.addingTimeInterval(-1))
        #expect(!points.isEmpty)
        let n = Double(points.count)
        #expect(abs(points.map(\.cpu).reduce(0, +) / n - 25) < 15)
        #expect(points.allSatisfy { $0.memoryTotal == 16e9 })
        #expect(points.contains { $0.battery == nil })
        #expect(points.contains { $0.battery == 50 })
    }

    @Test func pruneAndClear() async {
        let store = store
        store.insert(row(Date().addingTimeInterval(-3 * 86_400), cpu: 1))
        store.insert(row(Date().addingTimeInterval(-60), cpu: 2))
        store.prune(keepingDays: 1)
        let oldest = await withCheckedContinuation { done in store.oldestSample { done.resume(returning: $0) } }
        #expect(oldest.map { Date().timeIntervalSince($0) < 3_600 } == true)

        await withCheckedContinuation { done in store.clear { done.resume() } }
        #expect(await series(store, since: Date().addingTimeInterval(-86_400)).isEmpty)
    }

    @Test func cpuTimeAddsUpPerApp() async {
        let store = store
        store.addCPUTime(["Xcode": 30, "Safari": 5, "Idle": 0], at: Date())
        store.addCPUTime(["Xcode": 12], at: Date())
        let apps = await withCheckedContinuation { done in
            store.topApps(since: Date().addingTimeInterval(-3_600)) { done.resume(returning: $0) }
        }
        #expect(apps.map(\.0) == ["Xcode", "Safari"])
        #expect(apps.first?.1 == 42)
    }
}
