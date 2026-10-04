import WorkholicCore
import XCTest

final class DayBudgetTests: XCTestCase {
    private let hour: Int64 = 3_600_000

    func testTodayIsTheSumOfTaskBudgets() {
        let tasks = [
            DayTask(name: "Write", budgetMs: 2 * hour),
            DayTask(name: "Review", budgetMs: 90 * 60_000),
        ]
        XCTAssertEqual(dayBudgetMs(tasks), 2 * hour + 90 * 60_000)
    }

    func testATaskPastADayDoesNotLeaveTimeForTomorrow() {
        let tasks = [DayTask(name: "Write", budgetMs: 30 * hour)]
        XCTAssertEqual(dayBudgetMs(tasks), DayBudgetRule.capMs)
        let today = DayBudget(day: "2026-10-04", tasks: tasks)
        XCTAssertEqual(budgetForDay(today, today: "2026-10-04")?.tasks.count, 1)
        XCTAssertNil(budgetForDay(today, today: "2026-10-05"))
    }

    func testTheDayStopsAt24Hours() {
        let tasks = [
            DayTask(name: "Write", budgetMs: 20 * hour),
            DayTask(name: "Review", budgetMs: 10 * hour),
        ]
        XCTAssertEqual(dayBudgetMs(tasks), DayBudgetRule.capMs)
    }

    func testBlankOrEmptyBudgetsDoNotCount() {
        let tasks = [
            DayTask(name: "  ", budgetMs: hour),
            DayTask(name: "Write", budgetMs: 0),
            DayTask(name: "Review", budgetMs: -5),
            DayTask(name: "Ship", budgetMs: hour),
        ]
        XCTAssertEqual(dayBudgetMs(tasks), hour)
    }

    func testAPlanFromAnotherDayIsDiscarded() {
        let plan = DayBudget(day: "2026-10-04", tasks: [DayTask(name: "Write", budgetMs: hour)])
        XCTAssertNil(budgetForDay(plan, today: "2026-10-05"))
        XCTAssertEqual(budgetForDay(plan, today: "2026-10-04")?.day, "2026-10-04")
    }

    func testAnEmptyPlanIsNotACommitment() {
        XCTAssertNil(budgetForDay(DayBudget(day: "2026-10-04", tasks: []), today: "2026-10-04"))
        XCTAssertNil(budgetForDay(nil, today: "2026-10-04"))
        XCTAssertEqual(dayBudgetMs([]), 0)
    }

    func testDynamicModeIgnoresTheStandingLimit() {
        let plan = DayBudget(day: "2026-10-04", tasks: [DayTask(name: "Write", budgetMs: 2 * hour)])
        let standing = 7 * hour
        XCTAssertEqual(
            committedBudgetMs(mode: .dynamic, fixedMs: standing, dayPlan: plan, today: "2026-10-04"),
            2 * hour
        )
        XCTAssertEqual(
            committedBudgetMs(mode: .fixed, fixedMs: standing, dayPlan: plan, today: "2026-10-04"),
            standing
        )
        XCTAssertNil(committedBudgetMs(mode: .dynamic, fixedMs: standing, dayPlan: plan, today: "2026-10-05"))
        XCTAssertNil(committedBudgetMs(mode: .dynamic, fixedMs: standing, dayPlan: nil, today: "2026-10-04"))
        XCTAssertNil(committedBudgetMs(mode: .fixed, fixedMs: nil, dayPlan: plan, today: "2026-10-04"))
    }

    func testATaskRecordsANameAndABudgetOnly() throws {
        let data = try JSONEncoder().encode(DayTask(name: "Write", budgetMs: hour))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["name", "budgetMs"]))
    }
}
