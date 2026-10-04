import Foundation
import WorkholicCore

enum BudgetStore {
    static let modeKey = "budgetMode"
    static let planKey = "dayBudget"

    static func mode(defaults: UserDefaults = .standard) -> BudgetMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = BudgetMode(rawValue: raw) else { return .fixed }
        return mode
    }

    static func setMode(_ mode: BudgetMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    static func plan(defaults: UserDefaults = .standard) -> DayBudget? {
        guard let data = defaults.data(forKey: planKey),
              let plan = try? JSONDecoder().decode(DayBudget.self, from: data) else { return nil }
        return plan
    }

    static func savePlan(_ plan: DayBudget?, defaults: UserDefaults = .standard) {
        if let plan, let data = try? JSONEncoder().encode(plan) {
            defaults.set(data, forKey: planKey)
        } else {
            defaults.removeObject(forKey: planKey)
        }
    }
}

func civilDay(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}
