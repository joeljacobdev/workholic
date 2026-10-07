import WorkholicCore
import XCTest

final class ReminderTests: XCTestCase {
    private let config = ReminderConfig(breakAfterMs: 50 * 60_000, awayResetMs: 5 * 60_000)
    private let rest = DueBreak(message: "Step away from the screen.", durationMs: 5 * 60_000, rest: true)
    private let grip = DueBreak(message: "Hand grip.", durationMs: 60_000, rest: false)

    func testBreakOpensWhenTheWorkIntervalIsReached() {
        var state = ReminderState()
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 49 * 60_000, dueBreak: rest), config: config)
        XCTAssertEqual(notices, [])
        XCTAssertEqual(state.stretchMs, 49 * 60_000)

        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 60_000, dueBreak: rest), config: config)
        let opened = ActiveBreak(message: rest.message, remainingMs: rest.durationMs, durationMs: rest.durationMs, rest: true)
        XCTAssertEqual(notices, [.beginBreak(opened)])
        XCTAssertEqual(state.activeBreak, opened)
        XCTAssertEqual(state.stretchMs, 50 * 60_000)
    }

    func testCountdownFinishesThePauseAndClearsTheStretch() {
        let opened = ActiveBreak(message: rest.message, remainingMs: 1_500, durationMs: rest.durationMs, rest: true)
        var state = ReminderState(stretchMs: 50 * 60_000, breakNotified: true, activeBreak: opened)
        var effect: CountdownEffect?
        (state, effect) = countdownBreak(state: state, elapsedMs: 1_000, displayAwake: true, onCall: false)
        XCTAssertEqual(effect, .running(remainingMs: 500))
        (state, effect) = countdownBreak(state: state, elapsedMs: 1_000, displayAwake: true, onCall: false)
        XCTAssertEqual(effect, .finished)
        XCTAssertNil(state.activeBreak)
        XCTAssertEqual(state.stretchMs, 0)
    }

    func testSkippingEndsThePauseAndRestartsTheInterval() {
        let opened = ActiveBreak(message: rest.message, remainingMs: 4 * 60_000, durationMs: rest.durationMs, rest: true)
        var state = skipBreak(state: ReminderState(stretchMs: 50 * 60_000, breakNotified: true, activeBreak: opened))
        XCTAssertNil(state.activeBreak)
        XCTAssertEqual(state.stretchMs, 0)

        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 49 * 60_000, dueBreak: rest), config: config)
        XCTAssertEqual(notices, [], "the next pause waits a full interval")
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 60_000, dueBreak: rest), config: config)
        XCTAssertEqual(notices.count, 1)
    }

    func testBreakDoesNotOpenAgainWhileOneIsUp() {
        var state = ReminderState(stretchMs: 50 * 60_000 - 1)
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 1, dueBreak: rest), config: config)
        XCTAssertEqual(notices.count, 1)
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 20_000, dueBreak: rest), config: config)
        XCTAssertEqual(notices, [])
        XCTAssertEqual(state.stretchMs, 50 * 60_000)
    }

    func testShortGapDoesNotResetTheStretch() {
        var state = ReminderState(stretchMs: 40 * 60_000)
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(gapMs: 20_000), config: config)
        XCTAssertEqual(notices, [])
        XCTAssertEqual(state.stretchMs, 40 * 60_000)
        XCTAssertEqual(state.awayMs, 20_000)

        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 20_000), config: config)
        XCTAssertEqual(state.stretchMs, 40 * 60_000 + 20_000)
        XCTAssertEqual(state.awayMs, 0)
    }

    func testFiveMinutesAwayResetsTheStretch() {
        var state = ReminderState(stretchMs: 40 * 60_000, awayMs: 4 * 60_000)
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(gapMs: 60_000), config: config)
        XCTAssertEqual(notices, [])
        XCTAssertEqual(state.stretchMs, 0)

        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 20_000), config: config)
        XCTAssertEqual(state.stretchMs, 20_000)
        XCTAssertEqual(notices, [])
    }

    func testSleepResetsTheStretchImmediately() {
        let state = ReminderState(stretchMs: 30 * 60_000, awayMs: 1_000)
        let (next, notices) = reminderStep(state: state, tick: ReminderTick(slept: true), config: config)
        XCTAssertEqual(notices, [])
        XCTAssertEqual(next.stretchMs, 0)
        XCTAssertEqual(next.awayMs, 0)
    }

    func testCallHoldsTheBreakUntilTheMicAndCameraAreOff() {
        var state = ReminderState(stretchMs: 49 * 60_000)
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(
            state: state,
            tick: ReminderTick(attendedAddMs: 60_000, onCall: true, dueBreak: rest),
            config: config
        )
        XCTAssertEqual(notices, [])
        XCTAssertTrue(state.heldBreak)
        XCTAssertNil(state.activeBreak)
        XCTAssertEqual(state.stretchMs, 50 * 60_000)

        (state, notices) = reminderStep(
            state: state,
            tick: ReminderTick(attendedAddMs: 60_000, onCall: true, dueBreak: rest),
            config: config
        )
        XCTAssertEqual(notices, [])
        XCTAssertEqual(state.stretchMs, 50 * 60_000)

        (state, notices) = reminderStep(state: state, tick: ReminderTick(dueBreak: rest), config: config)
        XCTAssertEqual(notices, [.beginBreak(ActiveBreak(message: rest.message, remainingMs: rest.durationMs, durationMs: rest.durationMs, rest: true))])
        XCTAssertFalse(state.heldBreak)
        XCTAssertEqual(state.stretchMs, 50 * 60_000)
    }

    func testDarkScreenCompletesARestAndDoesNotCompleteAHandGrip() {
        let restState = ReminderState(
            stretchMs: 20 * 60_000,
            breakNotified: true,
            activeBreak: ActiveBreak(message: rest.message, remainingMs: 4 * 60_000, durationMs: rest.durationMs, rest: true)
        )
        let (done, restNotices) = reminderStep(state: restState, tick: ReminderTick(displayAwake: false, dueBreak: rest), config: config)
        XCTAssertEqual(restNotices, [.breakFinished])
        XCTAssertEqual(done.stretchMs, 0)
        XCTAssertNil(done.activeBreak)

        let gripState = ReminderState(
            stretchMs: 20 * 60_000,
            breakNotified: true,
            activeBreak: ActiveBreak(message: grip.message, remainingMs: 30_000, durationMs: grip.durationMs, rest: false)
        )
        let (still, gripNotices) = countdownBreak(state: gripState, elapsedMs: 1_000, displayAwake: false, onCall: false)
        XCTAssertEqual(gripNotices, .running(remainingMs: 29_000))
        XCTAssertEqual(still.activeBreak?.remainingMs, 29_000)
    }

    func testDarkScreenBeforeThePauseCountsAsTheRest() {
        let state = ReminderState(stretchMs: 40 * 60_000)
        let (next, notices) = reminderStep(
            state: state,
            tick: ReminderTick(displayAwake: false, dueBreak: rest),
            config: config
        )
        XCTAssertEqual(notices, [])
        XCTAssertEqual(next.stretchMs, 0)
        XCTAssertNil(next.activeBreak)
    }

    func testCallHidesThePauseWithoutFinishingIt() {
        let opened = ActiveBreak(message: grip.message, remainingMs: 40_000, durationMs: grip.durationMs, rest: false)
        var state = ReminderState(stretchMs: 15 * 60_000, breakNotified: true, activeBreak: opened)
        var effect: CountdownEffect?
        (state, effect) = countdownBreak(state: state, elapsedMs: 1_000, displayAwake: true, onCall: true)
        XCTAssertEqual(effect, .hideForCall)
        XCTAssertEqual(state.activeBreak?.remainingMs, 40_000)
        (state, effect) = countdownBreak(state: state, elapsedMs: 1_000, displayAwake: true, onCall: false)
        XCTAssertEqual(effect, .resume(ActiveBreak(message: grip.message, remainingMs: 40_000, durationMs: grip.durationMs, rest: false)))
    }

    func testLeavingForFiveMinutesDropsAHeldBreak() {
        let state = ReminderState(stretchMs: 50 * 60_000, breakNotified: true, heldBreak: true)
        let (next, notices) = reminderStep(
            state: state,
            tick: ReminderTick(gapMs: 5 * 60_000, onCall: true),
            config: config
        )
        XCTAssertEqual(notices, [])
        XCTAssertFalse(next.heldBreak)
        XCTAssertEqual(next.stretchMs, 0)
    }

    func testAttendedAddCountsOnlyExtendedTime() {
        XCTAssertEqual(attendedAddMs(.extend(addMs: 20_000)), 20_000)
        XCTAssertEqual(
            attendedAddMs(.fillSeal(fillMs: 10_000, restartWallMs: 300_000, restartUptimeMs: 300_000, appKey: "Mail")),
            10_000
        )
        XCTAssertEqual(attendedAddMs(.hold), 0)
        XCTAssertEqual(attendedAddMs(.start(appKey: "Mail", wallMs: 1, uptimeMs: 1)), 0)
        XCTAssertEqual(attendedAddMs(.seal), 0)
        XCTAssertEqual(attendedAddMs(.sealAndStart(appKey: "Mail", wallMs: 1, uptimeMs: 1)), 0)
        XCTAssertEqual(attendedAddMs(.extend(addMs: -5)), 0)
    }
}
