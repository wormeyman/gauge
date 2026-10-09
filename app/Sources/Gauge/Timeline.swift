import SwiftUI
import Charts

enum TimelineRange: Int, CaseIterable, Identifiable {
    case hour = 3600, sixHours = 21_600, day = 86_400, week = 604_800, month = 2_592_000
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        }
    }
    static let points = 360
    /// The width of one chart point, matching HistoryStore.series' buckets.
    var bucket: TimeInterval { max(10, Double(rawValue / Self.points)) }
}

/// Everything the timeline shows from the history store, apart from the focused moment.
struct TimelineData {
    var points: [HistoryPoint] = []
    var events: [RecordedEvent] = []
    var recordedSeconds: Double = 0
    var days: [DayRecord] = []
    var week = SpanStats()
    var busiest: (name: String, seconds: Double)?

    static func load(store: HistoryStore, range: TimelineRange, now: Date = Date()) async -> TimelineData {
        let start = now.addingTimeInterval(-Double(range.rawValue))
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        var data = TimelineData()
        data.points = await withCheckedContinuation { done in store.series(since: start, points: TimelineRange.points) { done.resume(returning: $0) } }
        data.events = await store.events(from: start, to: now)
        data.recordedSeconds = await store.spanStats(since: .distantPast).seconds
        data.days = await store.days(since: now.addingTimeInterval(-Double(HistoryStore.trendDays) * 86_400))
        data.week = await store.spanStats(since: weekStart)
        data.busiest = await withCheckedContinuation { done in
            store.topApps(since: weekStart, limit: 1) { done.resume(returning: $0.first.map { (name: $0.0, seconds: $0.1) }) }
        }
        return data
    }
}

/// The busiest apps over one chart point.
struct MomentFocus {
    var start: Date
    var end: Date
    /// Saved moments (10-second rows) the apps were averaged over.
    var count: Int
    var apps: [MomentApp]

    static func load(store: HistoryStore, at date: Date, range: TimelineRange) async -> MomentFocus {
        let end = date.addingTimeInterval(range.bucket)
        let result = await store.moments(from: date, to: end)
        return MomentFocus(start: date, end: end, count: result.count, apps: result.apps)
    }
}

/// History with context: CPU and memory over time, what happened (sleep, wake, apps opening and
/// quitting), and which apps were busiest at any moment. Plus long-term battery and disk trends.
struct TimelinePage: View {
    var store: HistoryStore
    var width: CGFloat
    var back: () -> Void
    /// Snapshot aid: the page was filled from made-up readings, and says so.
    var sample = false

    @State private var range: TimelineRange = .day
    @State private var data: TimelineData
    @State private var loaded: Bool
    /// The point under the pointer.
    @State private var hover: Date?
    /// The last point hovered or clicked; the moment panel stays on it after the pointer leaves.
    @State private var pinned: Date?
    @State private var focus: MomentFocus?

    init(store: HistoryStore, width: CGFloat, initial: TimelineData? = nil, pinned: Date? = nil, focus: MomentFocus? = nil,
         sample: Bool = false, back: @escaping () -> Void) {
        self.store = store
        self.width = width
        self.back = back
        self.sample = sample
        _data = State(initialValue: initial ?? TimelineData())
        _loaded = State(initialValue: initial != nil)
        _pinned = State(initialValue: pinned)
        _focus = State(initialValue: focus)
    }

    private var tone: Color { Theme.tone("Timeline") }
    private var cpuTone: Color { Theme.tone("CPU") }
    private var memoryTone: Color { Theme.tone("Memory") }
    private var wide: Bool { width >= 900 }

    /// The chart point the moment panel describes: hovered, else pinned, else the latest.
    private var focusPoint: HistoryPoint? {
        let points = data.points
        guard let target = hover ?? pinned else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chartBlock
            momentSection.padding(.top, 48)
            TimelineTrends(data: data, width: width).padding(.top, 64)
        }
        .task(id: range) {
            while !Task.isCancelled {
                data = await TimelineData.load(store: store, range: range)
                loaded = true
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .task(id: focusPoint?.date) {
            guard let date = focusPoint?.date else { focus = nil; return }
            if focus?.start == date { return }
            try? await Task.sleep(for: .milliseconds(60))  // let a sweeping pointer settle first
            guard !Task.isCancelled else { return }
            focus = await MomentFocus.load(store: store, at: date, range: range)
        }
        .onChange(of: range) { pinned = nil; hover = nil }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Button(action: back) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Overview")
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.soft).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to Overview (Esc)")
                Spacer()
                Segmented(options: TimelineRange.allCases.map { ($0, $0.label, nil) }, selection: $range, accessibilityName: "Timeline range")
            }
            .padding(.top, 24)
            HStack(spacing: 10) {
                Circle().fill(tone).frame(width: 9, height: 9)
                Text("Timeline").font(.system(size: 30, weight: .semibold)).tracking(-0.75)
                if sample {
                    Text("SAMPLE DATA").font(Theme.mono(10.5)).tracking(0.6).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line2))
                        .padding(.leading, 6)
                }
            }
            .padding(.top, 22)
            Text("CPU and memory over time, with what happened and which apps were busiest")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 4)
        }
    }

    // MARK: Chart

    private struct SleepSpan: Identifiable { var id: Date { start }; var start: Date; var end: Date }

    /// Sleep followed by a wake becomes a shaded span; anything unpaired stays a marker.
    private var sleepSpans: [SleepSpan] {
        var spans: [SleepSpan] = []
        var asleep: Date?
        for event in data.events {
            if event.kind == .sleep { asleep = event.date }
            if event.kind == .wake, let start = asleep { spans.append(SleepSpan(start: start, end: event.date)); asleep = nil }
        }
        return spans
    }

    /// Thermal changes and unpaired sleeps or wakes get a full-height rule. Labels are dropped where
    /// they would crowd the previous one.
    private var markers: [(event: RecordedEvent, labelled: Bool)] {
        let paired = Set(sleepSpans.flatMap { [$0.start, $0.end] })
        let gap = Double(range.rawValue) * 0.09
        var last = Date.distantPast
        return data.events.filter { ($0.kind == .thermal || $0.kind == .sleep || $0.kind == .wake) && !paired.contains($0.date) }
            .map { event in
                let labelled = event.date.timeIntervalSince(last) >= gap
                if labelled { last = event.date }
                return (event, labelled)
            }
    }

    private var appEvents: [RecordedEvent] { data.events.filter { $0.kind == .launch || $0.kind == .quit } }

    private var caption: String {
        guard let first = data.points.first?.date else { return "Stored on this Mac" }
        if Date().timeIntervalSince(first) < Double(range.rawValue) * 0.9 { return "Since \(Self.time(first, range)) · stored on this Mac" }
        return "Last \(range.label) · stored on this Mac"
    }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                legend(SeriesSwatch(color: cpuTone, dashed: false), "CPU")
                legend(SeriesSwatch(color: memoryTone, dashed: false), "Memory in use")
                legend(Rectangle().fill(Theme.raise2).frame(width: 14, height: 9).overlay(Rectangle().strokeBorder(Theme.line2)), "Asleep")
                legend(Rectangle().fill(Theme.muted).frame(width: 1, height: 9), "App opened or quit")
                Spacer()
                Text(caption).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            if data.points.count < 2 {
                Text(emptyMessage)
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                chart
                    .frame(height: 300)
                    .padding(.top, 30)
                    .accessibilityLabel("CPU and memory chart, \(range.label)")
            }
        }
        .padding(.top, 34)
        .padding(.bottom, 26)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var emptyMessage: String {
        if !loaded { return "Loading history…" }
        let minutes = Int(data.recordedSeconds / 60)
        let recorded = minutes == 0 ? "Gauge hasn't saved any readings yet."
            : minutes < 120 ? "Gauge has recorded \(minutes) minute\(minutes == 1 ? "" : "s") so far."
            : "Gauge has recorded \(minutes / 60) hours so far, but none in this range."
        return "\(recorded)\nReadings are saved every 10 seconds while it runs, and stay on this Mac."
    }

    private func legend(_ swatch: some View, _ name: String) -> some View {
        HStack(spacing: 7) {
            swatch
            Text(name).font(.system(size: 12)).foregroundStyle(Theme.soft)
        }
    }

    private var chart: some View {
        let now = Date()
        let start = now.addingTimeInterval(-Double(range.rawValue))
        let focused = hover != nil || pinned != nil ? focusPoint : nil
        return Chart {
            ForEach(sleepSpans) { span in
                RectangleMark(xStart: .value("Time", max(span.start, start)), xEnd: .value("Time", span.end),
                              yStart: .value("Load", 0), yEnd: .value("Load", 100))
                    .foregroundStyle(Theme.raise2)
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 0) {
                        if span.end.timeIntervalSince(max(span.start, start)) > Double(range.rawValue) * 0.06 {
                            Text("Asleep").font(Theme.mono(10)).foregroundStyle(Theme.muted).padding(6)
                        }
                    }
            }
            ForEach(segmented, id: \.point.date) { p, segment in
                AreaMark(x: .value("Time", p.date), y: .value("Load", p.cpu), series: .value("Series", "CPU \(segment)"))
                    .foregroundStyle(cpuTone.opacity(0.12))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Load", p.cpu), series: .value("Series", "CPU \(segment)"))
                    .foregroundStyle(cpuTone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Load", memoryPercent(p)), series: .value("Series", "Memory \(segment)"))
                    .foregroundStyle(memoryTone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(appEvents) { event in
                RuleMark(x: .value("Time", event.date), yStart: .value("Load", 0), yEnd: .value("Load", 5))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(markers, id: \.event.id) { marker in
                RuleMark(x: .value("Time", marker.event.date))
                    .foregroundStyle(marker.event.kind == .thermal && Self.hot(marker.event) ? Theme.signal.opacity(0.7) : Theme.line2)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading, spacing: 4) {
                        if marker.labelled {
                            Text(marker.event.label).font(Theme.mono(10))
                                .foregroundStyle(marker.event.kind == .thermal && Self.hot(marker.event) ? Theme.signal : Theme.muted)
                                .fixedSize()
                        }
                    }
            }
            if let focused {
                RuleMark(x: .value("Time", focused.date))
                    .foregroundStyle(Theme.soft)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", focused.date), y: .value("Load", focused.cpu))
                    .symbol(.square).symbolSize(36).foregroundStyle(cpuTone)
                PointMark(x: .value("Time", focused.date), y: .value("Load", memoryPercent(focused)))
                    .symbol(.square).symbolSize(36).foregroundStyle(memoryTone)
            }
        }
        .chartXSelection(value: $hover)
        .onChange(of: hover) { if let hover { pinned = hover } }
        .chartXScale(domain: start...now)
        .chartYScale(domain: 0...100)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))%").font(Theme.mono(10)).foregroundStyle(Theme.faint) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Theme.line)
                AxisValueLabel(format: range.rawValue >= TimelineRange.week.rawValue ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute())
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            }
        }
    }

    /// Points numbered by unbroken stretch, so the lines stop where Gauge wasn't recording (asleep or not running)
    /// instead of drawing a straight line across the gap.
    private var segmented: [(point: HistoryPoint, segment: Int)] {
        var segment = 0
        var previous: Date?
        return data.points.map { p in
            if let previous, p.date.timeIntervalSince(previous) > range.bucket * 3 + 30 { segment += 1 }
            previous = p.date
            return (p, segment)
        }
    }

    private func memoryPercent(_ p: HistoryPoint) -> Double {
        p.memoryTotal > 0 ? min(100, p.memoryUsed / p.memoryTotal * 100) : 0
    }

    static func hot(_ event: RecordedEvent) -> Bool { event.detail == "Serious" || event.detail == "Critical" }

    static func time(_ date: Date, _ range: TimelineRange) -> String {
        range.rawValue >= TimelineRange.day.rawValue && !Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : Fmt.clock(date)
    }

    // MARK: What was running

    private var momentSection: some View {
        let point = focusPoint
        return VStack(spacing: 0) {
            SectionHeader(title: "What was running") {
                if let point {
                    HStack(spacing: 14) {
                        if pinned != nil && hover == nil {
                            Button("Latest") { pinned = nil }.buttonStyle(.plain)
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .help("Show the most recent moment")
                        }
                        Text("At \(Self.time(point.date, range))").font(Theme.mono(12)).foregroundStyle(Theme.soft)
                    }
                }
            }
            if let point {
                momentReadout(point)
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    appColumn("Top apps by CPU", apps: focusApps(byCPU: true), tint: cpuTone, first: true) { String(format: "%.1f%%", $0.cpu) }
                    Hairline(axis: wide ? .vertical : .horizontal)
                    appColumn("Top apps by memory", apps: focusApps(byCPU: false), tint: memoryTone) { Fmt.memoryText($0.memory) }
                    Hairline(axis: wide ? .vertical : .horizontal)
                    nearbyColumn(point.date)
                }
                .fixedSize(horizontal: false, vertical: true)
                Hairline()
            } else {
                Text("Nothing recorded in this range yet. Hover over the chart once it fills in to see which apps were busiest.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 22)
            }
        }
    }

    private func momentReadout(_ point: HistoryPoint) -> some View {
        let averaged = range.bucket > 10 ? "Averaged over \(Self.span(range.bucket))" : "One 10-second reading"
        return HStack(spacing: 36) {
            stat("CPU", Fmt.percent(point.cpu))
            stat("Memory in use", Fmt.memoryText(point.memoryUsed))
            stat("GPU", Fmt.percent(point.gpu))
            Spacer()
            Text(averaged).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
        .padding(.top, 18)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(15))
        }
    }

    private func focusApps(byCPU: Bool) -> [MomentApp] {
        guard let focus, focus.start == focusPoint?.date else { return [] }
        let sorted = byCPU ? focus.apps.filter { $0.cpu >= 0.05 }.sorted { $0.cpu > $1.cpu } : focus.apps.sorted { $0.memory > $1.memory }
        return Array(sorted.prefix(Moments.topCount))
    }

    private func appColumn(_ title: String, apps: [MomentApp], tint: Color, first: Bool = false, value: @escaping (MomentApp) -> String) -> some View {
        let top = apps.first.map { title.contains("CPU") ? $0.cpu : $0.memory } ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if apps.isEmpty {
                Text(focus?.start == focusPoint?.date ? "No app readings were saved for this moment." : "Loading…")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
            VStack(spacing: 0) {
                ForEach(apps, id: \.name) { app in
                    let amount = title.contains("CPU") ? app.cpu : app.memory
                    HStack(spacing: 12) {
                        Text(app.name).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.line2)
                            Rectangle().fill(tint).frame(width: 64 * amount / max(top, 0.001))
                        }
                        .frame(width: 64, height: 2)
                        Text(value(app)).font(Theme.mono(12)).foregroundStyle(Theme.soft).frame(width: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 22)
        .padding(.leading, wide && !first ? 28 : 0)
        .padding(.trailing, wide ? 28 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Events within a few chart points of the moment.
    private func nearbyColumn(_ date: Date) -> some View {
        let window = max(600, range.bucket * 6)
        let nearby = data.events.filter { abs($0.date.timeIntervalSince(date)) <= window }
            .sorted { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            .prefix(6)
            .sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nearby").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("within \(Self.span(window))").font(Theme.mono(11)).foregroundStyle(Theme.faint)
            }
            if nearby.isEmpty {
                Text("No sleep, wake, app or thermal changes recorded.").font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
            VStack(spacing: 0) {
                ForEach(Array(nearby), id: \.id) { event in
                    HStack(spacing: 12) {
                        Text(Self.time(event.date, range)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            .frame(width: wide ? 92 : 110, alignment: .leading)
                        Text(event.label).font(.system(size: 13)).lineLimit(1)
                            .foregroundStyle(event.kind == .thermal && Self.hot(event) ? Theme.signal : Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 22)
        .padding(.leading, wide ? 28 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 120 { return "\(minutes / 60) hours" }
        if minutes >= 1 { return "\(minutes) min" }
        return "\(Int(seconds)) s"
    }
}

// MARK: Trends

/// Long-term battery health and disk use (one reading a day), and a digest of the last seven days.
struct TimelineTrends: View {
    var data: TimelineData
    var width: CGFloat

    private var wide: Bool { width >= 900 }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Trends")
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                battery.padding(.trailing, wide ? 28 : 0)
                Hairline(axis: wide ? .vertical : .horizontal)
                disk.padding(.horizontal, wide ? 28 : 0)
                Hairline(axis: wide ? .vertical : .horizontal)
                week.padding(.leading, wide ? 28 : 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            Hairline()
        }
    }

    private struct Point: Identifiable { var id: Date { date }; var date: Date; var value: Double }

    private var health: [Point] { data.days.compactMap { d in d.batteryHealth.map { Point(date: d.day, value: $0) } } }
    private var diskUsed: [Point] { data.days.compactMap { d in d.diskUsed.map { Point(date: d.day, value: $0) } } }

    private var battery: some View {
        let points = health
        let latest = data.days.last { $0.batteryHealth != nil }
        return column(title: "Battery health") {
            if let latest, let value = latest.batteryHealth {
                headline(String(format: "%.0f", value), "% of design capacity")
                Text(batteryCaption(points, cycles: latest.batteryCycles)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                trend(points, tint: Theme.tone("Battery"), format: { String(format: "%.0f%%", $0) }, floor: 0.5)
            } else {
                Text(data.days.isEmpty ? "Gauge saves one reading a day; the trend appears after a few days."
                     : "No battery readings. This Mac may not have a battery.")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
        }
    }

    private func batteryCaption(_ points: [Point], cycles: Int?) -> String {
        var parts: [String] = []
        if let cycles { parts.append("\(cycles) cycles") }
        if let first = points.first, let last = points.last, points.count > 1 {
            let change = last.value - first.value
            parts.append(abs(change) < 0.5 ? "steady since \(Self.day(first.date))"
                         : String(format: "%+.0f%% since %@", change, Self.day(first.date)))
        }
        return parts.joined(separator: " · ")
    }

    private var disk: some View {
        let points = diskUsed
        return column(title: "Startup disk used") {
            if let last = points.last {
                let (value, unit) = Fmt.storage(last.value)
                headline(value, unit + (data.days.last?.diskTotal.map { " of \(Fmt.storageText($0))" } ?? ""))
                Text(diskCaption(points)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                trend(points, tint: Theme.tone("Disk"), format: { Fmt.storageText($0) }, floor: 5e9)
            } else {
                Text("Gauge saves one reading a day; the trend appears after a few days.")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
        }
    }

    /// "+18 GB in the last 30 days", or since the first reading when there's less than that.
    private func diskCaption(_ points: [Point]) -> String {
        guard let last = points.last, points.count > 1 else { return "First reading today" }
        let monthAgo = last.date.addingTimeInterval(-30 * 86_400)
        let base = points.last { $0.date <= monthAgo } ?? points[0]
        let change = Self.change(last.value - base.value)
        return base.date <= monthAgo ? "\(change) in the last 30 days" : "\(change) since \(Self.day(base.date))"
    }

    private var week: some View {
        let w = data.week
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let disk = diskUsed
        let diskChange: String = {
            guard let last = disk.last, let base = disk.last(where: { $0.date <= weekAgo }) ?? disk.first, base.date < last.date else {
                return "Not enough days yet"
            }
            return Self.change(last.value - base.value)
        }()
        let peak = w.peakMemory.map { peak in Fmt.memoryText(peak) + (w.memoryTotal.map { " of \(Int($0 / 1_073_741_824)) GB" } ?? "") }
        return column(title: "This week") {
            if w.seconds == 0 {
                Text("Nothing recorded in the last seven days.").font(.system(size: 13)).foregroundStyle(Theme.faint)
            } else {
                Readings(stats: [
                    Stat(label: "Average CPU", value: w.averageCPU.map(Fmt.percent) ?? "–"),
                    Stat(label: "Busiest app", value: data.busiest.map { "\($0.name) · \(Fmt.cpuTime($0.seconds))" } ?? "–"),
                    Stat(label: "Peak memory", value: peak ?? "–"),
                    Stat(label: "Disk change", value: diskChange),
                    Stat(label: "Recorded", value: Self.hours(w.seconds)),
                ], size: 13)
                .padding(.top, 4)
                Text("Busiest app is by CPU time, from the last seven days of history on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Pieces

    private func column(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.bottom, 10)
            content()
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func headline(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(Theme.mono(44, .light)).tracking(-1.5)
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(.bottom, 6)
    }

    /// A small daily line. The scale hugs the data (with at least `floor` of room) so slow change is visible.
    @ViewBuilder
    private func trend(_ points: [Point], tint: Color, format: @escaping (Double) -> String, floor: Double) -> some View {
        if points.count < 2 {
            Text("One reading a day; the line appears after a second day.")
                .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 18)
        } else {
            let low = points.map(\.value).min() ?? 0, high = points.map(\.value).max() ?? 1
            let pad = max((high - low) * 0.25, floor)
            Chart(points) { p in
                LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .interpolationMethod(.stepEnd)
            }
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartYAxis {
                AxisMarks(position: .trailing, values: [low, high]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.line)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(format(v)).font(Theme.mono(10)).foregroundStyle(Theme.faint) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                }
            }
            .frame(height: 110)
            .padding(.top, 18)
        }
    }

    static func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    static func change(_ bytes: Double) -> String {
        abs(bytes) < 1e8 ? "No change" : (bytes > 0 ? "+" : "−") + Fmt.storageText(abs(bytes))
    }

    static func hours(_ seconds: Double) -> String {
        seconds >= 7200 ? "\(Int(seconds / 3600)) hours" : "\(Int(seconds / 60)) min"
    }
}

// MARK: Snapshot

@MainActor
enum TimelineSnapshot {
    /// The page with its data loaded up front (ImageRenderer doesn't run tasks). With
    /// GAUGE_SNAPSHOT_DEMO=1 it reads a temporary store of made-up readings, never the real history.
    static func page(monitor: Monitor, width: CGFloat, hover: Double?) async -> TimelinePage {
        let demo = TimelineDemo.requested
        let store = demo ? TimelineDemo.store() : monitor.store
        let range = TimelineRange.day
        let data = await TimelineData.load(store: store, range: range)
        let point = hover.flatMap { f in data.points.isEmpty ? nil : data.points[min(data.points.count - 1, Int(Double(data.points.count - 1) * f))] }
            ?? data.points.last
        var focus: MomentFocus?
        if let point { focus = await MomentFocus.load(store: store, at: point.date, range: range) }
        return TimelinePage(store: store, width: width, initial: data, pinned: hover == nil ? nil : point?.date,
                            focus: focus, sample: demo, back: {})
    }
}
