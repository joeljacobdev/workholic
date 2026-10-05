import WorkholicCore
import XCTest

final class ScheduledBreaksTests: XCTestCase {
    private let minute: Int64 = 60_000
    private lazy var lunch = ScheduledBreak(id: "lunch", startMinute: 13 * 60, durationMs: 45 * minute, message: "Lunch.")
    private lazy var tea = ScheduledBreak(id: "tea", startMinute: 13 * 60 + 30, durationMs: 15 * minute, message: "Tea.")

    private func at(_ hour: Int64, _ minutes: Int64) -> Int64 { (hour * 60 + minutes) * minute }

    func testClockMinuteReadsTwentyFourHourTime() {
        XCTAssertEqual(clockMinute("13:05"), 785)
        XCTAssertEqual(clockMinute("00:00"), 0)
        XCTAssertEqual(clockMinute("23:59"), 1439)
        XCTAssertNil(clockMinute("24:00"))
        XCTAssertNil(clockMinute("9:00"))
        XCTAssertNil(clockMinute("12:60"))
        XCTAssertNil(clockMinute("noon"))
    }

    func testWindowIncludesItsStartAndExcludesItsEnd() {
        XCTAssertNil(dueScheduled([lunch], msIntoDay: at(12, 59), day: "2026-10-05", handled: [:]))
        XCTAssertEqual(dueScheduled([lunch], msIntoDay: at(13, 0), day: "2026-10-05", handled: [:])?.remainingMs, 45 * minute)
        XCTAssertNil(dueScheduled([lunch], msIntoDay: at(13, 45), day: "2026-10-05", handled: [:]))
    }

    func testALateStartShowsOnlyWhatIsLeftOfTheWindow() {
        let due = dueScheduled([lunch], msIntoDay: at(13, 30), day: "2026-10-05", handled: [:])
        XCTAssertEqual(due?.entry, lunch)
        XCTAssertEqual(due?.remainingMs, 15 * minute)
    }

    func testAHandledEntryWaitsForTheNextDay() {
        let handled = ["lunch": "2026-10-05"]
        XCTAssertNil(dueScheduled([lunch], msIntoDay: at(13, 10), day: "2026-10-05", handled: handled))
        XCTAssertNotNil(dueScheduled([lunch], msIntoDay: at(13, 10), day: "2026-10-06", handled: handled))
    }

    func testTheEarliestStartWinsWhenWindowsOverlap() {
        XCTAssertEqual(dueScheduled([tea, lunch], msIntoDay: at(13, 35), day: "2026-10-05", handled: [:])?.entry, lunch)
        let handled = ["lunch": "2026-10-05"]
        XCTAssertEqual(dueScheduled([tea, lunch], msIntoDay: at(13, 35), day: "2026-10-05", handled: handled)?.entry, tea)
    }

    func testBeginningOpensAScheduledPauseThatIsNotARest() {
        let (state, notices) = beginScheduledBreak(state: ReminderState(), entry: lunch, remainingMs: 15 * minute)
        let expected = ActiveBreak(message: "Lunch.", remainingMs: 15 * minute, durationMs: 45 * minute, rest: false, kind: .scheduled, scheduleId: "lunch")
        XCTAssertEqual(state.activeBreak, expected)
        XCTAssertEqual(notices, [.beginBreak(expected)])
    }

    func testBeginningDoesNothingWhileAnotherPauseIsUp() {
        let up = ActiveBreak(message: "Walk.", remainingMs: minute, durationMs: minute, rest: true)
        let (state, notices) = beginScheduledBreak(state: ReminderState(activeBreak: up), entry: lunch, remainingMs: minute)
        XCTAssertEqual(state.activeBreak, up)
        XCTAssertEqual(notices, [])
    }

    func testSnoozeTakesThePauseDownWithoutCountingItAsTaken() {
        let up = ActiveBreak(message: "Lunch.", remainingMs: 30 * minute, durationMs: 45 * minute, rest: false, kind: .scheduled, scheduleId: "lunch")
        let before = ReminderState(stretchMs: 10 * minute, activeBreak: up, overtimeMs: 4 * minute)
        let (state, snoozed) = snoozeBreak(state: before)
        XCTAssertNil(state.activeBreak)
        XCTAssertEqual(snoozed, up)
        XCTAssertEqual(state.stretchMs, 10 * minute)
        XCTAssertEqual(state.overtimeMs, 4 * minute)
        XCTAssertEqual(state.snoozed, up)
        XCTAssertEqual(state.snoozeLeftMs, BreakTiming.snoozeMs)
    }
}
