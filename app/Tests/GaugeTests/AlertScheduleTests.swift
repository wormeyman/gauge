import Foundation
import Testing
@testable import Gauge

@Suite struct AlertScheduleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func notice(_ title: String, hot: Bool = true, since: Date) -> Notice {
        Notice(tag: "Memory", title: title, body: "", hot: hot, since: since, target: "Memory")
    }

    @Test func waitsUntilANoticeHasHeld() {
        var schedule = AlertSchedule()
        let chrome = notice("Chrome is using a lot of memory", since: start)
        #expect(schedule.due([chrome], now: start.addingTimeInterval(10)).isEmpty)
        #expect(schedule.due([chrome], now: start.addingTimeInterval(30)).map(\.title) == [chrome.title])
    }

    @Test func quietNoticesAreNeverSent() {
        var schedule = AlertSchedule()
        let servers = notice("A dev server is running", hot: false, since: start)
        #expect(schedule.due([servers], now: start.addingTimeInterval(600)).isEmpty)
    }

    @Test func sentOnceWhileItLasts() {
        var schedule = AlertSchedule()
        let chrome = notice("Chrome is using a lot of memory", since: start)
        #expect(schedule.due([chrome], now: start.addingTimeInterval(30)).count == 1)
        #expect(schedule.due([chrome], now: start.addingTimeInterval(32)).isEmpty)
        // Still going after the cooldown: no repeat.
        #expect(schedule.due([chrome], now: start.addingTimeInterval(30 + AlertSchedule.cooldown)).isEmpty)
    }

    @Test func returningConditionWaitsForTheCooldown() {
        var schedule = AlertSchedule()
        let first = notice("Chrome is using a lot of memory", since: start)
        #expect(schedule.due([first], now: start.addingTimeInterval(30)).count == 1)
        #expect(schedule.due([], now: start.addingTimeInterval(60)).isEmpty)
        let again = notice(first.title, since: start.addingTimeInterval(120))
        #expect(schedule.due([again], now: start.addingTimeInterval(150)).isEmpty)
        let later = notice(first.title, since: start.addingTimeInterval(AlertSchedule.cooldown))
        #expect(schedule.due([], now: later.since).isEmpty)
        #expect(schedule.due([later], now: later.since.addingTimeInterval(30)).count == 1)
    }

    @Test func eachAppIsTrackedSeparately() {
        var schedule = AlertSchedule()
        let chrome = notice("Chrome is using a lot of memory", since: start)
        let xcode = notice("Xcode is using a lot of memory", since: start.addingTimeInterval(20))
        #expect(schedule.due([chrome, xcode], now: start.addingTimeInterval(30)).map(\.title) == [chrome.title])
        #expect(schedule.due([chrome, xcode], now: start.addingTimeInterval(50)).map(\.title) == [xcode.title])
    }
}
