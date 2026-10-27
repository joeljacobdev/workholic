import WorkholicCore
import XCTest

final class AccountPlanTests: XCTestCase {
    private let workday: [[Int]] = [[540, 720], [780, 1080]]

    private func decode(_ json: String) -> AccountPlan? {
        try? JSONDecoder().decode(AccountPlan.self, from: Data(json.utf8))
    }

    private var planner: AccountPlan {
        AccountPlan(mode: .planner, weekdays: workday, weekends: [[600, 660]], shutdown: .lastBlock)
    }

    func testReadsTheServersShape() {
        let json = #"{"mode":"planner","weekdays":[[540,720],[780,1080]],"weekends":[[600,660]],"today":{"day":"2026-10-26","blocks":[[600,900]]},"outside":"pause","shutdown":"last_block","at":null,"delay_minutes":0,"command":"cal"}"#
        let plan = decode(json)
        XCTAssertEqual(plan?.mode, .planner)
        XCTAssertEqual(plan?.weekdays, workday)
        XCTAssertEqual(plan?.today, AccountPlan.Today(day: "2026-10-26", blocks: [[600, 900]]))
        XCTAssertEqual(plan?.shutdown, .lastBlock)
        XCTAssertEqual(plan?.command, "cal")
        XCTAssertNil(decode(#"{"mode":"tasks"}"#))
    }

    func testPlanIsCheckedAgainOnTheMac() {
        XCTAssertTrue(validAccountPlan(planner))
        XCTAssertTrue(validAccountPlan(AccountPlan(shutdown: .limit, delayMinutes: 30)))
        XCTAssertFalse(validAccountPlan(AccountPlan(weekdays: [[720, 540]])))
        XCTAssertFalse(validAccountPlan(AccountPlan(weekdays: [[540, 720], [700, 800]])), "blocks do not overlap")
        XCTAssertFalse(validAccountPlan(AccountPlan(weekdays: [[0, 1441]])))
        XCTAssertFalse(validAccountPlan(AccountPlan(mode: .planner, shutdown: .limit)), "a limit shutdown needs limit mode")
        XCTAssertFalse(validAccountPlan(AccountPlan(mode: .limit, shutdown: .lastBlock)), "the last block needs the planner")
        XCTAssertFalse(validAccountPlan(AccountPlan(shutdown: .time)), "a set time needs its time")
        XCTAssertFalse(validAccountPlan(AccountPlan(shutdown: .time, at: 600, command: "../x")))
    }

    func testTodaysBlocksReplaceTheUsualOnes() {
        var plan = planner
        plan.today = AccountPlan.Today(day: "2026-10-26", blocks: [[600, 900]])
        XCTAssertEqual(blocksFor(plan, day: "2026-10-26", weekend: false), [[600, 900]])
        XCTAssertEqual(blocksFor(plan, day: "2026-10-27", weekend: false), workday)
        XCTAssertEqual(blocksFor(plan, day: "2026-10-31", weekend: true), [[600, 660]])
    }

    func testShutdownRuleFromThePlan() {
        XCTAssertEqual(planShutdownRule(planner, blocks: workday), ShutdownRule(when: .time, after: "18:00"))
        XCTAssertNil(planShutdownRule(planner, blocks: []), "no blocks that day, no shutdown")
        XCTAssertEqual(planShutdownRule(planner, blocks: [[1200, 1440]])?.after, "23:59")
        XCTAssertEqual(planShutdownRule(AccountPlan(shutdown: .time, at: 1290, command: "cal"), blocks: []),
                       ShutdownRule(when: .time, after: "21:30", command: "cal"))
        XCTAssertEqual(planShutdownRule(AccountPlan(shutdown: .limit, delayMinutes: 30), blocks: []),
                       ShutdownRule(when: .limit, delayMinutes: 30))
        XCTAssertNil(planShutdownRule(AccountPlan(), blocks: workday))
    }

    func testEachMacCanHaveItsOwnShutdown() {
        let macA = "8b6c1c0e-3a1a-4e0a-9f1a-0c2b7a6d5e11"
        let macB = "1f0e2d3c-4b5a-4968-8776-655443322110"
        let json = #"{"mode":"limit","weekdays":[],"weekends":[],"today":null,"outside":"pause","shutdown":"time","at":600,"delay_minutes":0,"command":null,"scope":"each","each":{"\#(macA)":{"shutdown":"time","at":1290,"delay_minutes":0,"command":"cal"},"\#(macB)":{"shutdown":"limit","at":null,"delay_minutes":30,"command":null}}}"#
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

        let old = decode(#"{"mode":"limit","shutdown":"time","at":600,"delay_minutes":0}"#)
        XCTAssertEqual(old?.scope, .all, "a plan from before scope is the same on every Mac")
        XCTAssertEqual(old?.each, [:])

        var bad = plan
        bad.each[macA] = AccountPlan.MacShutdown(shutdown: .lastBlock)
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
        XCTAssertTrue(plannerCovers(planner, blocks: [], day: day, minute: 600), "a day without blocks stays covered")
    }

    func testNothingIsCoveredWhenTheGapsAreLeftAlone() {
        var plan = planner
        plan.outside = .none
        XCTAssertFalse(plannerCovers(plan, blocks: workday, day: "2026-10-26", minute: 480))
        XCTAssertFalse(plannerCovers(AccountPlan(), blocks: workday, day: "2026-10-26", minute: 480), "limit mode never covers")
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
}
