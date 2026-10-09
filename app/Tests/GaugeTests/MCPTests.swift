import Foundation
import Testing
import GaugeKit

@Suite struct MCPTests {
    /// Records what each tool call asked for and answers with a canned result.
    final class FakeGauge: @unchecked Sendable {
        var requests: [Request] = []
        var result: JSON = ["ok": true]
        var failure: UnixSocketClient.Failure?
    }

    func server(_ fake: FakeGauge) -> MCPServer {
        MCPServer(version: "1.2.3") { request throws(UnixSocketClient.Failure) in
            fake.requests.append(request)
            if let failure = fake.failure { throw failure }
            return fake.result
        }
    }

    func send(_ fake: FakeGauge, _ text: String) throws -> JSON? {
        try server(fake).handle(line: Data(text.utf8)).map(JSON.parse)
    }

    @Test func initializeAnswersWithCapabilitiesAndVersion() throws {
        let response = try #require(try send(FakeGauge(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#))
        #expect(response["id"] == 1)
        #expect(response["result"]?["protocolVersion"] == "2025-06-18")
        #expect(response["result"]?["serverInfo"]?["name"] == "gauge")
        #expect(response["result"]?["serverInfo"]?["version"] == "1.2.3")
        #expect(response["result"]?["capabilities"]?["tools"] != nil)
    }

    @Test func unknownProtocolVersionGetsTheLatest() throws {
        let response = try #require(try send(FakeGauge(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(response["id"] == "a")
        #expect(response["result"]?["protocolVersion"] == .string(MCPServer.protocolVersion))
    }

    @Test func notificationsGetNoReply() throws {
        #expect(try send(FakeGauge(), #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func pingReturnsAnEmptyResult() throws {
        let response = try #require(try send(FakeGauge(), #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#))
        #expect(response["result"] == [:])
    }

    @Test func listsSixReadOnlyTools() throws {
        let response = try #require(try send(FakeGauge(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        guard case .array(let tools)? = response["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.compactMap { $0["name"]?.string } == ["get_vitals", "get_top_apps", "get_dev_servers", "check_port", "get_notices", "get_history"])
        for tool in tools {
            #expect(tool["annotations"]?["readOnlyHint"] == true)
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect((tool["description"]?.string?.count ?? 0) > 40)
        }
    }

    @Test func toolCallsMapToSocketRequests() throws {
        let fake = FakeGauge()
        fake.result = ["port": 3000, "free": true]
        let response = try #require(try send(fake, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"check_port","arguments":{"port":3000}}}"#))
        #expect(fake.requests == [.port(3000)])
        #expect(response["result"]?["isError"] == false)
        #expect(response["result"]?["structuredContent"] == fake.result)
        guard case .array(let content)? = response["result"]?["content"] else { Issue.record("no content"); return }
        #expect(content.first?["type"] == "text")
        #expect(try JSON.parse(Data((content.first?["text"]?.string ?? "").utf8)) == fake.result)

        _ = try send(fake, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_history","arguments":{"metric":"memory","minutes":30}}}"#)
        _ = try send(fake, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_top_apps","arguments":{"sort":"memory","limit":3}}}"#)
        _ = try send(fake, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_vitals"}}"#)
        #expect(fake.requests.dropFirst() == [.history(metric: "memory", minutes: 30, points: 60), .apps(sortBy: "memory", limit: 3), .vitals])
    }

    @Test func badArgumentsAreToolErrorsWithoutCallingGauge() throws {
        let fake = FakeGauge()
        let response = try #require(try send(fake, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"check_port","arguments":{"port":70000}}}"#))
        #expect(response["result"]?["isError"] == true)
        #expect(response["error"] == nil)
        #expect(fake.requests.isEmpty)
    }

    @Test func gaugeNotRunningIsAToolErrorThatSaysWhy() throws {
        let fake = FakeGauge()
        fake.failure = .notRunning
        let response = try #require(try send(fake, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_notices","arguments":{}}}"#))
        #expect(response["result"]?["isError"] == true)
        guard case .array(let content)? = response["result"]?["content"] else { Issue.record("no content"); return }
        #expect(content.first?["text"]?.string?.contains("Let local tools read Gauge") == true)
    }

    @Test func protocolErrors() throws {
        let unknownTool = try #require(try send(FakeGauge(), #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"stop_server"}}"#))
        #expect(unknownTool["error"]?["code"] == -32602)
        let unknownMethod = try #require(try send(FakeGauge(), #"{"jsonrpc":"2.0","id":11,"method":"resources/list"}"#))
        #expect(unknownMethod["error"]?["code"] == -32601)
        let garbage = try #require(try send(FakeGauge(), "{not json"))
        #expect(garbage["error"]?["code"] == -32700)
        #expect(garbage["id"] == .null)
        let notRPC = try #require(try send(FakeGauge(), #"{"id":12,"method":"ping"}"#))
        #expect(notRPC["error"]?["code"] == -32600)
    }
}

@Suite struct RequestTests {
    func parse(_ text: String) throws -> Request { try Request(JSON.parse(Data(text.utf8))) }

    @Test func defaultsAreFilledIn() throws {
        #expect(try parse(#"{"method":"vitals"}"#) == .vitals)
        #expect(try parse(#"{"method":"apps"}"#) == .apps(sortBy: "cpu", limit: 10))
        #expect(try parse(#"{"method":"history","metric":"cpu"}"#) == .history(metric: "cpu", minutes: 60, points: 60))
        #expect(try parse(#"{"method":"history","metric":"disk-read","minutes":90.0}"#) == .history(metric: "disk_read", minutes: 90, points: 60))
        #expect(try parse(#"{"method":"port","port":3000}"#) == .port(3000))
    }

    @Test func roundTripsThroughJSON() throws {
        for request: Request in [.vitals, .apps(sortBy: "memory", limit: 5), .servers, .port(8080), .notices,
                                 .history(metric: "battery", minutes: 1440, points: 100)] {
            #expect(try Request(request.json) == request)
        }
    }

    @Test func rejectsWhatItCantAnswer() {
        for text in [#"{}"#, #"{"method":"stop"}"#, #"{"method":"port"}"#, #"{"method":"port","port":0}"#,
                     #"{"method":"port","port":3000.5}"#, #"{"method":"apps","sort":"name"}"#, #"{"method":"apps","limit":51}"#,
                     #"{"method":"history"}"#, #"{"method":"history","metric":"temperature"}"#,
                     #"{"method":"history","metric":"cpu","minutes":20000}"#] {
            #expect(throws: Request.Invalid.self, "\(text)") { try parse(text) }
        }
    }
}

@Suite struct SocketTests {
    /// A real round trip over a Unix socket in a temporary folder.
    @Test func answersRequestsOnAnOwnerOnlySocket() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("t.sock").path
        let server = UnixSocketServer(path: path) { line in
            guard let request = try? Request(JSON.parse(line)) else { return API.failure("bad request") }
            return API.success(["echo": request.json])
        }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let result = try UnixSocketClient.send(.port(3000), path: path)
        #expect(result["echo"]?["port"] == 3000)
        #expect(throws: UnixSocketClient.Failure.refused("bad request")) { try UnixSocketClient.send(["method": "nope"], path: path) }

        // A second server on the same path refuses rather than taking over the socket.
        #expect(throws: UnixSocketServer.Failure.self) { try UnixSocketServer(path: path) { _ in Data() }.start() }

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: UnixSocketClient.Failure.notRunning) { try UnixSocketClient.send(.vitals, path: path) }
    }

    @Test func leavesFilesThatArentSocketsAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-\(UUID().uuidString.prefix(8)).sock")
        try Data("keep".utf8).write(to: file)
        #expect(throws: UnixSocketServer.Failure.self) { try UnixSocketServer(path: file.path) { _ in Data() }.start() }
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }
}

@Suite struct ReportTests {
    @Test func formatsSizesAndTables() {
        #expect(Report.bytes(512) == "512 B")
        #expect(Report.bytes(1_610_612_736) == "1.5 GB")
        #expect(Report.rate(20_480) == "20 KB/s")
        #expect(Report.minutes(90) == "1 h 30 min")
        #expect(Report.minutes(10_080) == "7 d")
        #expect(Report.table([["A", "1"], ["Long", "22"]], rightAligned: [1]) == "A      1\nLong  22")
    }

    @Test func historyWithoutPointsSaysSo() {
        let empty = HistorySeries(metric: "cpu", unit: "percent", minutes: 60, points: [])
        #expect(empty.summary == nil)
        #expect(Report.history(empty).contains("No cpu history"))
        let some = HistorySeries(metric: "cpu", unit: "percent", minutes: 60,
                                 points: [.init(time: Date(), value: 10), .init(time: Date(), value: 30)])
        #expect(some.summary == .init(min: 10, average: 20, max: 30))
    }
}
