import Foundation
import SQLite3

/// Flight recorder tables. All additive (`IF NOT EXISTS`), so history files from earlier versions keep working.
///
/// - `moments`: the busiest apps for each 10-second `samples` row, as compact text (see `Moments.encode`).
/// - `app_names`: app names referenced by id from `moments`.
/// - `events`: sleep, wake, app launches and quits, thermal state changes.
/// - `daily`: one row a day of battery health, cycle count and startup-disk use, for long-term trends.
extension HistoryStore {
    static let recorderTables = ["moments", "app_names", "events", "daily"]
    /// Daily rows are tiny (one a day), so they're kept for two years regardless of the sample
    /// retention, which is what lets battery health show a trend over months. Clearing history removes them.
    static let trendDays = 730

    /// Runs on `queue` from init.
    func createRecorderTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS app_names (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
            CREATE TABLE IF NOT EXISTS moments (t INTEGER PRIMARY KEY, apps TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events (t INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS events_t ON events (t);
            CREATE TABLE IF NOT EXISTS daily (
                day INTEGER PRIMARY KEY, battery_health REAL, battery_cycles INTEGER, disk_used REAL, disk_total REAL);
            """)
    }

    /// Runs on `queue` from prune: moments and events follow the sample retention.
    func pruneRecorder(before cutoff: Int64) {
        for table in ["moments", "events"] {
            run("DELETE FROM \(table) WHERE t < ?") { s in sqlite3_bind_int64(s, 1, cutoff); _ = sqlite3_step(s) }
        }
        let trendCutoff = Int64(Date().timeIntervalSince1970) - Int64(Self.trendDays) * 86_400
        run("DELETE FROM daily WHERE day < ?") { s in sqlite3_bind_int64(s, 1, trendCutoff); _ = sqlite3_step(s) }
    }

    // MARK: Writes

    func insertMoment(t: Int, apps: [MomentApp]) {
        guard !apps.isEmpty else { return }
        queue.async { [self] in
            exec("BEGIN")
            var rows: [(id: Int64, cpu: Double, memory: Double)] = []
            for app in apps {
                run("INSERT INTO app_names (name) VALUES (?) ON CONFLICT(name) DO UPDATE SET name = excluded.name RETURNING id") { s in
                    sqlite3_bind_text(s, 1, app.name, -1, TRANSIENT)
                    if sqlite3_step(s) == SQLITE_ROW { rows.append((sqlite3_column_int64(s, 0), app.cpu, app.memory)) }
                }
            }
            run("INSERT OR REPLACE INTO moments VALUES (?, ?)") { s in
                sqlite3_bind_int64(s, 1, Int64(t))
                sqlite3_bind_text(s, 2, Moments.encode(rows), -1, TRANSIENT)
                _ = sqlite3_step(s)
            }
            exec("COMMIT")
        }
    }

    func addEvent(_ event: RecordedEvent) {
        queue.async { [self] in
            run("INSERT INTO events VALUES (?, ?, ?)") { s in
                sqlite3_bind_int64(s, 1, Int64(event.date.timeIntervalSince1970))
                sqlite3_bind_text(s, 2, event.kind.rawValue, -1, TRANSIENT)
                sqlite3_bind_text(s, 3, event.detail, -1, TRANSIENT)
                _ = sqlite3_step(s)
            }
        }
    }

    /// One row per day: later readings replace earlier ones, but a missing reading keeps the stored value.
    func upsertDay(_ record: DayRecord) {
        queue.async { [self] in
            run("""
                INSERT INTO daily VALUES (?, ?, ?, ?, ?) ON CONFLICT(day) DO UPDATE SET
                    battery_health = coalesce(excluded.battery_health, battery_health),
                    battery_cycles = coalesce(excluded.battery_cycles, battery_cycles),
                    disk_used = coalesce(excluded.disk_used, disk_used),
                    disk_total = coalesce(excluded.disk_total, disk_total)
                """) { s in
                sqlite3_bind_int64(s, 1, Int64(record.day.timeIntervalSince1970))
                bind(s, 2, record.batteryHealth)
                bind(s, 3, record.batteryCycles.map(Double.init))
                bind(s, 4, record.diskUsed)
                bind(s, 5, record.diskTotal)
                _ = sqlite3_step(s)
            }
        }
    }

    // MARK: Reads

    func events(from start: Date, to end: Date) async -> [RecordedEvent] {
        await read { [self] in
            var result: [RecordedEvent] = []
            run("SELECT t, kind, detail FROM events WHERE t >= ? AND t <= ? ORDER BY t") { s in
                sqlite3_bind_int64(s, 1, Int64(start.timeIntervalSince1970))
                sqlite3_bind_int64(s, 2, Int64(end.timeIntervalSince1970))
                while sqlite3_step(s) == SQLITE_ROW {
                    guard let kind = RecordedEvent.Kind(rawValue: String(cString: sqlite3_column_text(s, 1))) else { continue }
                    result.append(RecordedEvent(date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0))),
                                                kind: kind, detail: String(cString: sqlite3_column_text(s, 2))))
                }
            }
            return result
        }
    }

    /// The busiest apps over the moments saved in `start..<end`, and how many moments that covers.
    func moments(from start: Date, to end: Date) async -> (count: Int, apps: [MomentApp]) {
        await read { [self] in
            var names: [Int64: String] = [:]
            run("SELECT id, name FROM app_names") { s in
                while sqlite3_step(s) == SQLITE_ROW { names[sqlite3_column_int64(s, 0)] = String(cString: sqlite3_column_text(s, 1)) }
            }
            var moments: [[MomentApp]] = []
            run("SELECT apps FROM moments WHERE t >= ? AND t < ?") { s in
                sqlite3_bind_int64(s, 1, Int64(start.timeIntervalSince1970))
                sqlite3_bind_int64(s, 2, Int64(end.timeIntervalSince1970))
                while sqlite3_step(s) == SQLITE_ROW {
                    moments.append(Moments.decode(String(cString: sqlite3_column_text(s, 0))).compactMap { row in
                        names[row.id].map { MomentApp(name: $0, cpu: row.cpu, memory: row.memory) }
                    })
                }
            }
            return (moments.count, Moments.summarize(moments))
        }
    }

    func days(since: Date) async -> [DayRecord] {
        await read { [self] in
            var result: [DayRecord] = []
            run("SELECT day, battery_health, battery_cycles, disk_used, disk_total FROM daily WHERE day >= ? ORDER BY day") { s in
                sqlite3_bind_int64(s, 1, Int64(since.timeIntervalSince1970))
                while sqlite3_step(s) == SQLITE_ROW {
                    func value(_ i: Int32) -> Double? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i) }
                    result.append(DayRecord(day: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0))),
                                            batteryHealth: value(1), batteryCycles: value(2).map { Int($0) },
                                            diskUsed: value(3), diskTotal: value(4)))
                }
            }
            return result
        }
    }

    func spanStats(since: Date) async -> SpanStats {
        await read { [self] in
            var stats = SpanStats()
            run("SELECT avg(cpu), max(mem), max(mem_total), count(*) FROM samples WHERE t >= ?") { s in
                sqlite3_bind_int64(s, 1, Int64(since.timeIntervalSince1970))
                if sqlite3_step(s) == SQLITE_ROW {
                    func value(_ i: Int32) -> Double? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i) }
                    stats = SpanStats(averageCPU: value(0), peakMemory: value(1), memoryTotal: value(2),
                                      seconds: Double(sqlite3_column_int64(s, 3)) * 10)
                }
            }
            return stats
        }
    }

    // MARK: Helpers

    private func read<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: body()) } }
    }

    private func bind(_ s: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(s, index, value) } else { sqlite3_bind_null(s, index) }
    }
}

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
