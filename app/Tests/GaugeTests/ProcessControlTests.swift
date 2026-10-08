import Foundation
import Testing
@testable import Gauge

@Suite struct ProcessControlTests {
    @Test func userAppsCanBeQuit() {
        #expect(ProcessControl.isQuittable(bundlePath: "/Applications/Spotify.app", pid: 500, ownPID: 1))
        #expect(ProcessControl.isQuittable(bundlePath: "/System/Applications/Notes.app", pid: 500, ownPID: 1))
        #expect(ProcessControl.isQuittable(bundlePath: "/Users/me/Applications/Tool.app", pid: 500, ownPID: 1))
    }

    @Test func macOSAndGaugeAreNotOffered() {
        #expect(!ProcessControl.isQuittable(bundlePath: "/System/Library/CoreServices/Finder.app", pid: 500, ownPID: 1))
        #expect(!ProcessControl.isQuittable(bundlePath: "/System/Library/CoreServices/Dock.app", pid: 500, ownPID: 1))
        #expect(!ProcessControl.isQuittable(bundlePath: "/Applications/Gauge.app", pid: 42, ownPID: 42))
        #expect(!ProcessControl.isQuittable(bundlePath: "/usr/libexec/rapportd", pid: 500, ownPID: 1))
        #expect(!ProcessControl.isQuittable(bundlePath: nil, pid: 500, ownPID: 1))
    }

    @Test func startTimeIdentifiesAProcess() throws {
        let own = try #require(ProcessControl.startTime(getpid()))
        #expect(ProcessControl.isRunning(getpid(), started: own))
        #expect(!ProcessControl.isRunning(getpid(), started: own + 1))
    }

    @Test func neverSignalsGaugeOrAReusedPID() {
        let own = ProcessControl.startTime(getpid()) ?? 0
        #expect(ProcessControl.signal(getpid(), started: own, force: false) == .gone)
        #expect(ProcessControl.signal(1, started: 0, force: false) == .gone)
    }

    @Test func stopsAServerAndSeesItExit() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        let started = try #require(ProcessControl.startTime(pid))
        #expect(ProcessControl.signal(pid, started: started + 1, force: false) == .gone)
        #expect(ProcessControl.signal(pid, started: started, force: false) == .sent)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
        #expect(!ProcessControl.isRunning(pid, started: started))
    }
}
