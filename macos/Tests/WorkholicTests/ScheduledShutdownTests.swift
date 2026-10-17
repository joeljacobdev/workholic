import WorkholicCore
import XCTest

final class ScheduledShutdownTests: XCTestCase {
    private let minute: Int64 = 60_000

    private func at(_ hour: Int64, _ minutes: Int64) -> Int64 { (hour * 60 + minutes) * minute }

    private func decode(_ json: String) -> ShutdownRule? {
        try? JSONDecoder().decode(ShutdownRule.self, from: Data(json.utf8))
    }

    func testReadsTheServersShape() {
        XCTAssertEqual(decode(#"{"when": "time", "after": "22:00", "delay_minutes": 0, "command": "last-call"}"#),
                       ShutdownRule(when: .time, after: "22:00", command: "last-call"))
        XCTAssertEqual(decode(#"{"when": "limit", "after": null, "delay_minutes": 30, "command": null}"#),
                       ShutdownRule(when: .limit, delayMinutes: 30))
        XCTAssertEqual(decode(#"{"after": "22:00", "after_limit": true}"#), ShutdownRule(when: .time, after: "22:00"),
                       "the first version was a clock time")
        XCTAssertNil(decode(#"{"when": "sunset"}"#))
    }

    func testRuleIsCheckedAgainOnTheMac() {
        XCTAssertTrue(validShutdownRule(ShutdownRule(when: .time, after: "22:00", command: "last-call.sh")))
        XCTAssertTrue(validShutdownRule(ShutdownRule(when: .limit, delayMinutes: 30)))
        XCTAssertFalse(validShutdownRule(ShutdownRule(when: .time, after: "10pm")))
        XCTAssertFalse(validShutdownRule(ShutdownRule(when: .time)))
        XCTAssertFalse(validShutdownRule(ShutdownRule(when: .limit, delayMinutes: -1)))
        XCTAssertFalse(validShutdownRule(ShutdownRule(when: .limit, delayMinutes: 721)))
        for command in ["", "../x", "a/b", "/bin/sh", ".hidden", "a..b", "rm -rf", "$(id)", String(repeating: "x", count: 101)] {
            XCTAssertFalse(validShutdownRule(ShutdownRule(when: .time, after: "22:00", command: command)), command)
        }
    }

    func testGateOpensAtTheTime() {
        let rule = ShutdownRule(when: .time, after: "22:00")
        let now = Date()
        XCTAssertFalse(shutdownGateOpen(rule, msIntoDay: at(21, 59), overLimit: true, crossedAt: now, now: now))
        XCTAssertTrue(shutdownGateOpen(rule, msIntoDay: at(22, 0), overLimit: false, crossedAt: nil, now: now))
    }

    func testGateOpensTheDelayAfterTheLimitIsCrossed() {
        let rule = ShutdownRule(when: .limit, delayMinutes: 30)
        let crossed = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(shutdownGateOpen(rule, msIntoDay: at(23, 0), overLimit: false, crossedAt: nil, now: crossed))
        XCTAssertFalse(shutdownGateOpen(rule, msIntoDay: 0, overLimit: true, crossedAt: crossed, now: crossed.addingTimeInterval(29 * 60)))
        XCTAssertTrue(shutdownGateOpen(rule, msIntoDay: 0, overLimit: true, crossedAt: crossed, now: crossed.addingTimeInterval(30 * 60)))
    }

    func testCrossingIsRecordedOnlyAfterBeingSeenUnder() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        var crossing = limitCrossingStep(LimitCrossing(), day: "2026-10-17", over: true, now: t)
        XCTAssertNil(crossing.crossedAt, "started already over: no crossing, so no delay from launch")
        crossing = limitCrossingStep(crossing, day: "2026-10-17", over: false, now: t)
        crossing = limitCrossingStep(crossing, day: "2026-10-17", over: true, now: t.addingTimeInterval(60))
        XCTAssertEqual(crossing.crossedAt, t.addingTimeInterval(60))
        crossing = limitCrossingStep(crossing, day: "2026-10-17", over: true, now: t.addingTimeInterval(120))
        XCTAssertEqual(crossing.crossedAt, t.addingTimeInterval(60), "the first crossing stands")
        crossing = limitCrossingStep(crossing, day: "2026-10-18", over: true, now: t.addingTimeInterval(86_400))
        XCTAssertNil(crossing.crossedAt, "a crossing does not carry into the next day")
    }

    func testStartedOverTheLimitIsMissedEvenWithADelay() {
        let rule = ShutdownRule(when: .limit, delayMinutes: 30)
        let now = Date()
        let crossing = limitCrossingStep(LimitCrossing(), day: "2026-10-17", over: true, now: now)
        let gate = shutdownGateOpen(rule, msIntoDay: 0, overLimit: true, crossedAt: crossing.crossedAt, now: now)
        XCTAssertEqual(shutdownStep(ShutdownWatch(), day: "2026-10-17", gateOpen: gate).1, .missed)
    }

    func testCommandTimeShapes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = ISO8601DateFormatter().date(from: "2026-10-17T19:00:00Z")!  // 12:00 in Los Angeles
        let expected = ISO8601DateFormatter().date(from: "2026-10-18T04:30:00Z")!  // 21:30 in Los Angeles
        XCTAssertEqual(readShutdownTime("21:30\n", now: now, calendar: calendar), expected)
        XCTAssertEqual(readShutdownTime("2026-10-18T04:30:00Z", now: now, calendar: calendar), expected)
        XCTAssertEqual(readShutdownTime("2026-10-17T21:30:00-07:00", now: now, calendar: calendar), expected)
        XCTAssertEqual(readShutdownTime("2026-10-18T04:30:00.000Z", now: now, calendar: calendar), expected)
    }

    func testCommandOutputThatIsNotATimeIsNil() {
        let now = Date()
        XCTAssertNil(readShutdownTime("", now: now))
        XCTAssertNil(readShutdownTime("9:30", now: now))
        XCTAssertNil(readShutdownTime("2026-10-17T21:30:00", now: now))  // no zone
        XCTAssertNil(readShutdownTime("error: token expired", now: now))
        XCTAssertNil(readShutdownTime("21:30\n22:00", now: now))
    }

    func testFiresOnlyAfterSeeingTheGateShutThatDay() {
        var watch = ShutdownWatch()
        var status: ShutdownStatus
        (watch, status) = shutdownStep(watch, day: "2026-10-17", gateOpen: false)
        XCTAssertEqual(status, .waiting)
        (watch, status) = shutdownStep(watch, day: "2026-10-17", gateOpen: true)
        XCTAssertEqual(status, .ready)
    }

    func testStartingAfterTheTimeDoesNotShutDown() {
        let (_, status) = shutdownStep(ShutdownWatch(), day: "2026-10-17", gateOpen: true)
        XCTAssertEqual(status, .missed)
    }

    func testYesterdaysArmingDoesNotCount() {
        let (_, status) = shutdownStep(ShutdownWatch(armedDay: "2026-10-16"), day: "2026-10-17", gateOpen: true)
        XCTAssertEqual(status, .missed)
    }

    func testOnceADay() {
        let watch = ShutdownWatch(armedDay: "2026-10-17", doneDay: "2026-10-17")
        XCTAssertEqual(shutdownStep(watch, day: "2026-10-17", gateOpen: true).1, .done)
        XCTAssertEqual(shutdownStep(watch, day: "2026-10-17", gateOpen: false).1, .done)
        let (next, status) = shutdownStep(watch, day: "2026-10-18", gateOpen: false)
        XCTAssertEqual(status, .waiting)
        XCTAssertEqual(shutdownStep(next, day: "2026-10-18", gateOpen: true).1, .ready)
    }
}
