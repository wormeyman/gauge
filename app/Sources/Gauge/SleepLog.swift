import Foundation

/// A name and how many times it came up, such as a wake reason.
struct Tally: Equatable {
    var name: String
    var count: Int
}

/// The most recent sleep, from macOS's power log: battery at sleep and wake, and what woke the Mac.
struct SleepReport: Equatable {
    var slept: Date
    var woke: Date
    var chargeAtSleep: Int
    var chargeAtWake: Int
    /// The Mac woke on battery. A Mac that woke on power may have charged while asleep.
    var onBattery: Bool
    /// Brief background (dark) wakes while asleep.
    var wakes: Int
    /// Why it woke, in plain language, most frequent first.
    var reasons: [Tally]
    /// Processes that scheduled the wakes macOS chose, most frequent first.
    var requesters: [Tally]

    var drop: Int { chargeAtSleep - chargeAtWake }
    var minutes: Int { Int(woke.timeIntervalSince(slept) / 60) }
}

/// Reads and parses `pmset -g log`. The parser is a pure function of the log text so it can be tested
/// with sample lines; reading the log runs pmset, which needs no privileges and makes no network request.
enum SleepLog {
    /// What Gauge knows about the last sleep.
    enum Status: Equatable {
        case notRead
        /// pmset failed or its log couldn't be read.
        case unavailable
        /// The log was read; nil when it holds no complete sleep.
        case read(SleepReport?)
    }

    /// Runs pmset. Blocking (the log is a few megabytes), so call it off the main thread.
    static func read() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private enum Kind { case sleep, darkWake, wake, wakeRequests }

    private struct Event {
        var date: Date
        var kind: Kind
        var detail: Substring
    }

    /// The most recent complete sleep: from the first time the Mac went to sleep after a full wake
    /// to the next full wake. Nil when the log doesn't hold one.
    static func parse(_ log: String) -> SleepReport? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var wake: Event?
        var sleep: Event?
        var darkWakes: [Event] = []
        var requesters: [String: Int] = [:]
        // Newest first, so only the last sleep is parsed out of a log that goes back days.
        for line in log.split(separator: "\n").reversed() {
            guard let event = event(line, formatter: formatter) else { continue }
            if event.kind == .wake {
                if wake == nil { wake = event; continue }
                break  // the full wake before this sleep
            }
            guard wake != nil else { continue }
            switch event.kind {
            case .sleep: sleep = event  // keeps going back to the first one
            case .darkWake: darkWakes.append(event)
            case .wakeRequests:
                for name in chosenRequesters(event.detail) { requesters[name, default: 0] += 1 }
            case .wake: break
            }
        }
        guard let wake, let sleep, let atSleep = charge(sleep.detail), let atWake = charge(wake.detail) else { return nil }
        var reasons: [String: Int] = [:]
        for darkWake in darkWakes where darkWake.date > sleep.date { reasons[reason(dueTo(darkWake.detail)), default: 0] += 1 }
        return SleepReport(slept: sleep.date, woke: wake.date, chargeAtSleep: atSleep, chargeAtWake: atWake,
                           onBattery: wake.detail.lowercased().contains("using batt"),
                           wakes: darkWakes.count { $0.date > sleep.date },
                           reasons: ranked(reasons), requesters: ranked(requesters))
    }

    /// A wake reason from the log, in plain language.
    static func reason(_ dueTo: Substring) -> String {
        let text = dueTo.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("rtc", "maintenance", "sleepservice") { return "scheduled background tasks" }
        if has("wifibt", "arpt", "tcp", "wlan", "network") { return "network activity" }
        if has("lid") { return "the lid opening" }
        if has("usb-c_plug", "acattach", "ac power") { return "connecting power" }
        if has("pwrbtn", "powerbutton", "power button") { return "the power button" }
        if has("hid", "useractivity", "keyboard", "multi-touch") { return "the keyboard or trackpad" }
        if has("bluetooth") { return "Bluetooth" }
        if has("usb", "xhc") { return "a USB device" }
        return "other reasons"
    }

    // MARK: Line parsing

    /// Lines look like `2026-10-08 19:06:40 +0100 DarkWake            \tDarkWake from Deep Idle ...`.
    private static func event(_ line: Substring, formatter: DateFormatter) -> Event? {
        guard line.count > 26, let tab = line.firstIndex(of: "\t") else { return nil }
        let head = line[..<tab]
        let type = head.dropFirst(26).trimmingCharacters(in: .whitespaces)
        let kind: Kind
        let detail = line[line.index(after: tab)...].prefix { $0 != "\t" }
        switch type {
        case "Sleep": kind = .sleep
        case "DarkWake": kind = .darkWake
        // "Wake" also covers "DarkWake to FullWake", when a background wake turns into a full one.
        case "Wake": kind = .wake
        case "Wake Requests": kind = .wakeRequests
        default: return nil
        }
        guard let date = formatter.date(from: String(head.prefix(25))) else { return nil }
        return Event(date: date, kind: kind, detail: detail)
    }

    /// The battery percentage in `(Charge:76%)`.
    private static func charge(_ detail: Substring) -> Int? {
        guard let start = detail.range(of: "(Charge:") else { return nil }
        return Int(detail[start.upperBound...].prefix { $0.isNumber })
    }

    /// The text between "due to" and "Using", such as `NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/SleepService`.
    private static func dueTo(_ detail: Substring) -> Substring {
        guard let start = detail.range(of: "due to ") else { return "" }
        let rest = detail[start.upperBound...]
        return rest.range(of: " Using ").map { rest[..<$0.lowerBound] } ?? rest
    }

    /// pmset stars the request it scheduled the wake for: `[*process=dasd request=SleepService ...]`.
    private static func chosenRequesters(_ detail: Substring) -> [String] {
        detail.components(separatedBy: "[*process=").dropFirst().compactMap { part in
            part.split(separator: " ", maxSplits: 1).first.map(String.init)
        }
    }

    private static func ranked(_ counts: [String: Int]) -> [Tally] {
        counts.map { Tally(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}
