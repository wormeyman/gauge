import Foundation

/// A Model Context Protocol server over stdio (JSON-RPC 2.0, one message per line) that answers
/// from Gauge's local API. Its tools only read; none can stop, quit or change anything.
///
/// `handle` is a pure function of a message and the API call it's given, so tests pass a fake.
public struct MCPServer: Sendable {
    public typealias Call = @Sendable (Request) throws(UnixSocketClient.Failure) -> JSON

    public static let protocolVersion = "2025-06-18"
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public var version: String
    public var call: Call

    public init(version: String, call: @escaping Call) {
        self.version = version
        self.call = call
    }

    /// Handles one line from stdin. Returns the line to write back, or nil for notifications.
    public func handle(line: Data) -> Data? {
        guard let message = try? JSON.parse(line) else { return reply(id: .null, error: (-32700, "Parse error")).data() }
        return handle(message)?.data()
    }

    public func handle(_ message: JSON) -> JSON? {
        guard case .object(let fields) = message, fields["jsonrpc"] == "2.0", let method = fields["method"]?.string else {
            return reply(id: message["id"] ?? .null, error: (-32600, "Invalid Request"))
        }
        // Without an id it's a notification, such as notifications/initialized, and gets no reply.
        guard let id = fields["id"], id != .null else { return nil }
        let params = fields["params"]?.object ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? Self.protocolVersion
            return reply(id: id, result: [
                "protocolVersion": .string(Self.supportedVersions.contains(asked) ? asked : Self.protocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "gauge", "title": "Gauge", "version": .string(version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": .array(Self.tools.map(\.definition))])
        case "tools/call":
            guard let name = params["name"]?.string, let tool = Self.tools.first(where: { $0.name == name }) else {
                return reply(id: id, error: (-32602, "Unknown tool: \(params["name"]?.string ?? "none given")"))
            }
            return reply(id: id, result: run(tool, arguments: params["arguments"]?.object ?? [:]))
        default:
            return reply(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    /// A tool's result. Problems the agent can act on (bad arguments, Gauge not running) come back
    /// as tool errors with an explanation, not protocol errors.
    func run(_ tool: Tool, arguments: [String: JSON]) -> JSON {
        var request = arguments
        request["method"] = .string(tool.method)
        do {
            let result = try call(try Request(.object(request)))
            return ["content": [["type": "text", "text": .string(result.text(pretty: true))]], "structuredContent": result, "isError": false]
        } catch {
            return ["content": [["type": "text", "text": .string("\(error)")]], "isError": true]
        }
    }

    private func reply(id: JSON, result: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }

    private func reply(id: JSON, error: (code: Int, message: String)) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }

    /// Reads stdin until it closes, answering each line on stdout.
    public func serve(output: FileHandle = .standardOutput) {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let response = handle(line: Data(line.utf8)) else { continue }
            output.write(response + Data("\n".utf8))
        }
    }

    // MARK: Tools

    struct Tool: Sendable {
        var name: String
        var title: String
        var method: String
        var description: String
        var properties: [String: JSON] = [:]
        var required: [String] = []

        var definition: JSON {
            ["name": .string(name), "title": .string(title), "description": .string(description),
             "inputSchema": ["type": "object", "properties": .object(properties), "required": .array(required.map(JSON.string)),
                             "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
        }
    }

    static let instructions = """
        Gauge is a system monitor running on this Mac. These tools read its live readings and local history. \
        They only read: nothing here can stop processes, quit apps or change settings. Byte values are bytes and \
        rates are bytes per second. A missing value is a reading Gauge can't take, not zero.
        """

    static let tools: [Tool] = [
        Tool(name: "get_vitals", title: "Get vitals", method: "vitals",
             description: "The Mac's six vitals right now: CPU load (percent of all cores, with user/system split), memory used of total with macOS memory pressure (normal, elevated or critical), GPU load, startup disk space and read/write rates, network download/upload rates, and battery (absent on Macs without one). Use this to check whether the Mac is under load before running something heavy."),
        Tool(name: "get_top_apps", title: "Get top apps", method: "apps",
             description: "The apps using the most CPU or memory right now, with helper processes grouped under their app. CPU is percent of one core, like Activity Monitor, so a busy app can exceed 100.",
             properties: ["sort": ["type": "string", "enum": ["cpu", "memory"], "description": "Sort by CPU (default) or memory."],
                          "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many apps to return (default 10)."]]),
        Tool(name: "get_dev_servers", title: "Get dev servers", method: "servers",
             description: "Local dev servers (Node.js, Bun, Deno, Python, Ruby, Java, PHP and similar runtimes) listening on TCP ports: pid, runtime, the folder each was started in, ports, CPU, memory, and whether it's idle. Use it to find a server you started earlier or one left running."),
        Tool(name: "check_port", title: "Check port", method: "port",
             description: "Whether a local TCP port is free to listen on. If it's taken, says which process holds it (pid, name, folder) when Gauge can see it. Check before starting a dev server on a fixed port.",
             properties: ["port": ["type": "integer", "minimum": 1, "maximum": 65535, "description": "The TCP port, such as 3000."]],
             required: ["port"]),
        Tool(name: "get_notices", title: "Get notices", method: "notices",
             description: "Gauge's current 'Worth a look' notices in plain language: sustained memory pressure, apps holding a lot of CPU, a nearly full startup disk, running dev servers, and low battery health. needsAttention marks the ones Gauge highlights. An empty list means nothing needs a look."),
        Tool(name: "get_history", title: "Get history", method: "history",
             description: "Averaged history of one metric from Gauge's local database, oldest first, with min/average/max. Gauge records a reading every 10 seconds while it runs, so gaps mean Gauge wasn't running. Units: cpu, gpu and battery in percent; memory in bytes; download, upload, disk_read and disk_write in bytes per second.",
             properties: ["metric": ["type": "string", "enum": .array(API.historyMetrics.map { .string($0.name) }), "description": "Which metric."],
                          "minutes": ["type": "integer", "minimum": 1, "maximum": 10080, "description": "How far back to look, in minutes (default 60; up to 7 days)."],
                          "points": ["type": "integer", "minimum": 2, "maximum": 500, "description": "How many averaged points to return (default 60)."]],
             required: ["metric"]),
    ]
}
