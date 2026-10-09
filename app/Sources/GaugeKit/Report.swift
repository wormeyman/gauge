import Foundation

/// Plain-text tables for the `gauge` command. Columns are padded for a monospaced terminal.
public enum Report {
    public static func vitals(_ v: Vitals) -> String {
        var rows: [[String]] = [
            ["CPU", percent(v.cpu.percent), "user \(percent(v.cpu.userPercent)) · system \(percent(v.cpu.systemPercent)) · \(v.cpu.cores) cores"],
            ["Memory", bytes(v.memory.usedBytes), "of \(bytes(v.memory.totalBytes)) · pressure \(v.memory.pressure) · swap \(bytes(v.memory.swapUsedBytes))"],
            ["GPU", v.gpu.percent.map(percent) ?? "unavailable", v.gpu.memoryBytes.map { "\(bytes($0)) in use" } ?? ""],
            ["Disk", storage(v.disk.usedBytes), "used of \(storage(v.disk.totalBytes)) · \(storage(v.disk.availableBytes)) free · read \(rate(v.disk.readBytesPerSecond)) · write \(rate(v.disk.writeBytesPerSecond))"],
            ["Network", rate(v.network.downloadBytesPerSecond), "down · \(rate(v.network.uploadBytesPerSecond)) up"],
        ]
        if let b = v.battery {
            let state = b.charging ? "charging" : b.onPowerAdapter ? "on power adapter" : "on battery"
            var detail = [state]
            if b.charging, let m = b.minutesToFull { detail.append("\(minutes(m)) until full") }
            if !b.charging, !b.onPowerAdapter, let m = b.minutesToEmpty { detail.append("\(minutes(m)) left") }
            if let h = b.healthPercent { detail.append("health \(percent(h))") }
            rows.append(["Battery", percent(b.percent), detail.joined(separator: " · ")])
        } else {
            rows.append(["Battery", "none", "on power adapter"])
        }
        var text = table(rows)
        for note in v.unavailable { text += "\nUnavailable: \(note)" }
        return text
    }

    public static func apps(_ a: TopApps) -> String {
        guard !a.apps.isEmpty else { return "No apps to show." }
        let rows = a.apps.map { [$0.name, String(format: "%.1f%%", $0.cpuPercent), bytes($0.memoryBytes)] }
        return table([["APP", "CPU", "MEMORY"]] + rows, rightAligned: [1, 2])
            + "\n\(a.processCount) processes · CPU is percent of one core · sorted by \(a.sortedBy)"
    }

    public static func servers(_ s: DevServers) -> String {
        guard !s.servers.isEmpty else { return "No dev servers are listening." }
        let rows = s.servers.map {
            [String($0.pid), $0.runtime, $0.ports.map(String.init).joined(separator: ", "), $0.folder.isEmpty ? "–" : $0.folder,
             String(format: "%.1f%%", $0.cpuPercent), bytes($0.memoryBytes), $0.idle ? "idle" : "busy"]
        }
        return table([["PID", "RUNTIME", "PORTS", "FOLDER", "CPU", "MEMORY", ""]] + rows, rightAligned: [0, 4, 5])
    }

    public static func port(_ p: PortStatus) -> String { p.detail }

    public static func notices(_ n: NoticeList) -> String {
        guard !n.notices.isEmpty else { return "Nothing worth a look right now." }
        return n.notices.map { "\($0.needsAttention ? "!" : "·") \($0.tag.padding(toLength: 9, withPad: " ", startingAt: 0)) \($0.title)\n            \($0.body)" }
            .joined(separator: "\n")
    }

    public static func history(_ h: HistorySeries, now: Date = Date()) -> String {
        guard let summary = h.summary else { return "No \(h.metric) history in the last \(minutes(h.minutes)). Gauge records history while it's running." }
        let format = formatter(h.unit)
        let time = DateFormatter()
        time.dateFormat = h.minutes > 1440 ? "MMM d HH:mm" : "HH:mm"
        let peak = max(summary.max, h.unit == "percent" ? 100 : summary.max, 1e-9)
        let rows = h.points.map { p -> [String] in
            let width = Int((p.value / peak * 30).rounded())
            return [time.string(from: p.time), format(p.value), String(repeating: "█", count: max(0, min(30, width)))]
        }
        return table([["TIME", h.metric.uppercased(), ""]] + rows, rightAligned: [1])
            + "\nmin \(format(summary.min)) · average \(format(summary.average)) · max \(format(summary.max)) over the last \(minutes(h.minutes))"
    }

    // MARK: Formatting

    static func formatter(_ unit: String) -> (Double) -> String {
        switch unit {
        case "percent": percent
        case "bytes": bytes
        default: rate
        }
    }

    public static func percent(_ value: Double) -> String { value < 10 && value > 0 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value) }

    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return String(format: "%.0f B", v) }
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    public static func rate(_ value: Double) -> String { bytes(value) + "/s" }

    /// Disk sizes in decimal units, as Finder shows them.
    public static func storage(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: i == 0 || v >= 10 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    public static func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        if m % 60 == 0 { return m >= 1440 && m % 1440 == 0 ? "\(m / 1440) d" : "\(m / 60) h" }
        return "\(m / 60) h \(m % 60) min"
    }

    /// Pads columns to their widest cell, two spaces apart.
    public static func table(_ rows: [[String]], rightAligned: Set<Int> = []) -> String {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { c in rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { c, cell in
                let pad = String(repeating: " ", count: max(0, widths[c] - cell.count))
                return rightAligned.contains(c) ? pad + cell : (c == row.count - 1 ? cell : cell + pad)
            }
            .joined(separator: "  ")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        .joined(separator: "\n")
    }
}
