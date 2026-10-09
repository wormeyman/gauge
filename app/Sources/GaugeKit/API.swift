import Foundation

/// Gauge's local API: newline-delimited JSON over a Unix domain socket that only the current user can open.
///
/// A request is one JSON object per line, such as `{"method":"vitals"}` or `{"method":"port","port":3000}`.
/// Each gets one line back: `{"ok":true,"result":{…}}` or `{"ok":false,"error":"…"}`.
/// It's read-only: nothing can stop servers, quit apps or change settings through it.
public enum API {
    /// Methods the app answers, with what each takes.
    public static let methods: [(name: String, summary: String)] = [
        ("vitals", "The six vitals right now"),
        ("apps", "Top apps; optional \"sort\": \"cpu\" or \"memory\", \"limit\": 1-50"),
        ("servers", "Dev servers listening on local ports"),
        ("port", "Whether a TCP port is free, or what holds it; \"port\": 1-65535"),
        ("notices", "Current Worth a look notices"),
        ("history", "Averaged history; \"metric\", \"minutes\": 1-10080, optional \"points\": 2-500"),
    ]

    /// Metrics `history` can return, with their units.
    public static let historyMetrics: [(name: String, unit: String)] = [
        ("cpu", "percent"), ("memory", "bytes"), ("gpu", "percent"), ("download", "bytes/s"),
        ("upload", "bytes/s"), ("disk_read", "bytes/s"), ("disk_write", "bytes/s"), ("battery", "percent"),
    ]

    /// `~/Library/Application Support/Gauge/gauge.sock`, next to the history file.
    /// GAUGE_SOCKET overrides it, for tests.
    public static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["GAUGE_SOCKET"], !path.isEmpty { return path }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gauge/gauge.sock").path
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// One response line, without the trailing newline.
    public static func success(_ result: JSON) -> Data { JSON.object(["ok": true, "result": result]).data() }
    public static func failure(_ message: String) -> Data { JSON.object(["ok": false, "error": .string(message)]).data() }

    public static func success<T: Encodable>(encoding result: T) -> Data {
        (try? JSON(encoding: result)).map(success) ?? failure("Gauge couldn't encode the result.")
    }
}

// MARK: Results

/// The six vitals. Byte counts are bytes, rates are bytes per second. A missing value is one Gauge can't read.
public struct Vitals: Codable, Equatable, Sendable {
    public var time: Date
    public var cpu: CPU
    public var memory: Memory
    public var gpu: GPU
    public var disk: Disk
    public var network: Network
    /// Absent on a Mac without a battery.
    public var battery: Battery?
    /// Readings Gauge can't take, in plain language.
    public var unavailable: [String]

    public struct CPU: Codable, Equatable, Sendable {
        public var percent, userPercent, systemPercent: Double
        public var cores: Int
        public var chip: String
        public init(percent: Double, userPercent: Double, systemPercent: Double, cores: Int, chip: String) {
            self.percent = percent; self.userPercent = userPercent; self.systemPercent = systemPercent; self.cores = cores; self.chip = chip
        }
    }

    public struct Memory: Codable, Equatable, Sendable {
        public var usedBytes, totalBytes, appBytes, wiredBytes, compressedBytes, cachedBytes, freeBytes, swapUsedBytes: Double
        /// "normal", "elevated" or "critical", as macOS reports it.
        public var pressure: String
        public init(usedBytes: Double, totalBytes: Double, appBytes: Double, wiredBytes: Double, compressedBytes: Double,
                    cachedBytes: Double, freeBytes: Double, swapUsedBytes: Double, pressure: String) {
            self.usedBytes = usedBytes; self.totalBytes = totalBytes; self.appBytes = appBytes; self.wiredBytes = wiredBytes
            self.compressedBytes = compressedBytes; self.cachedBytes = cachedBytes; self.freeBytes = freeBytes
            self.swapUsedBytes = swapUsedBytes; self.pressure = pressure
        }
    }

    public struct GPU: Codable, Equatable, Sendable {
        public var percent: Double?
        public var memoryBytes: Double?
        public init(percent: Double?, memoryBytes: Double?) { self.percent = percent; self.memoryBytes = memoryBytes }
    }

    public struct Disk: Codable, Equatable, Sendable {
        public var name: String
        public var totalBytes, usedBytes, availableBytes, readBytesPerSecond, writeBytesPerSecond: Double
        public init(name: String, totalBytes: Double, usedBytes: Double, availableBytes: Double,
                    readBytesPerSecond: Double, writeBytesPerSecond: Double) {
            self.name = name; self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.availableBytes = availableBytes
            self.readBytesPerSecond = readBytesPerSecond; self.writeBytesPerSecond = writeBytesPerSecond
        }
    }

    public struct Network: Codable, Equatable, Sendable {
        public var downloadBytesPerSecond, uploadBytesPerSecond: Double
        /// Counted since Gauge opened.
        public var receivedBytes, sentBytes: Double
        public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double, receivedBytes: Double, sentBytes: Double) {
            self.downloadBytesPerSecond = downloadBytesPerSecond; self.uploadBytesPerSecond = uploadBytesPerSecond
            self.receivedBytes = receivedBytes; self.sentBytes = sentBytes
        }
    }

    public struct Battery: Codable, Equatable, Sendable {
        public var percent: Double
        public var charging, onPowerAdapter: Bool
        public var minutesToFull, minutesToEmpty: Int?
        public var watts, healthPercent: Double?
        public var cycleCount: Int?
        public init(percent: Double, charging: Bool, onPowerAdapter: Bool, minutesToFull: Int?, minutesToEmpty: Int?,
                    watts: Double?, healthPercent: Double?, cycleCount: Int?) {
            self.percent = percent; self.charging = charging; self.onPowerAdapter = onPowerAdapter
            self.minutesToFull = minutesToFull; self.minutesToEmpty = minutesToEmpty
            self.watts = watts; self.healthPercent = healthPercent; self.cycleCount = cycleCount
        }
    }

    public init(time: Date, cpu: CPU, memory: Memory, gpu: GPU, disk: Disk, network: Network, battery: Battery?, unavailable: [String]) {
        self.time = time; self.cpu = cpu; self.memory = memory; self.gpu = gpu; self.disk = disk
        self.network = network; self.battery = battery; self.unavailable = unavailable
    }
}

public struct TopApps: Codable, Equatable, Sendable {
    /// "cpu" or "memory".
    public var sortedBy: String
    public var processCount: Int
    public var apps: [App]

    public struct App: Codable, Equatable, Sendable {
        public var name: String
        /// Percent of one core, like Activity Monitor, so a busy app can pass 100.
        public var cpuPercent: Double
        public var memoryBytes: Double
        public init(name: String, cpuPercent: Double, memoryBytes: Double) {
            self.name = name; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        }
    }

    public init(sortedBy: String, processCount: Int, apps: [App]) {
        self.sortedBy = sortedBy; self.processCount = processCount; self.apps = apps
    }
}

public struct DevServers: Codable, Equatable, Sendable {
    public var servers: [Server]

    public struct Server: Codable, Equatable, Sendable {
        public var pid: Int
        /// Node.js, Python, Bun and so on.
        public var runtime: String
        /// The folder the server was started in (its last path component).
        public var folder: String
        public var ports: [Int]
        public var cpuPercent: Double
        public var memoryBytes: Double
        /// Under 1% CPU.
        public var idle: Bool
        /// False for local servers that aren't dev servers, such as a Minecraft server.
        public var isDevServer: Bool
        public init(pid: Int, runtime: String, folder: String, ports: [Int], cpuPercent: Double, memoryBytes: Double,
                    idle: Bool, isDevServer: Bool) {
            self.pid = pid; self.runtime = runtime; self.folder = folder; self.ports = ports
            self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.idle = idle; self.isDevServer = isDevServer
        }
    }

    public init(servers: [Server]) { self.servers = servers }
}

public struct PortStatus: Codable, Equatable, Sendable {
    public var port: Int
    public var free: Bool
    /// The process listening on the port, when Gauge can see it.
    public var holder: Holder?
    /// One plain-language sentence.
    public var detail: String

    public struct Holder: Codable, Equatable, Sendable {
        public var pid: Int
        public var name: String
        public var folder: String
        public init(pid: Int, name: String, folder: String) { self.pid = pid; self.name = name; self.folder = folder }
    }

    public init(port: Int, free: Bool, holder: Holder?, detail: String) {
        self.port = port; self.free = free; self.holder = holder; self.detail = detail
    }
}

public struct NoticeList: Codable, Equatable, Sendable {
    public var notices: [Notice]

    public struct Notice: Codable, Equatable, Sendable {
        /// The area it's about: Memory, CPU, Disk, Projects or Battery.
        public var tag: String
        public var title: String
        public var body: String
        /// True for readings that need attention (shown in signal orange in the app).
        public var needsAttention: Bool
        public var since: Date
        public init(tag: String, title: String, body: String, needsAttention: Bool, since: Date) {
            self.tag = tag; self.title = title; self.body = body; self.needsAttention = needsAttention; self.since = since
        }
    }

    public init(notices: [Notice]) { self.notices = notices }
}

public struct HistorySeries: Codable, Equatable, Sendable {
    public var metric: String
    public var unit: String
    public var minutes: Int
    /// Averages over equal buckets, oldest first. Empty when nothing was recorded in the window.
    public var points: [Point]
    public var summary: Summary?

    public struct Point: Codable, Equatable, Sendable {
        public var time: Date
        public var value: Double
        public init(time: Date, value: Double) { self.time = time; self.value = value }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var min, average, max: Double
        public init(min: Double, average: Double, max: Double) { self.min = min; self.average = average; self.max = max }
    }

    public init(metric: String, unit: String, minutes: Int, points: [Point]) {
        self.metric = metric; self.unit = unit; self.minutes = minutes; self.points = points
        let values = points.map(\.value)
        if let lo = values.min(), let hi = values.max() {
            summary = Summary(min: lo, average: values.reduce(0, +) / Double(values.count), max: hi)
        }
    }
}

// MARK: Requests

/// A validated request. The app answers these; the CLI and MCP server build them.
public enum Request: Equatable, Sendable {
    case vitals
    case apps(sortBy: String, limit: Int)
    case servers
    case port(Int)
    case notices
    case history(metric: String, minutes: Int, points: Int)

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Reads a request line's object, filling in defaults and rejecting out-of-range values.
    public init(_ json: JSON) throws(Invalid) {
        guard let method = json["method"]?.string else { throw Invalid("Missing \"method\". Try {\"method\":\"vitals\"}.") }
        func number(_ key: String, default value: Int? = nil, _ range: ClosedRange<Int>) throws(Invalid) -> Int {
            guard let raw = json[key], raw != .null else {
                if let value { return value }
                throw Invalid("\"\(method)\" needs \"\(key)\".")
            }
            guard let n = raw.int, range.contains(n) else {
                throw Invalid("\"\(key)\" must be a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return n
        }
        switch method {
        case "vitals": self = .vitals
        case "apps":
            let sort = json["sort"]?.string ?? "cpu"
            guard ["cpu", "memory"].contains(sort) else { throw Invalid("\"sort\" must be \"cpu\" or \"memory\".") }
            self = .apps(sortBy: sort, limit: try number("limit", default: 10, 1...50))
        case "servers": self = .servers
        case "port": self = .port(try number("port", 1...65_535))
        case "notices": self = .notices
        case "history":
            let names = API.historyMetrics.map(\.name)
            guard let metric = json["metric"]?.string?.lowercased().replacingOccurrences(of: "-", with: "_") else {
                throw Invalid("\"history\" needs \"metric\": one of \(names.joined(separator: ", ")).")
            }
            guard names.contains(metric) else { throw Invalid("Unknown metric \"\(metric)\". Use one of \(names.joined(separator: ", ")).") }
            self = .history(metric: metric, minutes: try number("minutes", default: 60, 1...10_080),
                            points: try number("points", default: 60, 2...500))
        default:
            throw Invalid("Unknown method \"\(method)\". Methods: \(API.methods.map(\.name).joined(separator: ", ")).")
        }
    }

    public var json: JSON {
        switch self {
        case .vitals: ["method": "vitals"]
        case .apps(let sort, let limit): ["method": "apps", "sort": .string(sort), "limit": .int(limit)]
        case .servers: ["method": "servers"]
        case .port(let port): ["method": "port", "port": .int(port)]
        case .notices: ["method": "notices"]
        case .history(let metric, let minutes, let points):
            ["method": "history", "metric": .string(metric), "minutes": .int(minutes), "points": .int(points)]
        }
    }

    public static func unit(of metric: String) -> String { API.historyMetrics.first { $0.name == metric }?.unit ?? "" }
}
