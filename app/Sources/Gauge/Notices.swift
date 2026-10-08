import Foundation

/// Plain-language notices and the overview status line. Pure functions of a reading and how long
/// each condition has held, so the rules can be tested without sampling the Mac.
enum Notices {
    /// How long a condition must hold before it becomes a notice or flag.
    static let sustainSeconds: TimeInterval = 30

    static func sustained(_ since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= sustainSeconds
    }

    /// Less than 10% of the startup disk is free.
    static func diskLow(_ disk: DiskReading) -> Bool {
        disk.total > 0 && disk.available / disk.total < 0.1
    }

    static func build(reading r: Reading, now: Date, memoryWarningSince: Date?, busyApps: [String: Date],
                      servers allServers: [DevServer], previous: [Notice]) -> [Notice] {
        var list: [Notice] = []
        if let since = memoryWarningSince {
            let top = r.apps.filter { $0.name != "macOS" }.sorted { $0.memory > $1.memory }.prefix(2)
            let users = top.map { "\($0.name), \(Fmt.memoryText($0.memory))" }.joined(separator: ", and ")
            list.append(Notice(tag: "Memory", title: "Memory pressure is elevated",
                               body: users.isEmpty ? "macOS is compressing memory to keep up." : "The biggest users are \(users).",
                               hot: true, since: since, target: "Memory"))
        }
        for (name, since) in busyApps.sorted(by: { $0.key < $1.key }) where sustained(since, now: now) {
            let cpu = r.apps.first { $0.name == name }?.cpu ?? 0
            list.append(Notice(tag: "CPU", title: "\(name) is using a lot of CPU",
                               body: "\(Fmt.percent(cpu)) of one core for the last \(max(1, Int(now.timeIntervalSince(since) / 60))) min.",
                               hot: true, since: since, target: "CPU"))
        }
        if diskLow(r.disk) {
            list.append(Notice(tag: "Disk", title: "Your startup disk is almost full",
                               body: "\(Fmt.storageText(r.disk.available)) free of \(Fmt.storageText(r.disk.total)).",
                               hot: true, since: r.date, target: "Disk"))
        }
        let servers = allServers.filter(\.isDev)
        if !servers.isEmpty {
            let idle = servers.allSatisfy(\.idle)
            let count = servers.count == 1 ? "A dev server is" : "\(servers.count) dev servers are"
            let byRuntime = Dictionary(grouping: servers, by: \.name)
            let ports = byRuntime.keys.sorted().map { name in
                let list = byRuntime[name, default: []].flatMap(\.ports).sorted().map(String.init)
                return "\(name) on \(list.formatted(.list(type: .and)))"
            }
            .joined(separator: "; ")
            let memory = Fmt.memoryText(servers.map(\.memory).reduce(0, +))
            list.append(Notice(tag: "Projects", title: "\(count) running\(idle ? " but idle" : "")",
                               body: "\(ports). Together they use \(memory).",
                               hot: false, since: previous.first { $0.tag == "Projects" }?.since ?? r.date, target: "Projects"))
        }
        if let health = r.battery?.health, health < 80 {
            list.append(Notice(tag: "Battery", title: "Battery health is \(Fmt.percent(health))",
                               body: "Cycle count \(r.battery?.cycles ?? 0). Capacity is below 80% of its design.",
                               hot: false, since: r.date, target: "Battery"))
        }
        return list
    }

    static func status(vitals: [Vital]) -> [StatusItem] {
        let flagged = vitals.filter { $0.flag != nil }
        let names = flagged.map { v -> String in
            let flag = v.flag?.lowercased() ?? ""
            switch v.name {
            case "Memory": return "Memory pressure \(flag)"
            case "CPU": return "CPU load high"
            case "Disk": return "Startup disk low on space"
            case "Battery": return "Battery low"
            default: return "\(v.name) \(flag)"
            }
        }
        let normal = vitals.count - flagged.count
        if flagged.isEmpty { return [StatusItem(on: false, text: "All \(normal) readings normal")] }
        return names.map { StatusItem(on: true, text: $0) } + [StatusItem(on: false, text: "\(normal) readings normal")]
    }
}
