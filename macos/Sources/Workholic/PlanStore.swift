import Foundation
import WorkholicCore

/// The account's day plan as this Mac last heard it, with its version, so the check asks for it
/// only when it changed. And the pass that lets this Mac be used outside the blocks for a while.
enum PlanStore {
    private static let planKey = "accountPlan"
    private static let updatedAtKey = "accountPlanUpdatedAt"
    private static let passKey = "plannerPass"
    /// Left by builds before the account plan: this Mac's own budget mode, task list, and shutdown.
    private static let oldKeys = ["budgetMode", "dayBudget", "shutdownSchedule"]

    /// The default plan when none is stored, or when the stored one fails the Mac's own checks.
    static func plan(defaults: UserDefaults = .standard) -> AccountPlan {
        guard let data = defaults.data(forKey: planKey),
              let plan = try? JSONDecoder().decode(AccountPlan.self, from: data),
              validAccountPlan(plan) else { return AccountPlan() }
        return plan
    }

    /// Nil until the account has been asked, so the first check fetches the plan.
    static func updatedAt(defaults: UserDefaults = .standard) -> Int64? {
        (defaults.object(forKey: updatedAtKey) as? NSNumber)?.int64Value
    }

    static func save(_ plan: AccountPlan, updatedAt: Int64, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(plan) { defaults.set(data, forKey: planKey) }
        defaults.set(NSNumber(value: updatedAt), forKey: updatedAtKey)
    }

    static func pass(defaults: UserDefaults = .standard) -> PlannerPass? {
        guard let data = defaults.data(forKey: passKey) else { return nil }
        return try? JSONDecoder().decode(PlannerPass.self, from: data)
    }

    static func savePass(_ pass: PlannerPass?, defaults: UserDefaults = .standard) {
        if let pass, let data = try? JSONEncoder().encode(pass) {
            defaults.set(data, forKey: passKey)
        } else {
            defaults.removeObject(forKey: passKey)
        }
    }

    static func clear(defaults: UserDefaults = .standard) {
        for key in [planKey, updatedAtKey, passKey] + oldKeys {
            defaults.removeObject(forKey: key)
        }
    }

    static func dropOldKeys(defaults: UserDefaults = .standard) {
        for key in oldKeys {
            defaults.removeObject(forKey: key)
        }
    }
}

func civilDay(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}
