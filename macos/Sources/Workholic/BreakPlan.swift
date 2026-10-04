import Foundation
import WorkholicCore

struct BreakItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var message: String
    var minutes: Int
    /// Time away from the screen. Turning the display off completes it.
    var rest: Bool
}

struct BreakPlan: Codable, Equatable {
    var enabled: Bool
    var everyMinutes: Int
    var items: [BreakItem]
    /// Which pause comes next. Kept on this Mac only; it is not synced.
    var cursor: Int

    init(enabled: Bool = true, everyMinutes: Int, items: [BreakItem], cursor: Int) {
        self.enabled = enabled
        self.everyMinutes = everyMinutes
        self.items = items
        self.cursor = cursor
    }

    // Plans saved before the on/off switch existed have no `enabled` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        everyMinutes = try container.decode(Int.self, forKey: .everyMinutes)
        items = try container.decode([BreakItem].self, forKey: .items)
        cursor = try container.decode(Int.self, forKey: .cursor)
    }

    var everyMs: Int64 { Int64(max(1, everyMinutes)) * 60_000 }

    /// Zero tells the reminder never to open a pause.
    var breakAfterMs: Int64 { enabled ? everyMs : 0 }

    var upcoming: BreakItem? {
        guard !items.isEmpty else { return nil }
        let index = ((cursor % items.count) + items.count) % items.count
        return items[index]
    }

    var due: DueBreak? {
        guard enabled, let item = upcoming else { return nil }
        return DueBreak(message: item.message, durationMs: Int64(max(1, item.minutes)) * 60_000, rest: item.rest)
    }

    /// The account's copy replaces everything except which pause is next.
    func adopting(_ remote: BreakSettingsPayload) -> BreakPlan {
        let items = remote.items.map {
            BreakItem(id: UUID(uuidString: $0.id) ?? UUID(), message: $0.message, minutes: $0.minutes, rest: $0.rest)
        }
        guard !items.isEmpty else { return self }
        return BreakPlan(enabled: remote.enabled, everyMinutes: remote.everyMinutes, items: items, cursor: cursor % items.count)
    }

    var payload: BreakSettingsPayload {
        BreakSettingsPayload(
            enabled: enabled,
            everyMinutes: everyMinutes,
            items: items.map { BreakItemPayload(id: $0.id.uuidString.lowercased(), message: $0.message, minutes: $0.minutes, rest: $0.rest) },
            updatedAtMs: nil
        )
    }

    mutating func advance() {
        guard !items.isEmpty else { return }
        cursor = (cursor + 1) % items.count
    }

    static let storageKey = "breakPlan"

    static var standard: BreakPlan {
        BreakPlan(
            everyMinutes: 15,
            items: [
                BreakItem(id: UUID(), message: "Step away from the screen.", minutes: 5, rest: true),
            ],
            cursor: 0
        )
    }

    static func load(defaults: UserDefaults = .standard) -> BreakPlan {
        guard let data = defaults.data(forKey: storageKey),
              let plan = try? JSONDecoder().decode(BreakPlan.self, from: data),
              !plan.items.isEmpty,
              plan.everyMinutes >= 1
        else { return standard }
        return plan
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: BreakPlan.storageKey)
    }
}
