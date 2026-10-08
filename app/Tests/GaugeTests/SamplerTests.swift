import Testing
import Foundation
@testable import Gauge

@Suite struct AppNameTests {
    @Test func helpersGroupUnderTheirOuterApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(Sampler.appName(path: helper, command: "Google Chrome Helper (Renderer)") == "Google Chrome")
        #expect(Sampler.appName(path: "/Applications/Spotify.app/Contents/MacOS/Spotify", command: "Spotify") == "Spotify")
    }

    @Test func systemBinariesAreMacOS() {
        #expect(Sampler.appName(path: "/usr/libexec/rapportd", command: "rapportd") == "macOS")
        #expect(Sampler.appName(path: "/System/Library/CoreServices/launchservicesd", command: "launchservicesd") == "macOS")
        #expect(Sampler.appName(path: "/usr/bin/java", command: "java") == "macOS")
    }

    @Test func localToolsKeepTheirRuntimeName() {
        #expect(Sampler.appName(path: "/opt/homebrew/bin/node", command: "node") == "Node.js")
        #expect(Sampler.appName(path: "/usr/local/bin/python3.12", command: "python3.12") == "Python")
        #expect(Sampler.appName(path: "", command: "java") == "Java")
        #expect(Sampler.appName(path: "/opt/homebrew/bin/cloudflared", command: "cloudflared") == "cloudflared")
    }
}

@Suite struct DevServerTests {
    /// Listening sockets from a real Mac: system apps, dev runtimes and two Java game servers.
    static let listeners: [Sampler.Listener] = [
        .init(pid: 471, command: "ControlCenter", port: 7000),
        .init(pid: 471, command: "ControlCenter", port: 5000),
        .init(pid: 22351, command: "node", port: 3000),
        .init(pid: 22385, command: "next-server (v16.3.0)", port: 3001),
        .init(pid: 22385, command: "next-server (v16.3.0)", port: 3002),
        .init(pid: 33910, command: "Spotify", port: 62451),
        .init(pid: 45199, command: "java", port: 25565),
        .init(pid: 45199, command: "java", port: 8765),
        .init(pid: 81580, command: "java", port: 25566),
        .init(pid: 23533, command: "node", port: 5179),
    ]

    @Test func findsThisProcessListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        #expect(!Sampler.listeningPorts(getpid()).contains { $0 > 0 && $0 == Self.port(fd) })
        try #require(listen(fd, 1) == 0)
        #expect(Sampler.listeningPorts(getpid()).contains(Self.port(fd)))
    }

    static func port(_ fd: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    @Test func keepsDevRuntimesGroupedByProcess() {
        let servers = Sampler.servers(from: Self.listeners)
        #expect(servers.map(\.pid) == [22351, 22385, 23533, 45199, 81580])
        #expect(servers.first { $0.pid == 22385 }?.ports == [3001, 3002])
        #expect(!servers.contains { $0.name == "ControlCenter" || $0.name == "Spotify" })
    }

    @Test func minecraftOnJavaIsNotADevServer() {
        let servers = Sampler.servers(from: Self.listeners)
        let paper = servers.first { $0.pid == 45199 }
        #expect(paper?.name == "Minecraft")
        #expect(paper?.isDev == false)
        #expect(paper?.ports == [8765, 25565])
        #expect(servers.first { $0.pid == 81580 }?.isDev == false)
        #expect(servers.filter(\.isDev).map(\.name) == ["Node.js", "next-server (v16.3.0)", "Node.js"])
    }

    @Test func javaOnOtherPortsStaysADevServer() {
        let spring = Sampler.classify(DevServer(pid: 1, name: "Java", folder: "", ports: [8080], cpu: 0, memory: 0))
        #expect(spring.isDev)
        #expect(spring.name == "Java")
    }
}
