import WorkholicCore
import XCTest

final class AccountPlanTests: XCTestCase {
    private let workday: [[Int]] = [[540, 720], [780, 1080]]

    private func decode(_ json: String) -> AccountPlan? {
        try? JSONDecoder().decode(AccountPlan.self, from: Data(json.utf8))
    }

    private func dated(_ blocks: [[Int]], on day: String = "2026-10-26") -> [AccountPlan.DatedBlocks] {
        [AccountPlan.DatedBlocks(day: day, blocks: blocks)]
    }

    private var planner: AccountPlan {
        AccountPlan(dates: dated(workday), shutdown: .planEnd)
    }

    func testReadsTheServersShape() {
        let json = #"{"dates":[{"day":"2026-10-26","blocks":[[540,720],[780,1080]]},{"day":"2026-10-31","blocks":[[600,660]]}],"outside":"pause","shutdown":"plan_end","at":null,"delay_minutes":0,"command":"cal"}"#
        let plan = decode(json)
        XCTAssertEqual(plan?.dates.map(\.day), ["2026-10-26", "2026-10-31"])
        XCTAssertEqual(plan?.dates.first?.blocks, workday)
        XCTAssertEqual(plan?.shutdown, .planEnd)
        XCTAssertEqual(plan?.command, "cal")
        XCTAssertNil(decode(#"{"mode":"limit"}"#), "the old shape is no plan")
    }

    func testPlanIsCheckedAgainOnTheMac() {
        XCTAssertTrue(validAccountPlan(planner))
        XCTAssertTrue(validAccountPlan(AccountPlan(shutdown: .planEnd, delayMinutes: 30)))
        XCTAssertFalse(validAccountPlan(AccountPlan(shutdown: .planEnd, delayMinutes: 721)))
        XCTAssertFalse(validAccountPlan(AccountPlan(dates: dated([[720, 540]]))))
        XCTAssertFalse(validAccountPlan(AccountPlan(dates: dated([[540, 720], [700, 800]]))), "blocks do not overlap")
        XCTAssertFalse(validAccountPlan(AccountPlan(dates: dated([[0, 1441]]))))
        XCTAssertFalse(validAccountPlan(AccountPlan(dates: dated([]))), "a date without blocks is not entered")
        XCTAssertFalse(validAccountPlan(AccountPlan(dates: dated(workday, on: "26/10/2026"))))
        XCTAssertFalse(validAccountPlan(AccountPlan(dates: dated(workday, on: "2026-10-27") + dated(workday))), "soonest first")
        XCTAssertFalse(validAccountPlan(AccountPlan(dates: dated(workday) + dated(workday))), "no date twice")
        XCTAssertFalse(validAccountPlan(AccountPlan(shutdown: .time)), "a set time needs its time")
        XCTAssertFalse(validAccountPlan(AccountPlan(shutdown: .time, at: 600, command: "../x")))
    }

    func testShutdownRuleFromThePlan() {
        XCTAssertEqual(planShutdownRule(planner, blocks: workday), ShutdownRule(when: .time, after: "18:00"))
        XCTAssertEqual(planShutdownRule(planner, blocks: []), ShutdownRule(when: .limit), "no blocks that day, after the limit")
        XCTAssertEqual(planShutdownRule(planner, blocks: [[1200, 1440]])?.after, "23:59")
        XCTAssertEqual(planShutdownRule(AccountPlan(shutdown: .time, at: 1290, command: "cal"), blocks: []),
                       ShutdownRule(when: .time, after: "21:30", command: "cal"))
        XCTAssertEqual(planShutdownRule(AccountPlan(shutdown: .planEnd, delayMinutes: 30), blocks: []),
                       ShutdownRule(when: .limit, delayMinutes: 30))
        XCTAssertNil(planShutdownRule(AccountPlan(), blocks: workday))
    }

    func testEachMacCanHaveItsOwnShutdown() {
        let macA = "8b6c1c0e-3a1a-4e0a-9f1a-0c2b7a6d5e11"
        let macB = "1f0e2d3c-4b5a-4968-8776-655443322110"
        let json = #"{"dates":[],"outside":"pause","shutdown":"time","at":600,"delay_minutes":0,"command":null,"scope":"each","each":{"\#(macA)":{"shutdown":"time","at":1290,"delay_minutes":0,"command":"cal"},"\#(macB)":{"shutdown":"plan_end","at":null,"delay_minutes":30,"command":null}}}"#
        guard let plan = decode(json) else { return XCTFail("a plan with entries per Mac decodes") }
        XCTAssertEqual(plan.scope, .each)
        XCTAssertTrue(validAccountPlan(plan))
        XCTAssertEqual(planShutdownRule(plan, blocks: [], deviceId: macA), ShutdownRule(when: .time, after: "21:30", command: "cal"))
        XCTAssertEqual(planShutdownRule(plan, blocks: [], deviceId: macB), ShutdownRule(when: .limit, delayMinutes: 30))
        XCTAssertNil(planShutdownRule(plan, blocks: [], deviceId: "00000000-0000-4000-8000-000000000000"), "a Mac not listed does not shut down")
        XCTAssertNil(planShutdownRule(plan, blocks: []), "no Mac named, no shutdown under each")

        var shared = plan
        shared.scope = .all
        XCTAssertEqual(planShutdownRule(shared, blocks: [], deviceId: macB)?.after, "10:00", "under all, every Mac follows the plan's own shutdown")

        let old = decode(#"{"dates":[],"shutdown":"time","at":600,"delay_minutes":0}"#)
        XCTAssertEqual(old?.scope, .all, "a plan from before scope is the same on every Mac")
        XCTAssertEqual(old?.each, [:])

        var bad = plan
        bad.each[macA] = AccountPlan.MacShutdown(shutdown: .time)
        XCTAssertFalse(validAccountPlan(bad), "an entry follows the plan's own rules")
        bad.each[macA] = AccountPlan.MacShutdown(shutdown: .time, at: 600, command: "../x")
        XCTAssertFalse(validAccountPlan(bad))
    }

    func testCoversOutsideTheBlocksOnly() {
        let day = "2026-10-26"
        XCTAssertTrue(plannerCovers(planner, blocks: workday, day: day, minute: 480), "before the first block")
        XCTAssertFalse(plannerCovers(planner, blocks: workday, day: day, minute: 540), "a block starts on its minute")
        XCTAssertTrue(plannerCovers(planner, blocks: workday, day: day, minute: 720), "and ends on its last")
        XCTAssertTrue(plannerCovers(planner, blocks: workday, day: day, minute: 1200), "after the last block")
        XCTAssertFalse(plannerCovers(planner, blocks: [], day: day, minute: 600), "a day without blocks follows the limit")
    }

    func testNothingIsCoveredWhenTheGapsAreLeftAlone() {
        var plan = planner
        plan.outside = .none
        XCTAssertFalse(plannerCovers(plan, blocks: workday, day: "2026-10-26", minute: 480))
    }

    func testFifteenMoreMinutes() {
        let day = "2026-10-26"
        let pass = morePass(day: day, minute: 730)
        XCTAssertEqual(pass, PlannerPass(day: day, untilMinute: 745))
        XCTAssertFalse(plannerCovers(planner, blocks: workday, day: day, minute: 744, pass: pass))
        XCTAssertTrue(plannerCovers(planner, blocks: workday, day: day, minute: 745, pass: pass))
        XCTAssertEqual(morePass(day: day, minute: 1435).untilMinute, 1440)
    }

    func testUnlockLastsUntilTheNextBlock() {
        let day = "2026-10-26"
        let pass = unlockPass(workday, day: day, minute: 730)
        XCTAssertEqual(pass.untilMinute, 780)
        XCTAssertFalse(plannerCovers(planner, blocks: workday, day: day, minute: 779, pass: pass))
        XCTAssertFalse(plannerCovers(planner, blocks: workday, day: day, minute: 800, pass: pass), "inside the block")
        XCTAssertTrue(plannerCovers(planner, blocks: workday, day: day, minute: 1100, pass: pass), "the next gap covers again")
        XCTAssertEqual(unlockPass(workday, day: day, minute: 1100).untilMinute, 1440, "after the last block, for the rest of the day")
        XCTAssertTrue(plannerCovers(planner, blocks: workday, day: "2026-10-27", minute: 480, pass: unlockPass(workday, day: day, minute: 1100)),
                      "a pass ends with its day")
    }

    func testPlannedMinutes() {
        XCTAssertEqual(plannedMinutes(workday), 480)
        XCTAssertEqual(plannedMinutes([]), 0)
    }

    // Blocks on chosen dates; every other day follows the daily limit. The plan is read from the
    // server's shape, which has no mode, weekdays, weekends or today.
    private let blockDay = "2026-12-01"
    private let freeDay = "2026-12-02"

    private func datesPlan(outside: String = "pause", shutdown: String = "plan_end", delay: Int = 30) -> AccountPlan? {
        decode(#"{"dates":[{"day":"2026-12-01","blocks":[[540,720],[780,1080]]}],"outside":"\#(outside)","shutdown":"\#(shutdown)","at":null,"delay_minutes":\#(delay),"command":null,"scope":"all","each":{}}"#)
    }

    func testPlanWithOnlyDatesIsRead() {
        XCTAssertNotNil(datesPlan(), "no mode needed")
        XCTAssertNotNil(decode(#"{"dates":[]}"#), "no dates is a plan")
        XCTAssertEqual(datesPlan()?.shutdown, .planEnd)
        if let plan = datesPlan() { XCTAssertTrue(validAccountPlan(plan)) }
    }

    func testBlocksOnlyOnTheirDate() {
        guard let plan = datesPlan() else { return XCTFail("a plan with dates decodes") }
        XCTAssertEqual(blocksOn(plan, day: blockDay), workday)
        XCTAssertEqual(blocksOn(plan, day: freeDay), [])
        XCTAssertEqual(blocksOn(plan, day: "2026-11-30"), [])
    }

    func testABlockDateCoversOutsideItsBlocksAndAFreeDateIsNeverCovered() {
        guard let plan = datesPlan() else { return XCTFail("a plan with dates decodes") }
        let onBlockDay = blocksOn(plan, day: blockDay)
        let onFreeDay = blocksOn(plan, day: freeDay)
        XCTAssertTrue(plannerCovers(plan, blocks: onBlockDay, day: blockDay, minute: 480), "before the first block")
        XCTAssertFalse(plannerCovers(plan, blocks: onBlockDay, day: blockDay, minute: 600), "inside a block")
        XCTAssertTrue(plannerCovers(plan, blocks: onBlockDay, day: blockDay, minute: 1200), "after the last block")
        XCTAssertFalse(plannerCovers(plan, blocks: onFreeDay, day: freeDay, minute: 600), "a day without blocks is not covered")
        XCTAssertFalse(plannerCovers(plan, blocks: onFreeDay, day: freeDay, minute: 1200))
    }

    func testTheLimitAppliesOnlyOnDaysWithoutBlocks() {
        guard let plan = datesPlan() else { return XCTFail("a plan with dates decodes") }
        XCTAssertFalse(limitApplies(blocksOn(plan, day: blockDay)), "on a block date only the blocks count")
        XCTAssertTrue(limitApplies(blocksOn(plan, day: freeDay)))
        XCTAssertTrue(limitApplies([]))
    }

    func testLeavingTheGapsAloneStillNeverCoversOnABlockDate() {
        guard let plan = datesPlan(outside: "none") else { return XCTFail("a plan with dates decodes") }
        XCTAssertFalse(plannerCovers(plan, blocks: blocksOn(plan, day: blockDay), day: blockDay, minute: 480))
    }

    func testPlanEndFollowsTheDay() {
        guard let plan = datesPlan(delay: 30) else { return XCTFail("a plan with dates decodes") }
        XCTAssertEqual(planShutdownRule(plan, blocks: blocksOn(plan, day: blockDay)), ShutdownRule(when: .time, after: "18:00"),
                       "on a block date, the last block's end")
        XCTAssertEqual(planShutdownRule(plan, blocks: blocksOn(plan, day: freeDay)), ShutdownRule(when: .limit, delayMinutes: 30),
                       "on any other day, after the limit")
        guard let midnight = decode(#"{"dates":[{"day":"2026-12-01","blocks":[[1200,1440]]}],"shutdown":"plan_end"}"#) else { return XCTFail("decodes") }
        XCTAssertEqual(planShutdownRule(midnight, blocks: blocksOn(midnight, day: blockDay))?.after, "23:59")
    }

    func testASetTimeAndOffDoNotDependOnTheDay() {
        guard let timed = decode(#"{"dates":[{"day":"2026-12-01","blocks":[[540,720]]}],"shutdown":"time","at":1290}"#),
              let off = datesPlan(shutdown: "off") else { return XCTFail("decodes") }
        XCTAssertEqual(planShutdownRule(timed, blocks: blocksOn(timed, day: blockDay)), ShutdownRule(when: .time, after: "21:30"))
        XCTAssertEqual(planShutdownRule(timed, blocks: blocksOn(timed, day: freeDay)), ShutdownRule(when: .time, after: "21:30"))
        XCTAssertNil(planShutdownRule(off, blocks: blocksOn(off, day: blockDay)))
    }

    func testDatesAreCheckedAgainOnTheMac() {
        XCTAssertNil(decode(#"{"dates":[{"day":"2026-12-01","blocks":[[540,720]]}],"shutdown":"limit"}"#), "limit is no longer a choice; plan_end replaces it")
        XCTAssertNil(decode(#"{"dates":[{"day":"2026-12-01","blocks":[[540,720]]}],"shutdown":"last_block"}"#))
        if let bad = decode(#"{"dates":[{"day":"2026-12-01","blocks":[[720,540]]}]}"#) {
            XCTAssertFalse(validAccountPlan(bad), "a backwards block")
        } else { XCTFail("the shape decodes; the check refuses it") }
        if let overlap = decode(#"{"dates":[{"day":"2026-12-01","blocks":[[540,720],[700,800]]}]}"#) {
            XCTAssertFalse(validAccountPlan(overlap), "blocks do not overlap")
        } else { XCTFail("the shape decodes; the check refuses it") }
    }
}
