import Foundation
import Testing
@testable import Gauge

@Suite struct SleepLogTests {
    /// Trimmed from a real `pmset -g log` on an Apple silicon MacBook: the lid closes on battery, the Mac
    /// wakes briefly for timers and the network, then the lid opens. Earlier lines are a previous sleep.
    let log = """
    2026-10-07 23:10:02 +0100 Sleep               \tEntering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:91%) 3600 secs\u{20}\u{20}
    2026-10-07 23:30:00 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using BATT (Charge:91%) 45 secs\u{20}\u{20}\u{20}\u{20}
    2026-10-08 00:18:08 +0100 Wake                \tWake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch/HID Activity Using BATT (Charge:90%)
    2026-10-08 00:18:08 +0100 WakeDetails         \tDriverReason:smc.sysState.Wake(0x70070000) - DriverDetails:
    2026-10-08 00:40:12 +0100 Assertions          \tPID 412(Safari) Created PreventUserIdleSystemSleep "Playing audio" 00:00:00  id:0x0x1000a  [System: PrevIdle DeclUser kDisp]
    2026-10-08 00:52:31 +0100 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:88%) 1071 secs\u{20}\u{20}
    2026-10-08 00:52:34 +0100 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7200 wakeAt=2026-10-08 02:52:34 info="upkeep wake"] [*process=dasd request=SleepService deltaSecs=1071 wakeAt=2026-10-08 01:10:25 info="com.apple.dasd:501:com.apple.searchd.heartbeat"] [process=powerd request=TCPKATurnOff deltaSecs=313612 wakeAt=2026-10-12 10:10:37]
    2026-10-08 01:10:25 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:87%) 2 secs\u{20}\u{20}\u{20}\u{20}
    2026-10-08 01:10:25 +0100 WakeTime            \tWakeTime: 0.319 sec                                                        \t
    2026-10-08 01:10:27 +0100 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:87%) 986 secs\u{20}\u{20}
    2026-10-08 01:10:30 +0100 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7200 wakeAt=2026-10-08 03:10:30 info="upkeep wake"] [*process=dasd request=SleepService deltaSecs=983 wakeAt=2026-10-08 01:26:53 info="com.apple.dasd:501:com.apple.searchd.heartbeat"]
    2026-10-08 01:26:53 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:86%) 2 secs\u{20}\u{20}\u{20}\u{20}
    2026-10-08 01:26:55 +0100 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:86%) 656 secs\u{20}\u{20}
    2026-10-08 01:26:58 +0100 Wake Requests       \t[*process=mDNSResponder request=Maintenance deltaSecs=7200 wakeAt=2026-10-08 03:26:58 info="upkeep wake"] [process=powerd request=CSPNEvaluation deltaSecs=1721 wakeAt=2026-10-08 01:55:39]
    2026-10-08 02:31:40 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty centauri-alpha E_TKO_TCP_DATA ARPT/ Using BATT (Charge:84%) 45 secs\u{20}\u{20}\u{20}
    2026-10-08 02:32:25 +0100 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:84%) 1073 secs\u{20}
    2026-10-08 08:31:02 +0100 Wake                \tWake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch/HID Activity Using BATT (Charge:76%)
    2026-10-08 08:31:02 +0100 WakeDetails         \tDriverReason:smc.sysState.Wake(0x70070000) - DriverDetails:
    2026-10-08 08:31:02 +0100 WakeTime            \tWakeTime: 0.411 sec                                                        \t
    2026-10-08 08:45:10 +0100 Assertions          \tPID 88(WindowServer) Released UserIsActive "com.apple.iohideventsystem.queue.tickle" 00:14:08  id:0x0x1000b
    """

    func date(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: text)!
    }

    @Test func parsesTheMostRecentSleep() throws {
        let report = try #require(SleepLog.parse(log))
        #expect(report.slept == date("2026-10-08 00:52:31 +0100"))
        #expect(report.woke == date("2026-10-08 08:31:02 +0100"))
        #expect(report.chargeAtSleep == 88)
        #expect(report.chargeAtWake == 76)
        #expect(report.drop == 12)
        #expect(report.onBattery)
        #expect(report.wakes == 3)
        #expect(report.minutes == 458)
        #expect(report.reasons == [Tally(name: "scheduled background tasks", count: 2), Tally(name: "network activity", count: 1)])
        #expect(report.requesters == [Tally(name: "dasd", count: 2), Tally(name: "mDNSResponder", count: 1)])
    }

    @Test func darkWakeToFullWakeEndsTheSleep() throws {
        let lines = """
        2026-10-08 23:26:04 +0100 Sleep               \tEntering DarkWake state due to 'Clamshell Sleep':TCPKeepAlive=active Using AC (Charge:100%) 5261 secs\u{20}
        2026-10-09 00:53:45 +0100 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:100%)
        """
        let report = try #require(SleepLog.parse(lines))
        #expect(report.drop == 0)
        #expect(!report.onBattery)
        #expect(report.wakes == 0)
    }

    @Test func noCompleteSleep() {
        #expect(SleepLog.parse("") == nil)
        #expect(SleepLog.parse("Unable to read the power management log\n") == nil)
        // Asleep but not yet awake again: the log ends before a full wake.
        let asleep = """
        2026-10-08 00:52:31 +0100 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:88%) 1071 secs
        2026-10-08 01:10:25 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:87%) 2 secs
        """
        #expect(SleepLog.parse(asleep) == nil)
    }

    @Test func wakeReasonsInPlainLanguage() {
        #expect(SleepLog.reason("NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/SleepService") == "scheduled background tasks")
        #expect(SleepLog.reason("EC.RTC (Maintenance)/Maintenance") == "scheduled background tasks")
        #expect(SleepLog.reason("smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty centauri-alpha E_TKO_TCP_DATA ARPT/") == "network activity")
        #expect(SleepLog.reason("EC.LidOpen (User)/Lid Open") == "the lid opening")
        #expect(SleepLog.reason("smc.sysState.Wake(0x70070000) USB-C_plug SMC.OutboxNotEmpty") == "connecting power")
        #expect(SleepLog.reason("EC.PowerButton (User)") == "the power button")
        #expect(SleepLog.reason("MTP.DOCK.CHANNELS.AP0.IRQ RTP.keyboard/UserActivity Assertion") == "the keyboard or trackpad")
        #expect(SleepLog.reason("XHC1") == "a USB device")
        #expect(SleepLog.reason("") == "other reasons")
    }
}
