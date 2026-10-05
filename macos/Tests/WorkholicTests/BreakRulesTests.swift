import WorkholicCore
import XCTest

final class BreakRulesTests: XCTestCase {
    private let budget: Int64 = 25 * 60_000
    private let config = ReminderConfig(breakAfterMs: 50 * 60_000, awayResetMs: 5 * 60_000)
    private let rest = DueBreak(message: "Step away from the screen.", durationMs: 5 * 60_000, rest: true)
    private let sessionRest = DueBreak(message: "Session done.", durationMs: 5 * 60_000, rest: true, kind: .session)
    private let sessionGrip = DueBreak(message: "Hand grip.", durationMs: 60_000, rest: false, kind: .session)
    private let overtime = DueBreak(message: "Past the limit.", durationMs: 5 * 60_000, rest: true, kind: .overtime)

    private func opened(_ due: DueBreak) -> ActiveBreak {
        ActiveBreak(message: due.message, remainingMs: due.durationMs, durationMs: due.durationMs, rest: due.rest, kind: due.kind)
    }

    func testCoveredScreenIsNotAttention() {
        let sample = GateSample(onConsole: true, displayAwake: true, idleMs: 0, bundleId: "com.apple.Terminal", covered: true)
        XCTAssertFalse(attending(sample: sample, idleThresholdMs: 120_000))
        XCTAssertTrue(attending(sample: GateSample(onConsole: true, displayAwake: true, idleMs: 0, bundleId: "com.apple.Terminal"), idleThresholdMs: 120_000))
    }

    func testSessionBreakOpensWhenTheBudgetIsReached() {
        var state = ReminderState(session: BudgetSession(budgetMs: 25 * 60_000, attendedMs: 24 * 60_000))
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 60_000, sessionBreak: sessionRest), config: config)
        XCTAssertEqual(notices, [.sessionBudget(attendedMs: budget, budgetMs: budget), .beginBreak(opened(sessionRest))])
        XCTAssertEqual(state.activeBreak?.kind, .session)
        XCTAssertNil(state.extraDue)
    }

    func testSessionBreakIsOnlyANotificationWhenOff() {
        var state = ReminderState(session: BudgetSession(budgetMs: 25 * 60_000, attendedMs: 24 * 60_000))
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 60_000), config: config)
        XCTAssertEqual(notices, [.sessionBudget(attendedMs: budget, budgetMs: budget)])
        XCTAssertNil(state.activeBreak)
    }

    func testSessionBreakWaitsForTheCallToEnd() {
        var state = ReminderState(session: BudgetSession(budgetMs: 25 * 60_000, attendedMs: 24 * 60_000))
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 60_000, onCall: true, sessionBreak: sessionRest), config: config)
        XCTAssertEqual(notices, [])
        XCTAssertEqual(state.extraDue, sessionRest)
        (state, notices) = reminderStep(state: state, tick: ReminderTick(gapMs: 20_000, onCall: false, sessionBreak: sessionRest), config: config)
        XCTAssertEqual(notices, [.sessionBudget(attendedMs: budget, budgetMs: budget), .beginBreak(opened(sessionRest))])
    }

    func testDarkScreenCompletesAWaitingRestButNotAnActivity() {
        var state = ReminderState(extraDue: sessionRest)
        (state, _) = reminderStep(state: state, tick: ReminderTick(displayAwake: false), config: config)
        XCTAssertNil(state.extraDue)

        state = ReminderState(extraDue: sessionGrip)
        (state, _) = reminderStep(state: state, tick: ReminderTick(slept: true, displayAwake: false), config: config)
        XCTAssertEqual(state.extraDue, sessionGrip)
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(gapMs: 20_000), config: config)
        XCTAssertEqual(notices, [.beginBreak(opened(sessionGrip))])
    }

    func testAwayResetDropsAWaitingBreak() {
        var state = ReminderState(extraDue: sessionGrip)
        (state, _) = reminderStep(state: state, tick: ReminderTick(gapMs: 5 * 60_000, onCall: true), config: config)
        XCTAssertNil(state.extraDue)
    }

    func testOvertimeDoesNotGrowUnderTheLimit() {
        var state = ReminderState()
        (state, _) = reminderStep(
            state: state,
            tick: ReminderTick(attendedAddMs: 30 * 60_000, overLimit: false, overtimeAfterMs: 20 * 60_000, overtimeBreak: overtime),
            config: config
        )
        XCTAssertEqual(state.overtimeMs, 0)
        XCTAssertNil(state.activeBreak)
    }

    func testOvertimeBreakOpensAfterTheChosenStretchPastTheLimit() {
        var state = ReminderState()
        var notices: [ReminderNotice] = []
        let past = ReminderTick(attendedAddMs: 19 * 60_000, overLimit: true, overtimeAfterMs: 20 * 60_000, overtimeBreak: overtime)
        (state, notices) = reminderStep(state: state, tick: past, config: config)
        XCTAssertEqual(notices, [])
        XCTAssertEqual(state.overtimeMs, 19 * 60_000)
        var more = past
        more.attendedAddMs = 60_000
        (state, notices) = reminderStep(state: state, tick: more, config: config)
        XCTAssertEqual(notices, [.beginBreak(opened(overtime))])

        var effect: CountdownEffect?
        (state, effect) = countdownBreak(state: state, elapsedMs: 5 * 60_000, displayAwake: true, onCall: false)
        XCTAssertEqual(effect, .finished)
        XCTAssertEqual(state.overtimeMs, 0, "the next overtime break is a full stretch away")
    }

    func testTakingAnyBreakResetsOvertime() {
        let up = opened(rest)
        let state = skipBreak(state: ReminderState(stretchMs: 50 * 60_000, breakNotified: true, activeBreak: up, overtimeMs: 15 * 60_000))
        XCTAssertEqual(state.overtimeMs, 0)
        XCTAssertEqual(state.stretchMs, 0)
    }

    func testSessionBreakDueDuringAnotherBreakIsDroppedWhenThatBreakEnds() {
        let up = opened(rest)
        var state = ReminderState(
            stretchMs: 50 * 60_000,
            breakNotified: true,
            session: BudgetSession(budgetMs: 25 * 60_000, attendedMs: 24 * 60_000),
            activeBreak: up
        )
        (state, _) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 60_000, sessionBreak: sessionRest), config: config)
        XCTAssertEqual(state.activeBreak, up)
        XCTAssertEqual(state.extraDue, sessionRest)
        var effect: CountdownEffect?
        (state, effect) = countdownBreak(state: state, elapsedMs: 5 * 60_000, displayAwake: true, onCall: false)
        XCTAssertEqual(effect, .finished)
        XCTAssertNil(state.extraDue)
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 20_000, sessionBreak: sessionRest), config: config)
        XCTAssertEqual(notices, [], "no second break straight after the first")
    }

    func testRecurringBreakStillOpensWithTheNewFieldsUnset() {
        var state = ReminderState(stretchMs: 50 * 60_000 - 1)
        var notices: [ReminderNotice] = []
        (state, notices) = reminderStep(state: state, tick: ReminderTick(attendedAddMs: 20_000, dueBreak: rest), config: config)
        XCTAssertEqual(notices, [.beginBreak(opened(rest))])
        XCTAssertEqual(state.activeBreak?.kind, .recurring)
    }
}
