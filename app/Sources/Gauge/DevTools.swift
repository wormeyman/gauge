import Foundation
import Darwin
import Observation

// Developer readings for the Projects page: who holds the usual dev ports, running containers,
// build caches on disk, and local AI models. Everything is read from this Mac: libproc for
// processes, the local Docker command-line tool over its unix socket, and folder sizes on disk.
// Nothing here makes a network request.

// MARK: Ports

/// A process with a listening TCP port.
struct PortListener: Equatable {
    var port: Int
    var pid: Int32
    /// Display name, grouped like the process list (Node.js, ControlCenter, Spotify).
    var name: String
    /// The process's working folder, when Gauge can read it.
    var path: String
}

/// One port on the Projects page and what holds it.
struct PortRow: Identifiable, Equatable {
    var id: Int { port }
    var port: Int
    var holder: String
    /// Working folder with the home folder shortened to ~, or empty when unknown.
    var folder: String
    /// Set when a dev server holds the port, so it can be stopped.
    var server: DevServer?
    var note: String?
    /// Likely left running by accident: idle, and in another project or idle for a long time.
    var forgotten = false
}

enum PortBoard {
    /// Ports dev tools pick by default: Next.js, Create React App, Phoenix, Flask, Vite, Django, Jupyter and others.
    static let common = [3000, 3001, 4000, 5000, 5173, 8000, 8080, 8888]
    /// How long a server must have been idle, while Gauge watched, to count as forgotten.
    static let forgottenAfter: TimeInterval = 30 * 60

    /// Rows for the common ports that are taken and every dev server port, plus the common ports that are free.
    /// `idleFor` holds how long each server (by id) has been idle while Gauge watched.
    static func build(listeners: [PortListener], servers: [DevServer], idleFor: [String: TimeInterval],
                      now: Date, home: String) -> (rows: [PortRow], free: [Int]) {
        let dev = servers.filter(\.isDev)
        let ports = Set(common + dev.flatMap(\.ports)).sorted()
        // The project you're working in: where servers are busy, or else the newest server's folder.
        // Idle servers in other folders are suspects.
        let busy = Set(dev.filter { !$0.idle }.map(\.path))
        let current = busy.isEmpty ? Set([dev.max { $0.started < $1.started }?.path ?? ""]) : busy
        let folders = Set(dev.map(\.path).filter { !$0.isEmpty })
        var rows: [PortRow] = []
        var free: [Int] = []
        for port in ports {
            if let server = servers.first(where: { $0.ports.contains(port) }) {
                let idle = idleFor[server.id] ?? 0
                let otherProject = server.isDev && server.idle && folders.count > 1 && !server.path.isEmpty
                    && !current.contains(server.path)
                var notes: [String] = []
                if !server.isDev { notes.append("Game server") }
                if server.idle, idle >= 5 * 60 { notes.append("Idle \(Fmt.minutes(Int(idle / 60)))") }
                if otherProject { notes.append("Other project") }
                if let age = age(server.started, now: now) { notes.append(age) }
                rows.append(PortRow(port: port, holder: server.name, folder: abbreviate(server.path, home: home), server: server,
                                    note: notes.isEmpty ? nil : notes.joined(separator: " · "),
                                    forgotten: server.isDev && server.idle && (otherProject || idle >= forgottenAfter)))
            } else if let listener = listeners.first(where: { $0.port == port }) {
                let airPlay = listener.name == "ControlCenter"
                rows.append(PortRow(port: port, holder: airPlay ? "AirPlay Receiver" : listener.name,
                                    folder: airPlay ? "" : abbreviate(listener.path, home: home),
                                    note: airPlay ? "Turn off in System Settings › General › AirDrop & Handoff" : nil))
            } else {
                free.append(port)
            }
        }
        return (rows, free)
    }

    /// "Started 3 days ago" for servers running a day or more.
    static func age(_ started: UInt64, now: Date) -> String? {
        guard started > 0 else { return nil }
        let days = Int(now.timeIntervalSince1970 - Double(started) / 1_000_000) / 86_400
        return days >= 1 ? "Started \(days) day\(days == 1 ? "" : "s") ago" : nil
    }

    /// The path with the home folder shortened to ~. Root ("/") and empty paths come back empty.
    static func abbreviate(_ path: String, home: String) -> String {
        guard !path.isEmpty, path != "/" else { return "" }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: Containers

struct ContainerStat: Identifiable, Equatable {
    var id: String { name }
    var name: String
    /// Percent of one core, like `docker stats`.
    var cpu: Double
    var memory: Double
    var limit: Double?
}

enum ContainerRuntime: String, CaseIterable {
    case dockerDesktop = "Docker Desktop", orbStack = "OrbStack", colima = "Colima", podman = "Podman"

    /// Names the process list groups the runtime's processes under.
    var processNames: [String] {
        switch self {
        case .dockerDesktop: ["docker", "docker desktop", "com.docker.backend"]
        case .orbStack: ["orbstack"]
        case .colima: ["colima"]
        case .podman: ["podman", "podman desktop", "gvproxy"]
        }
    }

    /// Where each runtime puts its Docker-compatible unix socket.
    func sockets(home: String, temp: String) -> [String] {
        switch self {
        case .dockerDesktop: ["\(home)/.docker/run/docker.sock", "/var/run/docker.sock"]
        case .orbStack: ["\(home)/.orbstack/run/docker.sock", "/var/run/docker.sock"]
        case .colima: ["\(home)/.colima/default/docker.sock", "\(home)/.colima/docker.sock"]
        case .podman: ["\(home)/.local/share/containers/podman/machine/podman.sock",
                       "\(home)/.local/share/containers/podman/machine/qemu/podman.sock",
                       "\(temp)/podman/podman-machine-default-api.sock", "/var/run/docker.sock"]
        }
    }

    /// Runtimes with a running process, matched case-insensitively against the process list's names.
    static func running(in names: [String]) -> [ContainerRuntime] {
        let lower = Set(names.map { $0.lowercased() })
        return allCases.filter { runtime in runtime.processNames.contains(where: lower.contains) }
    }
}

enum ContainerState: Equatable {
    case noRuntime
    case checking(String)
    case unavailable(String, String)
    case running(String, [ContainerStat])
}

enum ContainerStats {
    /// Where the Docker command-line tool is usually installed.
    static func cliPaths(home: String) -> [String] {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.orbstack/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker", "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"]
    }

    /// Parses `docker stats --no-stream --format '{{json .}}'`: one JSON object per line.
    /// Podman's lower-case keys are accepted too. Lines that aren't JSON are skipped.
    static func parse(_ output: String) -> [ContainerStat] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> ContainerStat? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            func value(_ keys: String...) -> String? { keys.lazy.compactMap { object[$0] as? String }.first }
            guard let name = value("Name", "name", "Names") ?? value("ID", "id") else { return nil }
            let usage = (value("MemUsage", "mem_usage") ?? "").components(separatedBy: "/")
            return ContainerStat(name: name, cpu: percent(value("CPUPerc", "cpu_percent", "CPU") ?? "") ?? 0,
                                 memory: bytes(usage.first ?? "") ?? 0, limit: usage.count > 1 ? bytes(usage[1]) : nil)
        }
        .sorted { $0.memory > $1.memory }
    }

    static func percent(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    }

    /// "8.035MiB", "1.913GiB", "512kB" or "0B" in bytes.
    static func bytes(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let split = text.firstIndex(where: { !($0.isNumber || $0 == ".") }), let number = Double(text[..<split]) else {
            return Double(text)
        }
        let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
                                       "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
        guard let scale = units[text[split...].trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        return number * scale
    }

    /// Runs a command with a time limit and returns its output, or nil if it failed or ran too long.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // A plain environment: no DOCKER_HOST or context from a shell profile can point it elsewhere.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: Build caches

struct CacheItem: Identifiable, Equatable {
    var id: String { path }
    var label: String
    var path: String
    /// What happens after it goes to the Trash.
    var note: String
    var bytes: Double
}

enum BuildCaches {
    /// Caches developer tools rebuild or download again when needed.
    static func locations(home: String) -> [(label: String, path: String, note: String)] {
        [("Xcode DerivedData", "\(home)/Library/Developer/Xcode/DerivedData", "Xcode rebuilds it on the next build."),
         ("Simulator devices", "\(home)/Library/Developer/CoreSimulator/Devices",
          "Every simulator goes, with the apps and data on it. Xcode can create new ones."),
         ("Simulator caches", "\(home)/Library/Developer/CoreSimulator/Caches", "Simulators rebuild it as they need it."),
         ("Homebrew downloads", "\(home)/Library/Caches/Homebrew", "Homebrew downloads packages again when it needs them."),
         ("npm cache", "\(home)/.npm", "npm downloads packages again when it needs them."),
         ("pnpm store", "\(home)/Library/pnpm/store", "pnpm downloads packages again when it needs them."),
         ("pnpm store", "\(home)/.pnpm-store", "pnpm downloads packages again when it needs them."),
         ("Yarn cache", "\(home)/.cache/yarn", "Yarn downloads packages again when it needs them."),
         ("Yarn cache", "\(home)/Library/Caches/Yarn", "Yarn downloads packages again when it needs them."),
         ("Gradle caches", "\(home)/.gradle/caches", "Gradle downloads and rebuilds them on the next build."),
         ("Cargo registry", "\(home)/.cargo/registry", "Cargo downloads crates again on the next build.")]
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Space a folder takes on disk, like `du`: allocated blocks, hard-linked files counted once,
    /// symbolic links not followed and other volumes not entered. fts is several times faster than
    /// FileManager's enumerator on folders with hundreds of thousands of files, such as ~/.npm.
    static func size(of path: String) -> Double {
        var total: Int64 = 0
        var linked = Set<[UInt64]>()
        guard let root = strdup(path) else { return 0 }
        defer { free(root) }
        var paths: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            guard Int32(entry.pointee.fts_info) == FTS_F, let info = entry.pointee.fts_statp?.pointee else { continue }
            if info.st_nlink > 1, !linked.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted { continue }
            total += info.st_blocks * 512
        }
        return Double(total)
    }
}

// MARK: Local AI models

struct ModelRunner: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var memory: Double
}

struct LocalModel: Identifiable, Equatable {
    var id: String { source + name }
    var name: String
    var source: String
    var bytes: Double
}

enum LocalModels {
    /// Model runners by the names the process list groups them under. MLX runs inside Python, so it's found separately.
    static func runners(apps: [AppUsage], mlxMemory: Double) -> [ModelRunner] {
        let known: [(String, [String])] = [("Ollama", ["ollama"]), ("LM Studio", ["lm studio"]),
                                           ("llama.cpp", ["llama-server", "llama-cli", "llama.cpp"])]
        var result = known.compactMap { runner, names -> ModelRunner? in
            let matches = apps.filter { names.contains($0.name.lowercased()) }
            return matches.isEmpty ? nil : ModelRunner(name: runner, memory: matches.map(\.memory).reduce(0, +))
        }
        if mlxMemory > 0 { result.append(ModelRunner(name: "MLX", memory: mlxMemory)) }
        return result
    }

    /// True for a Python process serving or running an MLX model, such as `python -m mlx_lm.server`.
    static func isMLX(_ arguments: [String]) -> Bool {
        arguments.contains { arg in ["mlx_lm", "mlx-lm", "mlx_vlm", "mlx-vlm"].contains { arg.contains($0) } }
    }

    /// An Ollama model from its manifest. `components` is the manifest's path under models/manifests:
    /// registry, namespace, model and tag. Its size is the sum of its layers.
    static func ollamaModel(components: [String], manifest: Data) -> LocalModel? {
        guard components.count >= 3,
              let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let layers = object["layers"] as? [[String: Any]] else { return nil }
        let config = ((object["config"] as? [String: Any])?["size"] as? NSNumber)?.doubleValue ?? 0
        let size = layers.compactMap { ($0["size"] as? NSNumber)?.doubleValue }.reduce(0, +) + config
        let tag = components[components.count - 1], model = components[components.count - 2]
        var name = "\(model):\(tag)"
        if components.count >= 4 {
            let namespace = components[components.count - 3], registry = components[components.count - 4]
            if namespace != "library" { name = "\(namespace)/\(name)" }
            if registry != "registry.ollama.ai" { name = "\(registry)/\(name)" }
        }
        return LocalModel(name: name, source: "Ollama", bytes: size)
    }

    static func scanOllama(home: String) -> [LocalModel] {
        let root = URL(fileURLWithPath: "\(home)/.ollama/models/manifests")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var models: [LocalModel] = []
        while let file = files.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file) else { continue }
            let components = Array(file.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count))
            if let model = ollamaModel(components: components, manifest: data) { models.append(model) }
        }
        return models
    }

    /// LM Studio keeps each model in models/<publisher>/<model>.
    static func scanLMStudio(home: String) -> [LocalModel] {
        let fm = FileManager.default
        var models: [LocalModel] = []
        for root in ["\(home)/.lmstudio/models", "\(home)/.cache/lm-studio/models"] {
            for publisher in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !publisher.hasPrefix(".") {
                for model in (try? fm.contentsOfDirectory(atPath: "\(root)/\(publisher)")) ?? [] where !model.hasPrefix(".") {
                    let path = "\(root)/\(publisher)/\(model)"
                    guard BuildCaches.isDirectory(path) else { continue }
                    models.append(LocalModel(name: "\(publisher)/\(model)", source: "LM Studio", bytes: BuildCaches.size(of: path)))
                }
            }
        }
        return models
    }
}

/// How much memory a model could use right now, and roughly how large a model that is.
struct Headroom: Equatable {
    /// Memory the GPU may use: iogpu.wired_limit_mb when set, else an estimate.
    var limit: Double
    var estimated: Bool
    var physical: Double
    var used: Double
    var free: Double { max(0, limit - used) }
}

enum ModelHeadroom {
    /// Common open-weight model sizes, in billions of parameters.
    static let sizes: [Double] = [1, 3, 4, 7, 8, 12, 14, 24, 32, 70, 120, 405]
    /// Context and runtime buffers on top of the weights.
    static let overhead = 1.2

    /// The GPU's memory limit: iogpu.wired_limit_mb if someone set it, else about 75% of memory (an estimate of
    /// macOS's default; Apple doesn't document the exact share).
    static func estimate(physical: Double, wiredLimitMB: Int?, used: Double) -> Headroom {
        if let mb = wiredLimitMB, mb > 0 {
            return Headroom(limit: Double(mb) * 1_048_576, estimated: false, physical: physical, used: used)
        }
        return Headroom(limit: physical * 0.75, estimated: true, physical: physical, used: used)
    }

    /// Bytes a model needs: parameters × bits ÷ 8, plus overhead.
    static func bytes(billions: Double, bits: Double) -> Double {
        billions * 1e9 * bits / 8 * overhead
    }

    /// The largest common model size, in billions of parameters, that fits in `free` bytes.
    static func largest(fitting free: Double, bits: Double = 4) -> Double? {
        sizes.last { bytes(billions: $0, bits: bits) <= free }
    }

    static func sentence(free: Double) -> String {
        guard let billions = largest(fitting: free) else { return "No room for a 1B model at 4-bit without freeing memory" }
        return "Room for about a \(Int(billions))B model at 4-bit right now"
    }
}

// MARK: Model

/// Developer readings for the Projects page. Scans run off the main thread, and only while the page is open.
@MainActor @Observable
final class DevTools {
    var ports: [PortRow] = []
    var freePorts: [Int] = []
    var portsScanned = false
    var containers: ContainerState = .noRuntime
    var caches: [CacheItem] = []
    var measuring = false
    var measured: Date?
    var runners: [ModelRunner] = []
    var models: [LocalModel] = []
    var headroom: Headroom?

    @ObservationIgnored private let queue = DispatchQueue(label: "gauge.devtools", qos: .utility)
    /// Folder sizes can take a while, so they get their own queue and don't hold up the port scan.
    @ObservationIgnored private let diskQueue = DispatchQueue(label: "gauge.devtools.disk", qos: .utility)
    @ObservationIgnored private var listeners: [PortListener] = []
    @ObservationIgnored private var mlxMemory = 0.0
    @ObservationIgnored private var lastPortScan = Date.distantPast
    @ObservationIgnored private var lastContainerCheck = Date.distantPast
    @ObservationIgnored private var checkingContainers = false
    @ObservationIgnored private var lastModelScan = Date.distantPast
    /// When each server (by id) was last seen busy, or first seen.
    @ObservationIgnored private var lastBusy: [String: Date] = [:]
    private let home = NSHomeDirectory()

    /// Project folders dev servers have run in, remembered on this Mac so their node_modules can be measured.
    private var projectFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "projectFolders") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(30)), forKey: "projectFolders") }
    }

    /// Brings readings up to date. Each kind has its own interval: ports every 15 s, containers every 30 s,
    /// build caches and model folders every 10 minutes.
    func refresh(_ monitor: Monitor) {
        let now = Date()
        track(monitor.servers, now: now)
        rebuildPorts(monitor, now: now)
        if now.timeIntervalSince(lastPortScan) >= 15 {
            lastPortScan = now
            queue.async {
                let scan = DevTools.scanProcesses()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    listeners = scan.listeners
                    mlxMemory = scan.mlx
                    portsScanned = true
                    rebuildPorts(monitor, now: Date())
                    updateModels(monitor)
                }
            }
        }
        checkContainers(monitor, now: now)
        if measured == nil || now.timeIntervalSince(measured ?? now) >= 600 { measureCaches() }
        if now.timeIntervalSince(lastModelScan) >= 600 {
            lastModelScan = now
            let home = home
            diskQueue.async {
                let found = (LocalModels.scanOllama(home: home) + LocalModels.scanLMStudio(home: home)).sorted { $0.bytes > $1.bytes }
                DispatchQueue.main.async { [weak self] in
                    if self?.models != found { self?.models = found }
                }
            }
        }
        updateModels(monitor)
    }

    private func track(_ servers: [DevServer], now: Date) {
        var busy: [String: Date] = [:]
        for server in servers { busy[server.id] = server.idle ? (lastBusy[server.id] ?? now) : now }
        lastBusy = busy
        var paths: [String] = []
        for server in servers where server.isDev && !server.path.isEmpty && server.path != "/" && server.path != home
            && !paths.contains(server.path) { paths.append(server.path) }
        let known = projectFolders
        if paths.contains(where: { !known.contains($0) }) {
            projectFolders = known.filter { !paths.contains($0) } + paths
        }
    }

    private func rebuildPorts(_ monitor: Monitor, now: Date) {
        let idle = lastBusy.mapValues { now.timeIntervalSince($0) }
        let board = PortBoard.build(listeners: listeners, servers: monitor.servers, idleFor: idle, now: now, home: home)
        if board.rows != ports { ports = board.rows }
        if board.free != freePorts { freePorts = board.free }
    }

    private func updateModels(_ monitor: Monitor) {
        let found = LocalModels.runners(apps: monitor.apps, mlxMemory: mlxMemory)
        if found != runners { runners = found }
        if let memory = monitor.latest?.memory {
            let limit = Sampler.sysctlInt32("iogpu.wired_limit_mb").map(Int.init)
            let estimate = ModelHeadroom.estimate(physical: memory.total, wiredLimitMB: limit, used: memory.used)
            if estimate != headroom { headroom = estimate }
        }
    }

    // MARK: Containers

    private func checkContainers(_ monitor: Monitor, now: Date) {
        let running = ContainerRuntime.running(in: monitor.apps.map(\.name))
        guard let runtime = running.first else {
            if containers != .noRuntime { containers = .noRuntime }
            return
        }
        guard !checkingContainers, now.timeIntervalSince(lastContainerCheck) >= 30 else { return }
        lastContainerCheck = now
        checkingContainers = true
        if case .running(let name, _) = containers, name == runtime.rawValue {} else { containers = .checking(runtime.rawValue) }
        let home = home
        queue.async {
            let state = DevTools.readContainers(runtime, home: home)
            DispatchQueue.main.async { [weak self] in
                self?.checkingContainers = false
                if self?.containers != state { self?.containers = state }
            }
        }
    }

    private nonisolated static func readContainers(_ runtime: ContainerRuntime, home: String) -> ContainerState {
        let name = runtime.rawValue
        guard let cli = ContainerStats.cliPaths(home: home).first(where: FileManager.default.isExecutableFile) else {
            return .unavailable(name, "The docker command-line tool isn't installed, so Gauge can't list containers.")
        }
        let temp = NSTemporaryDirectory().hasSuffix("/") ? String(NSTemporaryDirectory().dropLast()) : NSTemporaryDirectory()
        guard let socket = runtime.sockets(home: home, temp: temp).first(where: isSocket) else {
            return .unavailable(name, "\(name)'s Docker socket wasn't found.")
        }
        guard let output = ContainerStats.run(cli, ["--host", "unix://\(socket)", "stats", "--no-stream", "--format", "{{json .}}"],
                                              timeout: 15) else {
            return .unavailable(name, "\(name) didn't answer. It may still be starting.")
        }
        return .running(name, ContainerStats.parse(output))
    }

    private nonisolated static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    // MARK: Caches

    /// Measures build caches and node_modules folders in the background.
    func measureCaches() {
        guard !measuring else { return }
        measuring = true
        let home = home
        let projects = projectFolders
        diskQueue.async {
            var items: [CacheItem] = []
            for location in BuildCaches.locations(home: home) where BuildCaches.isDirectory(location.path) {
                items.append(CacheItem(label: location.label, path: location.path, note: location.note,
                                       bytes: BuildCaches.size(of: location.path)))
            }
            for folder in Set(projects).sorted() where BuildCaches.isDirectory("\(folder)/node_modules") {
                let path = "\(folder)/node_modules"
                items.append(CacheItem(label: "node_modules · \((folder as NSString).lastPathComponent)", path: path,
                                       note: "Run your package manager's install command in the project to get it back.",
                                       bytes: BuildCaches.size(of: path)))
            }
            let sorted = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                caches = sorted
                measuring = false
                measured = Date()
            }
        }
    }

    /// Moves a cache folder to the Trash, where it can still be put back. Returns an error message on failure.
    func trash(_ item: CacheItem) -> String? {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            caches.removeAll { $0.id == item.id }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Process scan

    /// Listening ports of the user's processes, and the memory of any MLX model processes.
    /// Other users' processes can't be inspected without administrator access, so they're skipped.
    private nonisolated static func scanProcesses() -> (listeners: [PortListener], mlx: Double) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([], 0) }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        let uid = getuid()
        var listeners: [PortListener] = []
        var mlx = 0.0
        for pid in pids.prefix(found) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            func text<T>(_ tuple: T) -> String { withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            let command = info.pbi_name.0 != 0 ? text(info.pbi_name) : text(info.pbi_comm)
            let ports = Sampler.listeningPorts(pid)
            if !ports.isEmpty {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
                proc_pidpath(pid, &path, UInt32(path.count))
                let name = Sampler.appName(path: String(cBuffer: path), command: command)
                let folder = Sampler.workingFolder(pid)
                for port in ports { listeners.append(PortListener(port: port, pid: pid, name: name, path: folder)) }
            }
            let lower = command.lowercased()
            if lower.hasPrefix("python") || lower.contains("mlx"), LocalModels.isMLX(arguments(pid)) {
                var usage = rusage_info_v4()
                let ok = withUnsafeMutablePointer(to: &usage) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                } == 0
                if ok { mlx += Double(usage.ri_phys_footprint) }
            }
        }
        return (listeners.sorted { $0.port < $1.port }, mlx)
    }

    /// A process's command-line arguments, from KERN_PROCARGS2.
    private nonisolated static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // After argc: the executable path, NUL padding, then argc NUL-terminated arguments.
        var parts = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return [] }
        parts.removeFirst()
        return parts.prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }
    }
}
