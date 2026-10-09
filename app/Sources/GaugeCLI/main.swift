import Foundation
import GaugeKit

// `gauge`: reads Gauge's live readings and history from the running app over its local socket.
// Gauge.app ships it at Contents/Helpers/gauge. It only reads; nothing here changes the Mac.

let usage = """
    Usage: gauge <command> [--json]

      vitals                         The six vitals right now
      apps [--memory] [--limit N]    Top apps by CPU (or memory)
      servers                        Dev servers listening on local ports
      port <number>                  Whether a port is free, or what holds it
      notices                        Current Worth a look notices
      history <metric> [--minutes N] [--points N]
                                     Averaged history. Metrics: \(API.historyMetrics.map(\.name).joined(separator: ", "))
      mcp                            Run as an MCP server on stdin/stdout, for coding agents

      --json                         Print the raw JSON result

    Gauge must be running with "Let local tools read Gauge" turned on in Settings.
    """

/// Gauge's version, from the app bundle this tool ships in.
var version: String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    let info = NSDictionary(contentsOf: plist)
    return info?["CFBundleShortVersionString"] as? String ?? "development"
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }

/// The value after a flag such as `--minutes 60`, removed from the arguments.
@MainActor func option(_ flag: String) -> Int? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count, let value = Int(args[i + 1]) else { fail("\(flag) needs a number.") }
    args.removeSubrange(i...(i + 1))
    return value
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func merge(_ a: JSON, _ b: JSON) -> JSON { .object((a.object ?? [:]).merging(b.object ?? [:]) { $1 }) }

guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

if command == "mcp" {
    MCPServer(version: version) { request throws(UnixSocketClient.Failure) in try UnixSocketClient.send(request) }.serve()
    exit(0)
}

var request: JSON
switch command {
case "vitals": request = ["method": "vitals"]
case "apps":
    request = ["method": "apps", "sort": flag("--memory") ? "memory" : "cpu"]
    if let limit = option("--limit") { request = merge(request, ["limit": .int(limit)]) }
case "servers": request = ["method": "servers"]
case "port":
    guard let port = args.first.flatMap(Int.init) else { fail("Usage: gauge port <number>, such as gauge port 3000") }
    args.removeFirst()
    request = ["method": "port", "port": .int(port)]
case "notices": request = ["method": "notices"]
case "history":
    guard let metric = args.first, !metric.hasPrefix("-") else {
        fail("Usage: gauge history <metric> [--minutes N]. Metrics: \(API.historyMetrics.map(\.name).joined(separator: ", "))")
    }
    args.removeFirst()
    request = ["method": "history", "metric": .string(metric)]
    if let minutes = option("--minutes") { request = merge(request, ["minutes": .int(minutes)]) }
    if let points = option("--points") { request = merge(request, ["points": .int(points)]) }
case "help", "-h", "--help": print(usage); exit(0)
case "version", "--version": print("gauge \(version)"); exit(0)
default: fail("Unknown command \"\(command)\".\n\n\(usage)", code: 2)
}
if let extra = args.first { fail("Unexpected \"\(extra)\".\n\n\(usage)", code: 2) }

// Validate here too, so mistakes are explained without a round trip.
let parsed: Request
do { parsed = try Request(request) } catch { fail(error.description, code: 2) }

do {
    let result = try UnixSocketClient.send(parsed)
    if json { print(result.text(pretty: true)); exit(0) }
    switch parsed {
    case .vitals: print(Report.vitals(try result.decode()))
    case .apps: print(Report.apps(try result.decode()))
    case .servers: print(Report.servers(try result.decode()))
    case .port: print(Report.port(try result.decode()))
    case .notices: print(Report.notices(try result.decode()))
    case .history: print(Report.history(try result.decode()))
    }
} catch let failure as UnixSocketClient.Failure {
    fail(failure.description)
} catch {
    fail("Couldn't read Gauge's answer. Is this gauge from the same version as Gauge.app? (\(error))")
}
