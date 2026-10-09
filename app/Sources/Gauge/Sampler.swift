import Foundation
import Darwin
import IOKit
import IOKit.ps
import CoreAudio

// Raw readings from public macOS counters. Nothing here needs elevated privileges,
// and nothing leaves the Mac.

struct MemoryReading {
    var total: Double = 0, app: Double = 0, wired: Double = 0, compressed: Double = 0
    var cached: Double = 0, free: Double = 0, swapUsed: Double = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressure: Int = 1
    var used: Double { app + wired + compressed }
}

struct DiskReading {
    var name = "Macintosh HD"
    var total: Double = 0, available: Double = 0
    var readRate: Double = 0, writeRate: Double = 0
    var writtenSinceLaunch: Double = 0
}

struct NetworkReading {
    var downRate: Double = 0, upRate: Double = 0
    var receivedSinceLaunch: Double = 0, sentSinceLaunch: Double = 0
}

struct BatteryReading {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var watts: Double?
    var health: Double?
    var cycles: Int?
}

struct AppUsage: Identifiable, Hashable {
    var id: String { name }
    var name: String
    /// Percent of one core, like Activity Monitor.
    var cpu: Double
    var memory: Double
    /// Lifetime CPU seconds of the app's running processes.
    var cpuTime: Double
}

struct DevServer: Identifiable, Hashable {
    var id: String { "\(pid)" }
    var pid: Int32
    var name: String
    var folder: String
    var ports: [Int]
    var cpu: Double
    var memory: Double
    /// False for servers that run on a dev runtime but aren't dev servers, such as a Minecraft server on Java.
    var isDev = true
    /// Process start time, so stopping a server never signals a reused PID.
    var started: UInt64 = 0
    /// Full path of the working folder that `folder` names.
    var path = ""
    var idle: Bool { cpu < 1 }
}

/// Gauge's own CPU and memory, so its cost is visible.
struct SelfUsage: Hashable {
    var cpu: Double = 0
    var memory: Double = 0
}

struct Reading {
    var date = Date()
    var cpuUser: Double?
    var cpuSystem: Double?
    var memory = MemoryReading()
    var gpuUtilization: Double?
    var gpuMemory: Double?
    var disk = DiskReading()
    var network = NetworkReading()
    var battery: BatteryReading?
    var apps: [AppUsage] = []
    var processCount = 0
    var selfUsage = SelfUsage()
    /// CPU seconds each app used since the previous reading, for the history store.
    var cpuSecondsDelta: [String: Double] = [:]
    /// Nil when the listening-port scan did not run this tick.
    var servers: [DevServer]?
    var audioPlaying = false
    var audioDevice: String?
    var accessories: [(name: String, percent: Int)] = []
    /// macOS's public thermal state. Temperatures themselves need a privileged helper.
    var thermal: ProcessInfo.ThermalState = .nominal
}

/// Samples system counters. Not thread-safe: Monitor only uses it from one serial queue.
final class Sampler: @unchecked Sendable {
    private var previousCPU: [UInt64]?
    private var previousNetwork: (down: UInt64, up: UInt64, at: Date)?
    private var networkBase: (down: UInt64, up: UInt64)?
    private var previousDisk: (read: UInt64, write: UInt64, at: Date)?
    private var diskWriteBase: UInt64?
    private var previousProcesses: [Int32: UInt64] = [:]
    private var previousProcessWall: UInt64 = 0
    /// App and command names by PID, so a process's path is only looked up and parsed once.
    private var names: [Int32: ProcessName] = [:]
    private var lastVolumeCheck = Date.distantPast
    private var volume: (name: String, total: Double, available: Double) = ("Macintosh HD", 0, 0)
    private var lastServerScan = Date.distantPast
    private var gpuService: io_object_t = 0
    private var batteryService: io_object_t = 0
    private var lastBatteryHealthCheck = Date.distantPast
    private var batteryHealth: (health: Double?, cycles: Int?) = (nil, nil)
    private var audio: (playing: Bool, device: String?) = (false, nil)
    private var accessories: [(name: String, percent: Int)] = []
    /// False while no Gauge window or panel is visible. Readings only shown on screen (audio,
    /// accessories, dev servers) then keep their last values instead of being sampled.
    var detail = true
    private let ownPID = getpid()
    /// Bytes per page for host_statistics64 counts (vm_kernel_page_size isn't concurrency-safe to read).
    private let pageSize = Double(Sampler.sysctlInt64("vm.pagesize") ?? 16_384)
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    let memoryTotal: Double = Double(Sampler.sysctlInt64("hw.memsize") ?? 0)
    let cores: Int = Int(Sampler.sysctlInt64("hw.ncpu") ?? 0)
    let chip: String = Sampler.sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"

    func read() -> Reading {
        var r = Reading()
        let priming = previousCPU == nil  // the first read only seeds counters; its result is discarded
        if let cpu = readCPU() { r.cpuUser = cpu.user; r.cpuSystem = cpu.system }
        r.memory = readMemory()
        if let gpu = readGPU() { r.gpuUtilization = gpu.utilization; r.gpuMemory = gpu.memory }
        r.disk = readDisk(now: r.date)
        r.network = readNetwork(now: r.date)
        r.battery = readBattery()
        let processes = readProcesses()
        r.apps = processes.apps
        r.processCount = processes.count
        r.cpuSecondsDelta = processes.cpuDelta
        if let own = processes.byPID[ownPID] { r.selfUsage = SelfUsage(cpu: own.cpu, memory: own.memory) }
        if !priming, detail, r.date.timeIntervalSince(lastServerScan) >= 15 {
            lastServerScan = r.date
            r.servers = scanDevServers(processes: processes.byPID)
        }
        if detail {
            audio = readAudio()
            accessories = readAccessoryBatteries()
        }
        r.audioPlaying = audio.playing
        r.audioDevice = audio.device
        r.accessories = accessories
        r.thermal = ProcessInfo.processInfo.thermalState
        return r
    }

    // MARK: CPU

    private func readCPU() -> (user: Double, system: Double)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var totals: [UInt64] = [0, 0, 0, 0]  // user, system, idle, nice
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            totals[0] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            totals[1] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            totals[2] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            totals[3] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        defer { previousCPU = totals }
        guard let previous = previousCPU else { return nil }
        let d = zip(totals, previous).map { $0 >= $1 ? Double($0 - $1) : 0 }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return ((d[0] + d[3]) / total * 100, d[1] / total * 100)
    }

    // MARK: Memory

    private func readMemory() -> MemoryReading {
        var m = MemoryReading(total: memoryTotal)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = pageSize
            m.app = Double(stats.internal_page_count &- stats.purgeable_count) * page
            m.wired = Double(stats.wire_count) * page
            m.compressed = Double(stats.compressor_page_count) * page
            m.cached = Double(stats.external_page_count + stats.purgeable_count) * page
            m.free = max(0, memoryTotal - m.used - m.cached)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = Double(swap.xsu_used) }
        m.pressure = Int(Sampler.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
        return m
    }

    // MARK: GPU

    private func readGPU() -> (utilization: Double, memory: Double)? {
        if gpuService != 0, let reading = Sampler.gpuStatistics(gpuService) { return reading }
        // First read, or the cached accelerator stopped answering: find the one that reports statistics.
        if gpuService != 0 { IOObjectRelease(gpuService); gpuService = 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let reading = Sampler.gpuStatistics(entry) {
                gpuService = entry
                return reading
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    private static func gpuStatistics(_ entry: io_object_t) -> (utilization: Double, memory: Double)? {
        // NSDictionary reads the registry's CFDictionary in place instead of bridging every entry.
        guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSDictionary,
            let utilization = (stats["Device Utilization %"] as? NSNumber) ?? (stats["GPU Activity(%)"] as? NSNumber) else { return nil }
        return (utilization.doubleValue, (stats["In use system memory"] as? NSNumber)?.doubleValue ?? 0)
    }

    // MARK: Disk

    private func readDisk(now: Date) -> DiskReading {
        if now.timeIntervalSince(lastVolumeCheck) >= 15 {
            lastVolumeCheck = now
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                volume = (v.volumeName ?? "Macintosh HD",
                          Double(v.volumeTotalCapacity ?? 0),
                          Double(v.volumeAvailableCapacityForImportantUsage ?? 0))
            }
        }
        var d = DiskReading(name: volume.name, total: volume.total, available: volume.available)
        var read: UInt64 = 0, write: UInt64 = 0
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSDictionary {
                    read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        if diskWriteBase == nil { diskWriteBase = write }
        d.writtenSinceLaunch = Double(write &- (diskWriteBase ?? write))
        if let p = previousDisk {
            let seconds = max(0.001, now.timeIntervalSince(p.at))
            d.readRate = read >= p.read ? Double(read - p.read) / seconds : 0
            d.writeRate = write >= p.write ? Double(write - p.write) / seconds : 0
        }
        previousDisk = (read, write, now)
        return d
    }

    // MARK: Network

    private func readNetwork(now: Date) -> NetworkReading {
        var n = NetworkReading()
        let (down, up) = Sampler.interfaceBytes()
        if networkBase == nil { networkBase = (down, up) }
        if let base = networkBase {
            n.receivedSinceLaunch = Double(down &- base.down)
            n.sentSinceLaunch = Double(up &- base.up)
        }
        if let p = previousNetwork {
            let seconds = max(0.001, now.timeIntervalSince(p.at))
            n.downRate = down >= p.down ? Double(down - p.down) / seconds : 0
            n.upRate = up >= p.up ? Double(up - p.up) / seconds : 0
        }
        previousNetwork = (down, up, now)
        return n
    }

    /// 64-bit byte counters for physical interfaces (Wi-Fi, Ethernet, cellular).
    private static func interfaceBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var down: UInt64 = 0, up: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                let linkOffset = offset + MemoryLayout<if_msghdr2>.size
                if header.ifm_type == UInt8(RTM_IFINFO2), linkOffset + MemoryLayout<sockaddr_dl>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    // The interface's name follows in a link-level address, so no lookup by index is needed.
                    let link = raw.loadUnaligned(fromByteOffset: linkOffset, as: sockaddr_dl.self)
                    let nameStart = linkOffset + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
                    let nameEnd = nameStart + Int(link.sdl_nlen)
                    if link.sdl_family == UInt8(AF_LINK), nameEnd <= length {
                        let name = UnsafeRawBufferPointer(rebasing: raw[nameStart..<nameEnd])
                        if name.starts(with: "en".utf8) || name.starts(with: "pdp_ip".utf8) {
                            down += info.ifm_data.ifi_ibytes
                            up += info.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (down, up)
    }

    // MARK: Battery

    private func readBattery() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? NSDictionary,
                  (d["Type"] as? String) == "InternalBattery" else { continue }
            let current = (d["Current Capacity"] as? Int) ?? 0
            let maximum = max(1, (d["Max Capacity"] as? Int) ?? 100)
            var b = BatteryReading(percent: Double(current) / Double(maximum) * 100,
                                   charging: (d["Is Charging"] as? Bool) ?? false,
                                   onAC: (d["Power Source State"] as? String) == "AC Power")
            if let full = d["Time to Full Charge"] as? Int, full > 0 { b.minutesToFull = full }
            if let empty = d["Time to Empty"] as? Int, empty > 0 { b.minutesToEmpty = empty }
            if batteryService == 0 {
                batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            }
            if batteryService != 0 {
                // Individual properties: the full AppleSmartBattery dictionary is large and slow to copy.
                func number(_ key: String) -> NSNumber? {
                    IORegistryEntryCreateCFProperty(batteryService, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
                }
                if let volts = number("Voltage")?.doubleValue, let amps = (number("InstantAmperage") ?? number("Amperage"))?.int64Value {
                    b.watts = abs(volts * Double(amps)) / 1_000_000
                }
                // Capacity and cycle count change over weeks, so they're read once a minute.
                if Date().timeIntervalSince(lastBatteryHealthCheck) >= 60 {
                    lastBatteryHealthCheck = Date()
                    var health: Double?
                    if let raw = number("AppleRawMaxCapacity")?.doubleValue, let design = number("DesignCapacity")?.doubleValue, design > 0 {
                        health = min(100, raw / design * 100)
                    }
                    batteryHealth = (health, number("CycleCount")?.intValue)
                }
                b.health = batteryHealth.health
                b.cycles = batteryHealth.cycles
            }
            return b
        }
        return nil
    }

    // MARK: Processes

    private struct ProcessSample {
        var pid: Int32
        var app: String
        var command: String
        var cpu: Double
        var memory: Double
    }

    /// A process's names, valid while its start time and command name stay the same.
    private struct ProcessName {
        var started: UInt64
        var command: String
        var app: String
    }

    private func readProcesses() -> (apps: [AppUsage], count: Int, cpuDelta: [String: Double], byPID: [Int32: ProcessSample]) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([], 0, [:], [:]) }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        let wall = mach_absolute_time()
        let wallDelta = previousProcessWall > 0 ? toSeconds(wall - previousProcessWall) : 0
        var groups: [String: AppUsage] = [:]
        var delta: [String: Double] = [:]
        var byPID: [Int32: ProcessSample] = Dictionary(minimumCapacity: found)
        var ticks: [Int32: UInt64] = Dictionary(minimumCapacity: found)
        var seenNames: [Int32: ProcessName] = Dictionary(minimumCapacity: found)

        for pid in pids.prefix(found) where pid > 0 {
            // One call returns CPU time, resident size, start time and command name.
            var all = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, size) == size else { continue }
            let task = all.ptinfo
            let total = task.pti_total_user + task.pti_total_system
            ticks[pid] = total
            var usage = rusage_info_v4()
            let footprint = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0 ? Double(usage.ri_phys_footprint) : Double(task.pti_resident_size)

            // Like proc_name: the long name when set, else the short one.
            let command = all.pbsd.pbi_name.0 != 0 ? Sampler.string(all.pbsd.pbi_name) : Sampler.string(all.pbsd.pbi_comm)
            let started = all.pbsd.pbi_start_tvsec &* 1_000_000 &+ all.pbsd.pbi_start_tvusec
            var name = names[pid]
            if name == nil || name?.started != started || name?.command != command {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
                proc_pidpath(pid, &path, UInt32(path.count))
                name = ProcessName(started: started, command: command,
                                   app: Sampler.appName(path: String(cBuffer: path), command: command))
            }
            seenNames[pid] = name
            let app = name?.app ?? command

            var seconds = 0.0
            if let before = previousProcesses[pid], total >= before { seconds = toSeconds(total - before) }
            let cpu = wallDelta > 0 ? seconds / wallDelta * 100 : 0
            delta[app, default: 0] += seconds
            byPID[pid] = ProcessSample(pid: pid, app: app, command: command, cpu: cpu, memory: footprint)

            var group = groups[app] ?? AppUsage(name: app, cpu: 0, memory: 0, cpuTime: 0)
            group.cpu += cpu
            group.memory += footprint
            group.cpuTime += toSeconds(total)
            groups[app] = group
        }
        names = seenNames  // drops processes that exited
        previousProcesses = ticks
        previousProcessWall = wall
        return (Array(groups.values), found, wallDelta > 0 ? delta : [:], byPID)
    }

    /// A string from a fixed-size, NUL-terminated C char array imported as a tuple.
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func toSeconds(_ machTicks: UInt64) -> Double {
        Double(machTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    private static let friendlyNames = [
        "node": "Node.js", "python": "Python", "python3": "Python", "java": "Java", "ruby": "Ruby",
        "bun": "Bun", "deno": "Deno", "php": "PHP", "go": "Go",
    ]

    /// Groups helpers under their app bundle, and system binaries under "macOS".
    static func appName(path: String, command: String) -> String {
        if let range = path.range(of: ".app/") {
            let bundle = path[..<range.lowerBound].split(separator: "/").last.map(String.init)
            if let bundle, !bundle.isEmpty { return bundle }
        }
        let isLocal = path.hasPrefix("/usr/local/") || path.hasPrefix("/opt/")
        if !isLocal, ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains(where: path.hasPrefix) {
            return "macOS"
        }
        let base = command.isEmpty ? (path as NSString).lastPathComponent : command
        let key = base.lowercased()
        if key.hasPrefix("python") { return "Python" }
        return friendlyNames[key] ?? base
    }

    // MARK: Dev servers

    /// Makes the next reading rescan listening ports, such as after a server was stopped.
    func rescanServersSoon() { lastServerScan = .distantPast }

    static let devCommands = ["node", "bun", "deno", "python", "ruby", "java", "php", "uvicorn", "gunicorn",
                                      "puma", "rails", "next-server", "vite", "esbuild", "hugo", "jekyll", "dotnet", "beam.smp"]

    /// Local servers the user started: processes on a dev runtime with listening TCP sockets.
    /// Only those processes' file descriptors are inspected, which is far cheaper than running lsof.
    private func scanDevServers(processes: [Int32: ProcessSample]) -> [DevServer] {
        var listeners: [Listener] = []
        for (pid, process) in processes where Sampler.isDevCommand(process.command) {
            for port in Sampler.listeningPorts(pid) {
                listeners.append(Listener(pid: pid, command: process.command, port: port))
            }
        }
        return Sampler.servers(from: listeners).map { server in
            var server = server
            server.path = Sampler.workingFolder(server.pid)
            server.folder = (server.path as NSString).lastPathComponent
            server.started = ProcessControl.startTime(server.pid) ?? 0
            server.cpu = processes[server.pid]?.cpu ?? 0
            server.memory = processes[server.pid]?.memory ?? 0
            return server
        }
    }

    struct Listener: Equatable {
        var pid: Int32
        var command: String
        var port: Int
    }

    static func isDevCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return devCommands.contains { lower.hasPrefix($0) }
    }

    /// Ports a process has TCP sockets listening on (IPv4 and IPv6), like `lsof -iTCP -sTCP:LISTEN`.
    static func listeningPorts(_ pid: Int32) -> [Int] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP),
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    /// Groups listeners by process and keeps the ones on a dev runtime, sorted by first port.
    /// Folder, CPU and memory are filled in by the caller.
    static func servers(from listeners: [Listener]) -> [DevServer] {
        var servers: [Int32: DevServer] = [:]
        for listener in listeners {
            guard isDevCommand(listener.command) else { continue }
            var server = servers[listener.pid] ?? DevServer(pid: listener.pid, name: appName(path: "", command: listener.command),
                                                            folder: "", ports: [], cpu: 0, memory: 0)
            if !server.ports.contains(listener.port) { server.ports.append(listener.port) }
            servers[listener.pid] = server
        }
        return servers.values.map(classify).sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    /// Java game servers listen on Minecraft's port range; they're local servers, not dev servers.
    static let minecraftPorts = 25565...25575

    static func classify(_ server: DevServer) -> DevServer {
        var server = server
        server.ports.sort()
        if server.name == "Java", server.ports.contains(where: minecraftPorts.contains) {
            server.name = "Minecraft"
            server.isDev = false
        }
        return server
    }

    static func workingFolder(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path
    }

    // MARK: Audio and accessories

    private func readAudio() -> (playing: Bool, device: String?) {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return (false, nil)
        }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return (running != 0, name?.takeRetainedValue() as String?)
    }

    /// Battery levels that Apple keyboards, mice and trackpads publish in the I/O Registry.
    private func readAccessoryBatteries() -> [(name: String, percent: Int)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [String: Int] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let percent = IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               let product = IORegistryEntryCreateCFProperty(entry, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                found[product] = percent
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return found.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    // MARK: sysctl

    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }
}

extension String {
    /// A string from a NUL-terminated C buffer.
    init(cBuffer buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
