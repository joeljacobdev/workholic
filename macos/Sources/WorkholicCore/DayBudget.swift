import Foundation

public enum BudgetMode: String, Sendable, Equatable, Codable {
    case fixed
    case dynamic
}

public struct DayTask: Sendable, Equatable, Codable {
    public var name: String
    public var budgetMs: Int64

    public init(name: String, budgetMs: Int64) {
        self.name = name
        self.budgetMs = budgetMs
    }
}

/// Tasks for one local civil day (`yyyy-MM-dd`). There is no done flag.
public struct DayBudget: Sendable, Equatable, Codable {
    public var day: String
    public var tasks: [DayTask]

    public init(day: String, tasks: [DayTask]) {
        self.day = day
        self.tasks = tasks
    }
}

public enum DayBudgetRule {
    /// A task that would run past the day is not carried, and the day itself stops here.
    public static let capMs: Int64 = 24 * 3_600_000
}

/// Today's ceiling is the sum of the task budgets.
/// Each task, and the sum, stop at 24 hours. Time past that is dropped, not kept for tomorrow.
public func dayBudgetMs(_ tasks: [DayTask]) -> Int64 {
    var total: Int64 = 0
    for task in tasks {
        let name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }
        let piece = min(max(0, task.budgetMs), DayBudgetRule.capMs)
        guard piece > 0 else { continue }
        let room = DayBudgetRule.capMs - total
        if room <= 0 { break }
        total += min(piece, room)
    }
    return total
}

/// A plan counts only on its own civil day. Any other day is finished.
/// Nothing is carried forward, and completion is not tracked.
public func budgetForDay(_ plan: DayBudget?, today: String) -> DayBudget? {
    guard let plan, plan.day == today else { return nil }
    let kept = plan.tasks.filter { task in
        !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.budgetMs > 0
    }
    guard !kept.isEmpty else { return nil }
    return DayBudget(day: plan.day, tasks: kept)
}

/// The ceiling to compare with time already looked at.
/// Dynamic mode uses only today's tasks. It does not read or replace the standing fixed limit.
public func committedBudgetMs(mode: BudgetMode, fixedMs: Int64?, dayPlan: DayBudget?, today: String) -> Int64? {
    switch mode {
    case .fixed:
        return fixedMs
    case .dynamic:
        guard let plan = budgetForDay(dayPlan, today: today) else { return nil }
        let total = dayBudgetMs(plan.tasks)
        return total > 0 ? total : nil
    }
}
