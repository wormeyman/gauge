import Testing
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
    /// Trimmed from real `lsof -nP -iTCP -sTCP:LISTEN -Fpcn +c 0` output.
    static let lsof = """
    p471
    cControlCenter
    f9
    n*:7000
    f11
    n*:5000
    p22351
    cnode
    f14
    n*:3000
    p22385
    cnext-server (v16.3.0)
    f14
    n[::1]:3001
    f26
    n127.0.0.1:3002
    p33910
    cSpotify
    f55
    n*:62451
    p45199
    cjava
    f155
    n*:25565
    f179
    n*:8765
    p81580
    cjava
    f144
    n*:25566
    p23533
    cnode
    f16
    n[::1]:5179
    """

    @Test func parsesEveryListener() {
        let listeners = Sampler.parseListeners(Self.lsof)
        #expect(listeners.count == 10)
        #expect(listeners.first == .init(pid: 471, command: "ControlCenter", port: 7000))
        #expect(listeners.contains(.init(pid: 22385, command: "next-server (v16.3.0)", port: 3001)))
        #expect(listeners.contains(.init(pid: 23533, command: "node", port: 5179)))
    }

    @Test func ignoresMalformedLines() {
        let listeners = Sampler.parseListeners("n*:80\np12\ncnode\nn*:notaport\n\nn[::1]:4000\n")
        #expect(listeners == [.init(pid: 12, command: "node", port: 4000)])
    }

    @Test func keepsDevRuntimesGroupedByProcess() {
        let servers = Sampler.servers(from: Sampler.parseListeners(Self.lsof))
        #expect(servers.map(\.pid) == [22351, 22385, 23533, 45199, 81580])
        #expect(servers.first { $0.pid == 22385 }?.ports == [3001, 3002])
        #expect(!servers.contains { $0.name == "ControlCenter" || $0.name == "Spotify" })
    }

    @Test func minecraftOnJavaIsNotADevServer() {
        let servers = Sampler.servers(from: Sampler.parseListeners(Self.lsof))
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
