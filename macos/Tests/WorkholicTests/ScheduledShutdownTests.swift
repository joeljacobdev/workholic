import WorkholicCore
import XCTest

final class ScheduledShutdownTests: XCTestCase {
    private let minute: Int64 = 60_000

    private func at(_ hour: Int64, _ minutes: Int64) -> Int64 { (hour * 60 + minutes) * minute }

    private func decode(_ json: String) -> ShutdownRule? {
        try? JSONDecoder().decode(ShutdownRule.self, from: Data(json.utf8))
    }

    func testReadsTheServersShape() {
        XCTAssertEqual(decode(#"{"after": "22:00", "after_limit": true, "command": "last-call"}"#),
                       ShutdownRule(after: "22:00", afterLimit: true, command: "last-call"))
        XCTAssertEqual(decode(#"{"after": "22:00", "command": null}"#), ShutdownRule(after: "22:00"))
        XCTAssertNil(decode(#"{"after_limit": true}"#), "a time is required")
        XCTAssertNil(decode(#"{"after": 22}"#))
    }

    func testRuleIsCheckedAgainOnTheMac() {
        XCTAssertTrue(validShutdownRule(ShutdownRule(after: "22:00", command: "last-call.sh")))
        XCTAssertFalse(validShutdownRule(ShutdownRule(after: "10pm")))
        for command in ["", "../x", "a/b", "/bin/sh", ".hidden", "a..b", "rm -rf", "$(id)", String(repeating: "x", count: 101)] {
            XCTAssertFalse(validShutdownRule(ShutdownRule(after: "22:00", command: command)), command)
        }
    }

    func testGateOpensAtTheTime() {
        let rule = ShutdownRule(after: "22:00")
        XCTAssertFalse(shutdownGateOpen(rule, msIntoDay: at(21, 59), overLimit: true))
        XCTAssertTrue(shutdownGateOpen(rule, msIntoDay: at(22, 0), overLimit: false))
    }

    func testEveryPartMustHold() {
        let rule = ShutdownRule(after: "22:00", afterLimit: true)
        XCTAssertFalse(shutdownGateOpen(rule, msIntoDay: at(23, 0), overLimit: false))
        XCTAssertFalse(shutdownGateOpen(rule, msIntoDay: at(21, 0), overLimit: true))
        XCTAssertTrue(shutdownGateOpen(rule, msIntoDay: at(23, 0), overLimit: true))
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
