import AppKit

/// Stopping dev servers and quitting apps. Gauge only acts on processes owned by the same user,
/// and checks a process's start time before signalling it so a reused PID is never hit.
enum ProcessControl {
    /// When a process started, in microseconds since 1970. Nil once the process has exited.
    static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// True while the process that started at `started` is still running (a zombie counts as gone).
    static func isRunning(_ pid: Int32, started: UInt64) -> Bool {
        startTime(pid) == started
    }

    enum SignalResult: Equatable {
        case sent
        /// The process had already exited, or its PID now belongs to another process.
        case gone
        /// Owned by another user, such as a server started with sudo.
        case notPermitted
    }

    /// Sends SIGTERM (the same request as Control-C in a terminal), or SIGKILL when forced.
    static func signal(_ pid: Int32, started: UInt64, force: Bool) -> SignalResult {
        guard pid > 1, pid != getpid(), isRunning(pid, started: started) else { return .gone }
        if kill(pid, force ? SIGKILL : SIGTERM) == 0 { return .sent }
        return errno == EPERM ? .notPermitted : .gone
    }

    /// Apps whose bundles live in /System/Library (Finder, Dock, Control Center and other parts of
    /// macOS) or that are Gauge itself aren't offered for quitting.
    static func isQuittable(bundlePath: String?, pid: Int32, ownPID: Int32 = getpid()) -> Bool {
        guard let bundlePath, bundlePath.hasSuffix(".app"), pid != ownPID else { return false }
        return !bundlePath.hasPrefix("/System/Library/") && !bundlePath.hasPrefix("/Library/Apple/")
    }

    /// Running apps Gauge can quit, keyed by the name the process list groups them under.
    @MainActor static func quittableApps() -> [String: [NSRunningApplication]] {
        var result: [String: [NSRunningApplication]] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            guard let url = app.bundleURL, isQuittable(bundlePath: url.path, pid: app.processIdentifier) else { continue }
            result[url.deletingPathExtension().lastPathComponent, default: []].append(app)
        }
        return result
    }
}
