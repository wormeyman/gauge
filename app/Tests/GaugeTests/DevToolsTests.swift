import Testing
import Foundation
@testable import Gauge

@Suite struct PortBoardTests {
    static let home = "/Users/alex"
    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func server(_ pid: Int32, _ port: Int, path: String, cpu: Double, startedDaysAgo: Double, isDev: Bool = true) -> DevServer {
        var server = DevServer(pid: pid, name: isDev ? "Node.js" : "Minecraft", folder: (path as NSString).lastPathComponent,
                               ports: [port], cpu: cpu, memory: 0, isDev: isDev)
        server.path = path
        server.started = UInt64((now.timeIntervalSince1970 - startedDaysAgo * 86_400) * 1_000_000)
        return server
    }

    @Test func freeCommonPortsAreListedSeparately() {
        let board = PortBoard.build(listeners: [], servers: [], idleFor: [:], now: Self.now, home: Self.home)
        #expect(board.rows.isEmpty)
        #expect(board.free == PortBoard.common)
    }

    @Test func airPlayReceiverOnPort5000IsNamed() {
        let listeners = [PortListener(port: 5000, pid: 471, name: "ControlCenter", path: "/"),
                         PortListener(port: 7000, pid: 471, name: "ControlCenter", path: "/")]
        let board = PortBoard.build(listeners: listeners, servers: [], idleFor: [:], now: Self.now, home: Self.home)
        #expect(board.rows.map(\.port) == [5000])  // 7000 isn't a common dev port
        #expect(board.rows.first?.holder == "AirPlay Receiver")
        #expect(board.rows.first?.note?.contains("AirDrop & Handoff") == true)
        #expect(!board.free.contains(5000))
    }

    @Test func idleServerInAnOldProjectIsProbablyForgotten() {
        // next dev in an old project holds 3000, so the new project's server moved to 3001.
        let old = Self.server(100, 3000, path: "/Users/alex/old-project", cpu: 0, startedDaysAgo: 4)
        let new = Self.server(200, 3001, path: "/Users/alex/new-project", cpu: 0, startedDaysAgo: 0.01)
        let board = PortBoard.build(listeners: [], servers: [old, new], idleFor: [:], now: Self.now, home: Self.home)
        let row3000 = board.rows.first { $0.port == 3000 }
        #expect(row3000?.forgotten == true)
        #expect(row3000?.folder == "~/old-project")
        #expect(row3000?.note == "Other project · Started 4 days ago")
        #expect(row3000?.server?.pid == 100)
        #expect(board.rows.first { $0.port == 3001 }?.forgotten == false)
    }

    @Test func busyServerMarksItsFolderAsCurrent() {
        // The older project is the one in use, so the newer idle server is the suspect.
        let working = Self.server(100, 3000, path: "/Users/alex/app", cpu: 12, startedDaysAgo: 2)
        let stray = Self.server(200, 8080, path: "/Users/alex/demo", cpu: 0, startedDaysAgo: 0.5)
        let board = PortBoard.build(listeners: [], servers: [working, stray], idleFor: [:], now: Self.now, home: Self.home)
        #expect(board.rows.first { $0.port == 3000 }?.forgotten == false)
        #expect(board.rows.first { $0.port == 3000 }?.note == "Started 2 days ago")
        #expect(board.rows.first { $0.port == 8080 }?.forgotten == true)
    }

    @Test func longIdleCountsEvenInTheOnlyProject() {
        let server = Self.server(100, 5173, path: "/Users/alex/site", cpu: 0, startedDaysAgo: 0.2)
        let short = PortBoard.build(listeners: [], servers: [server], idleFor: ["100": 10 * 60], now: Self.now, home: Self.home)
        #expect(short.rows.first?.forgotten == false)
        #expect(short.rows.first?.note == "Idle 10m")
        let long = PortBoard.build(listeners: [], servers: [server], idleFor: ["100": 2 * 3600], now: Self.now, home: Self.home)
        #expect(long.rows.first?.forgotten == true)
        #expect(long.rows.first?.note == "Idle 2h 0m")
    }

    @Test func gameServersAreListedButNeverForgotten() {
        let game = Self.server(300, 8000, path: "/Users/alex/mc", cpu: 0, startedDaysAgo: 3, isDev: false)
        let board = PortBoard.build(listeners: [], servers: [game], idleFor: ["300": 9_999], now: Self.now, home: Self.home)
        #expect(board.rows.first?.forgotten == false)
        #expect(board.rows.first?.note?.hasPrefix("Game server") == true)
    }

    @Test func pathsShortenTheHomeFolder() {
        #expect(PortBoard.abbreviate("/Users/alex/code/app", home: "/Users/alex") == "~/code/app")
        #expect(PortBoard.abbreviate("/Users/alex", home: "/Users/alex") == "~")
        #expect(PortBoard.abbreviate("/Users/alexander/x", home: "/Users/alex") == "/Users/alexander/x")
        #expect(PortBoard.abbreviate("/", home: "/Users/alex") == "")
    }
}

@Suite struct ContainerStatsTests {
    @Test func parsesDockerStatsJSONLines() {
        let output = """
        {"BlockIO":"7.28MB / 0B","CPUPerc":"0.06%","Container":"566398f9e852","ID":"566398f9e852","MemPerc":"0.41%","MemUsage":"8.035MiB / 1.913GiB","Name":"rustdesk-hbbs","NetIO":"15MB / 10.4MB","PIDs":"9"}
        {"BlockIO":"2.3MB / 0B","CPUPerc":"112.50%","Container":"6c22fc61c1c4","ID":"6c22fc61c1c4","MemPerc":"0.14%","MemUsage":"2.73MiB / 1.913GiB","Name":"builder","NetIO":"34.1kB / 126B","PIDs":"5"}
        WARNING: not json
        """
        let stats = ContainerStats.parse(output)
        #expect(stats.map(\.name) == ["rustdesk-hbbs", "builder"])  // largest memory first
        #expect(stats[0].cpu == 0.06)
        #expect(abs(stats[0].memory - 8.035 * 1_048_576) < 1)
        #expect(abs((stats[0].limit ?? 0) - 1.913 * 1_073_741_824) < 1)
        #expect(stats[1].cpu == 112.5)
    }

    @Test func acceptsPodmanKeys() {
        let stats = ContainerStats.parse(#"{"name":"db","cpu_percent":"3.5%","mem_usage":"512kB / 2GB"}"#)
        #expect(stats == [ContainerStat(name: "db", cpu: 3.5, memory: 512_000, limit: 2e9)])
    }

    @Test func emptyAndMissingValues() {
        #expect(ContainerStats.parse("").isEmpty)
        let stats = ContainerStats.parse(#"{"Name":"starting","CPUPerc":"--","MemUsage":"-- / --"}"#)
        #expect(stats.first?.cpu == 0)
        #expect(stats.first?.memory == 0)
    }

    @Test func sizes() {
        #expect(ContainerStats.bytes("0B") == 0)
        #expect(ContainerStats.bytes("1.5GiB") == 1.5 * 1_073_741_824)
        #expect(ContainerStats.bytes(" 10MB ") == 10e6)
        #expect(ContainerStats.bytes("2KiB") == 2048)
        #expect(ContainerStats.bytes("12 parsecs") == nil)
    }

    @Test func runtimesAreFoundByProcessName() {
        #expect(ContainerRuntime.running(in: ["Safari", "colima", "Node.js"]) == [.colima])
        #expect(ContainerRuntime.running(in: ["Docker", "OrbStack"]) == [.dockerDesktop, .orbStack])
        #expect(ContainerRuntime.running(in: ["Safari", "macOS"]).isEmpty)
    }
}

@Suite struct LocalModelTests {
    static let manifest = Data(#"{"schemaVersion":2,"config":{"size":485},"layers":[{"mediaType":"application/vnd.ollama.image.model","size":4920734016},{"mediaType":"application/vnd.ollama.image.template","size":1429}]}"#.utf8)

    @Test func ollamaManifestNamesAndSizes() {
        let model = LocalModels.ollamaModel(components: ["registry.ollama.ai", "library", "llama3.1", "8b"], manifest: Self.manifest)
        #expect(model == LocalModel(name: "llama3.1:8b", source: "Ollama", bytes: 4_920_734_016 + 1429 + 485))
        let user = LocalModels.ollamaModel(components: ["registry.ollama.ai", "someone", "tiny", "latest"], manifest: Self.manifest)
        #expect(user?.name == "someone/tiny:latest")
        let hf = LocalModels.ollamaModel(components: ["hf.co", "org", "model", "Q4_K_M"], manifest: Self.manifest)
        #expect(hf?.name == "hf.co/org/model:Q4_K_M")
        #expect(LocalModels.ollamaModel(components: ["a", "b", "c", "d"], manifest: Data("nope".utf8)) == nil)
    }

    @Test func mlxIsFoundFromArguments() {
        #expect(LocalModels.isMLX(["/opt/homebrew/bin/python3.12", "-m", "mlx_lm.server", "--model", "x"]))
        #expect(LocalModels.isMLX(["/Users/a/.venv/bin/mlx_lm.generate"]))
        #expect(!LocalModels.isMLX(["python3", "-m", "http.server"]))
    }

    @Test func runnersGroupTheirProcesses() {
        let apps = [AppUsage(name: "Ollama", cpu: 0, memory: 100, cpuTime: 0), AppUsage(name: "ollama", cpu: 0, memory: 5000, cpuTime: 0),
                    AppUsage(name: "llama-server", cpu: 0, memory: 7, cpuTime: 0), AppUsage(name: "Safari", cpu: 0, memory: 9, cpuTime: 0)]
        let runners = LocalModels.runners(apps: apps, mlxMemory: 42)
        #expect(runners == [ModelRunner(name: "Ollama", memory: 5100), ModelRunner(name: "llama.cpp", memory: 7),
                            ModelRunner(name: "MLX", memory: 42)])
    }
}

@Suite struct ModelHeadroomTests {
    static let gib = 1_073_741_824.0

    @Test func limitFromSysctlOrEstimate() {
        let set = ModelHeadroom.estimate(physical: 64 * Self.gib, wiredLimitMB: 57_344, used: 20 * Self.gib)
        #expect(!set.estimated)
        #expect(set.limit == 56 * Self.gib)
        #expect(set.free == 36 * Self.gib)
        let guess = ModelHeadroom.estimate(physical: 16 * Self.gib, wiredLimitMB: 0, used: 13 * Self.gib)
        #expect(guess.estimated)
        #expect(guess.limit == 12 * Self.gib)
        #expect(guess.free == 0)  // never negative
    }

    @Test func modelSizeFormula() {
        // 14B at 4-bit: 14e9 × 0.5 bytes × 1.2 overhead = 8.4 GB.
        #expect(ModelHeadroom.bytes(billions: 14, bits: 4) == 8.4e9)
        #expect(ModelHeadroom.bytes(billions: 7, bits: 8) == 8.4e9)
    }

    @Test func largestModelThatFits() {
        #expect(ModelHeadroom.largest(fitting: 8.4e9) == 14)
        #expect(ModelHeadroom.largest(fitting: 8.3e9) == 12)
        #expect(ModelHeadroom.largest(fitting: 0.5e9) == nil)
        #expect(ModelHeadroom.largest(fitting: 8.4e9, bits: 8) == 7)
        #expect(ModelHeadroom.sentence(free: 9e9) == "Room for about a 14B model at 4-bit right now")
        #expect(ModelHeadroom.sentence(free: 0).hasPrefix("No room"))
    }
}
