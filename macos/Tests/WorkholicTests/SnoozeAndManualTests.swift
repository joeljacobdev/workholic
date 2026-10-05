import WorkholicCore
import XCTest

final class SnoozeAndManualTests: XCTestCase {
    private let minute: Int64 = 60_000
    private let config = ReminderConfig(breakAfterMs: 50 * 60_000, awayResetMs: 5 * 60_000)
    private let rest = DueBreak(message: "Step away from the screen.", durationMs: 5 * 60_000, rest: true)

    private func up(_ kind: BreakKind = .recurring, rest isRest: Bool = true, remaining: Int64 = 3 * 60_000) -> ActiveBreak {
        ActiveBreak(message: "Pause.", remainingMs: remaining, durationMs: 5 * 60_000, rest: isRest, kind: kind)
    }

    func testEveryAutomaticKindCanBeSnoozed() {
        for kind in [BreakKind.recurring, .session, .overtime, .scheduled] {
            let (state, held) = snoozeBreak(state: ReminderState(activeBreak: up(kind)))
            XCTAssertNil(state.activeBreak, "\(kind)")
            XCTAssertEqual(held, up(kind))
        }
    }

    func testABreakYouStartedCannotBeSnoozed() {
        let manual = up(.manual, rest: false)
        let (state, held) = snoozeBreak(state: ReminderState(activeBreak: manual))
        XCTAssertEqual(state.activeBreak, manual)
        XCTAssertNil(held)
        XCTAssertNil(state.snoozed)
    }

    func testASnoozedBreakComesBackAfterFiveMinutesWithTheTimeItHadLeft() {
        var (state, _) = snoozeBreak(state: ReminderState(stretchMs: 50 * minute, breakNotified: true, activeBreak: up()))
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 4 * minute, gapMs: 4 * minute, dueBreak: rest), config: config)
        XCTAssertEqual(notices, [], "no new break opens while one is snoozed")
        XCTAssertNil(state.activeBreak)
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: minute, gapMs: minute, dueBreak: rest), config: config)
        XCTAssertEqual(notices, [.resumeBreak(up())])
        XCTAssertEqual(state.activeBreak, up())
        XCTAssertNil(state.snoozed)
    }

    func testASnoozedBreakWaitsForTheCallToEnd() {
        var (state, _) = snoozeBreak(state: ReminderState(activeBreak: up()))
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 5 * minute, gapMs: 5 * minute, onCall: true), config: config)
        XCTAssertEqual(notices, [])
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 20_000, gapMs: 20_000), config: config)
        XCTAssertEqual(notices, [.resumeBreak(up())])
    }

    func testADarkScreenCompletesASnoozedRest() {
        var (state, _) = snoozeBreak(state: ReminderState(activeBreak: up()))
        (state, _) = reminderStep(state: state, tick: ReminderTick(displayAwake: false), config: config)
        XCTAssertNil(state.snoozed)
    }

    func testADarkScreenKeepsASnoozedLunch() {
        let lunch = up(.scheduled, rest: false)
        var (state, _) = snoozeBreak(state: ReminderState(activeBreak: lunch))
        (state, _) = reminderStep(state: state, tick: ReminderTick(slept: true, displayAwake: false), config: config)
        XCTAssertEqual(state.snoozed, lunch)
        (state, _) = reminderStep(state: state, tick: ReminderTick(gapMs: 5 * minute, onCall: true), config: config)
        XCTAssertEqual(state.snoozed, lunch, "stepping away is not lunch")
    }

    func testTakingAnotherBreakDropsASnoozedOneButNotLunch() {
        var (state, _) = snoozeBreak(state: ReminderState(activeBreak: up(.overtime)))
        state.activeBreak = up(.manual, rest: false)
        state = skipBreak(state: state)
        XCTAssertNil(state.snoozed)

        (state, _) = snoozeBreak(state: ReminderState(activeBreak: up(.scheduled, rest: false)))
        state.activeBreak = up(.manual, rest: false)
        state = skipBreak(state: state)
        XCTAssertNotNil(state.snoozed)
    }

    func testStartingABreakByHand() {
        let (state, notices) = beginManualBreak(state: ReminderState(), message: "Break.", durationMs: 10 * minute)
        let expected = ActiveBreak(message: "Break.", remainingMs: 10 * minute, durationMs: 10 * minute, rest: false, kind: .manual)
        XCTAssertEqual(state.activeBreak, expected)
        XCTAssertEqual(notices, [.beginBreak(expected)])

        let (same, none) = beginManualBreak(state: state, message: "Again.", durationMs: minute)
        XCTAssertEqual(same.activeBreak, expected)
        XCTAssertEqual(none, [])
    }
}
