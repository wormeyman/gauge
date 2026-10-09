import Foundation
import GaugeKit

/// "Let local tools read Gauge": an opt-in, read-only API on a Unix socket in
/// ~/Library/Application Support/Gauge that the `gauge` command and its MCP server use.
/// Only the current user can open the socket. There's no TCP listener and nothing leaves the Mac.
@MainActor
final class LocalAPI {
    static let shared = LocalAPI()
    static let enabledKey = "localAPIEnabled"

    /// The bundled command, or where it lives in an installed copy when running unbundled.
    static var commandPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gauge").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/Applications/Gauge.app/Contents/Helpers/gauge"
    }

    private weak var monitor: Monitor?
    private var server: UnixSocketServer?
    /// Why the socket couldn't open, for Settings.
    private(set) var problem: String?

    /// Called once the monitor starts. Snapshot runs never open the socket.
    func attach(_ monitor: Monitor) {
        self.monitor = monitor
        refresh()
    }

    /// Opens or closes the socket to match the setting.
    func refresh() {
        let on = UserDefaults.standard.bool(forKey: Self.enabledKey) && monitor != nil && Snapshot.folder == nil
        if on, server == nil {
            let server = UnixSocketServer(path: API.socketPath) { line in await LocalAPI.shared.respond(to: line) }
            do {
                try server.start()
                self.server = server
                problem = nil
            } catch {
                problem = error.description
            }
        } else if !on, let server {
            server.stop()
            self.server = nil
        }
    }

    func respond(to line: Data) async -> Data {
        let request: Request
        do {
            request = try Request(try JSON.parse(line))
        } catch let invalid as Request.Invalid {
            return API.failure(invalid.description)
        } catch {
            return API.failure("Each request is one JSON object on its own line, such as {\"method\":\"vitals\"}.")
        }
        guard let monitor, let reading = monitor.latest else {
            return API.failure("Gauge is still taking its first reading. Try again in a few seconds.")
        }
        switch request {
        case .vitals:
            return API.success(encoding: Self.vitals(reading, cores: monitor.sampler.cores, chip: monitor.sampler.chip))
        case .apps(let sort, let limit):
            let sorted = reading.apps.sorted { sort == "memory" ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            return API.success(encoding: TopApps(sortedBy: sort, processCount: reading.processCount, apps: sorted.prefix(limit).map {
                TopApps.App(name: $0.name, cpuPercent: Self.round($0.cpu, 1), memoryBytes: $0.memory.rounded())
            }))
        case .notices:
            let servers = await Task.detached { PortScan.devServers() }.value
            return API.success(encoding: NoticeList(notices: monitor.currentNotices(servers: servers).map {
                NoticeList.Notice(tag: $0.tag, title: $0.title, body: $0.body, needsAttention: $0.hot, since: $0.since)
            }))
        case .servers:
            // Scanned on request: Gauge only rescans ports while a window shows them.
            return await Task.detached { API.success(encoding: PortScan.servers()) }.value
        case .port(let port):
            return await Task.detached { API.success(encoding: PortScan.status(port)) }.value
        case .history(let metric, let minutes, let count):
            let points: [HistoryPoint] = await withCheckedContinuation { done in
                monitor.store.series(since: Date().addingTimeInterval(-Double(minutes) * 60), points: count) { done.resume(returning: $0) }
            }
            return API.success(encoding: HistorySeries(metric: metric, unit: Request.unit(of: metric), minutes: minutes,
                                                       points: points.compactMap { p in
                                                           Self.value(metric, p).map { .init(time: p.date, value: Self.round($0, 2)) }
                                                       }))
        }
    }

    nonisolated static func value(_ metric: String, _ p: HistoryPoint) -> Double? {
        switch metric {
        case "cpu": p.cpu
        case "memory": p.memoryUsed
        case "gpu": p.gpu
        case "download": p.download
        case "upload": p.upload
        case "disk_read": p.diskRead
        case "disk_write": p.diskWrite
        case "battery": p.battery
        default: nil
        }
    }

    nonisolated static func vitals(_ r: Reading, cores: Int, chip: String) -> Vitals {
        let m = r.memory
        let cpu = (r.cpuUser ?? 0) + (r.cpuSystem ?? 0)
        var unavailable = ["Temperatures and fans: reading sensors needs a privileged helper, which Gauge doesn't have."]
        if r.gpuUtilization == nil { unavailable.append("GPU load: this Mac's GPU doesn't report it.") }
        return Vitals(
            time: r.date,
            cpu: .init(percent: round(cpu, 1), userPercent: round(r.cpuUser ?? 0, 1), systemPercent: round(r.cpuSystem ?? 0, 1),
                       cores: cores, chip: chip),
            memory: .init(usedBytes: m.used, totalBytes: m.total, appBytes: m.app, wiredBytes: m.wired, compressedBytes: m.compressed,
                          cachedBytes: m.cached, freeBytes: m.free, swapUsedBytes: m.swapUsed,
                          pressure: m.pressure >= 4 ? "critical" : m.pressure >= 2 ? "elevated" : "normal"),
            gpu: .init(percent: r.gpuUtilization.map { round($0, 1) }, memoryBytes: r.gpuMemory),
            disk: .init(name: r.disk.name, totalBytes: r.disk.total, usedBytes: max(0, r.disk.total - r.disk.available),
                        availableBytes: r.disk.available, readBytesPerSecond: r.disk.readRate.rounded(),
                        writeBytesPerSecond: r.disk.writeRate.rounded()),
            network: .init(downloadBytesPerSecond: r.network.downRate.rounded(), uploadBytesPerSecond: r.network.upRate.rounded(),
                           receivedBytes: r.network.receivedSinceLaunch, sentBytes: r.network.sentSinceLaunch),
            battery: r.battery.map {
                .init(percent: round($0.percent, 1), charging: $0.charging, onPowerAdapter: $0.onAC, minutesToFull: $0.minutesToFull,
                      minutesToEmpty: $0.minutesToEmpty, watts: $0.watts.map { round($0, 1) }, healthPercent: $0.health.map { round($0, 1) },
                      cycleCount: $0.cycles)
            },
            unavailable: unavailable)
    }

    nonisolated static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}

/// On-demand port lookups for the local API. Only processes owned by this user can be inspected;
/// for the rest, a port counts as taken when it can't be bound.
enum PortScan {
    struct Listener { var pid: Int32; var command: String; var ports: [Int] }

    /// Every process this user can inspect that has a listening TCP socket.
    static func listeners() -> [Listener] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        return pids.prefix(found).compactMap { pid in
            guard pid > 0 else { return nil }
            let ports = Sampler.listeningPorts(pid)
            return ports.isEmpty ? nil : Listener(pid: pid, command: name(pid), ports: ports)
        }
    }

    /// Servers on dev runtimes, the way the Projects page finds them.
    static func devServers() -> [DevServer] {
        let found = listeners()
        let servers = Sampler.servers(from: found.flatMap { l in l.ports.map { Sampler.Listener(pid: l.pid, command: l.command, port: $0) } })
        let cpu = cpuPercent(servers.map(\.pid))
        return servers.map { s in
            var s = s
            s.folder = Sampler.workingFolder(s.pid)
            s.cpu = cpu[s.pid] ?? 0
            s.memory = footprint(s.pid)
            s.started = ProcessControl.startTime(s.pid) ?? 0
            return s
        }
    }

    static func servers() -> DevServers {
        DevServers(servers: devServers().map {
            .init(pid: Int($0.pid), runtime: $0.name, folder: $0.folder, ports: $0.ports, cpuPercent: LocalAPI.round($0.cpu, 1),
                  memoryBytes: $0.memory, idle: $0.idle, isDevServer: $0.isDev)
        })
    }

    static func status(_ port: Int) -> PortStatus {
        if let holder = listeners().first(where: { $0.ports.contains(port) }) {
            let folder = Sampler.workingFolder(holder.pid)
            let name = Sampler.appName(path: path(holder.pid), command: holder.command)
            let place = folder.isEmpty || folder == "/" ? "" : " in \(folder)"
            return PortStatus(port: port, free: false, holder: .init(pid: Int(holder.pid), name: name, folder: folder),
                              detail: "Port \(port) is in use by \(name) (pid \(holder.pid))\(place).")
        }
        if canBind(port) { return PortStatus(port: port, free: true, holder: nil, detail: "Port \(port) is free.") }
        return PortStatus(port: port, free: false, holder: nil,
                          detail: "Port \(port) is in use by a process Gauge can't inspect, such as one run by another user or with sudo.")
    }

    /// Binds (without listening or sending anything) on the loopback and wildcard addresses a dev server
    /// would use. A port that's in use on any of them isn't free.
    static func canBind(_ port: Int) -> Bool {
        func attempt(_ family: Int32, _ address: (inout sockaddr_storage) -> Void) -> Bool {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return true }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            if family == AF_INET6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size)) }
            var storage = sockaddr_storage()
            address(&storage)
            let length = socklen_t(storage.ss_len)
            let result = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
            }
            // No IPv6 loopback, say, isn't a sign the port is taken.
            return result == 0 || errno != EADDRINUSE
        }
        let p = in_port_t(port).bigEndian
        let v4: [UInt32] = [INADDR_LOOPBACK, INADDR_ANY]
        let v6 = [in6addr_loopback, in6addr_any]
        return v4.allSatisfy { host in
            attempt(AF_INET) { s in
                withUnsafeMutablePointer(to: &s) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                                 sin_port: p, sin_addr: in_addr(s_addr: host.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
                    }
                }
            }
        } && v6.allSatisfy { host in
            attempt(AF_INET6) { s in
                withUnsafeMutablePointer(to: &s) {
                    $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        $0.pointee = sockaddr_in6(sin6_len: UInt8(MemoryLayout<sockaddr_in6>.size), sin6_family: sa_family_t(AF_INET6),
                                                  sin6_port: p, sin6_flowinfo: 0, sin6_addr: host, sin6_scope_id: 0)
                    }
                }
            }
        }
    }

    /// CPU as percent of one core, measured over half a second.
    static func cpuPercent(_ pids: [Int32]) -> [Int32: Double] {
        guard !pids.isEmpty else { return [:] }
        // CPU time and the wall clock are both in Mach time units, so their ratio needs no conversion.
        func ticks() -> [Int32: UInt64] {
            var result: [Int32: UInt64] = [:]
            for pid in pids {
                var info = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size { result[pid] = info.pti_total_user + info.pti_total_system }
            }
            return result
        }
        let before = ticks(), start = mach_absolute_time()
        usleep(500_000)
        let after = ticks(), wall = Double(mach_absolute_time() - start)
        return after.reduce(into: [:]) { result, entry in
            guard let earlier = before[entry.key], entry.value >= earlier else { return }
            result[entry.key] = Double(entry.value - earlier) / wall * 100
        }
    }

    static func footprint(_ pid: Int32) -> Double {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        return ok ? Double(usage.ri_phys_footprint) : 0
    }

    static func name(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cBuffer: buffer)
    }

    static func path(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return String(cBuffer: buffer)
    }
}
