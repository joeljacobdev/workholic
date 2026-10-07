import Foundation
import WorkholicCore

struct BreakItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var message: String
    var minutes: Int
    /// Time away from the screen. Turning the display off completes it.
    var rest: Bool
}

/// Past the daily limit, a pause after every `everyMinutes` of further looking.
struct OvertimeRule: Codable, Equatable, Sendable {
    var enabled: Bool
    var everyMinutes: Int
    var message: String
    var minutes: Int
    var rest: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case everyMinutes = "every_minutes"
        case message
        case minutes
        case rest
    }

    static let standard = OvertimeRule(enabled: false, everyMinutes: 25, message: "You are past today's limit. Step away.", minutes: 5, rest: true)
}

/// A pause at a local clock time. `at` is 24-hour `HH:MM`.
struct ScheduledItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var at: String
    var message: String
    var minutes: Int
}

struct BreakPlan: Codable, Equatable {
    /// Off means no pause of any kind.
    var enabled: Bool
    var everyMinutes: Int
    var items: [BreakItem]
    /// Which pause comes next. Kept on this Mac only; it is not synced.
    var cursor: Int
    /// The every-few-minutes pause, separately from the other kinds.
    var recurringEnabled: Bool
    var overtime: OvertimeRule
    var scheduled: [ScheduledItem]

    init(
        enabled: Bool = true,
        everyMinutes: Int,
        items: [BreakItem],
        cursor: Int,
        recurringEnabled: Bool = true,
        overtime: OvertimeRule = .standard,
        scheduled: [ScheduledItem] = []
    ) {
        self.enabled = enabled
        self.everyMinutes = everyMinutes
        self.items = items
        self.cursor = cursor
        self.recurringEnabled = recurringEnabled
        self.overtime = overtime
        self.scheduled = scheduled
    }

    // Plans saved before the on/off switch existed have no `enabled` key,
    // and plans saved before the newer kinds have none of theirs. A stored `session` key is ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        everyMinutes = try container.decode(Int.self, forKey: .everyMinutes)
        items = try container.decode([BreakItem].self, forKey: .items)
        cursor = try container.decode(Int.self, forKey: .cursor)
        recurringEnabled = try container.decodeIfPresent(Bool.self, forKey: .recurringEnabled) ?? true
        overtime = try container.decodeIfPresent(OvertimeRule.self, forKey: .overtime) ?? .standard
        scheduled = try container.decodeIfPresent([ScheduledItem].self, forKey: .scheduled) ?? []
    }

    var everyMs: Int64 { Int64(max(1, everyMinutes)) * 60_000 }

    /// Zero tells the reminder never to open a pause.
    var breakAfterMs: Int64 { enabled && recurringEnabled ? everyMs : 0 }

    var upcoming: BreakItem? {
        guard !items.isEmpty else { return nil }
        let index = ((cursor % items.count) + items.count) % items.count
        return items[index]
    }

    var due: DueBreak? {
        guard enabled, recurringEnabled, let item = upcoming else { return nil }
        return DueBreak(message: item.message, durationMs: Int64(max(1, item.minutes)) * 60_000, rest: item.rest)
    }

    var overtimeDue: DueBreak? {
        guard enabled, overtime.enabled else { return nil }
        return DueBreak(message: overtime.message, durationMs: Int64(max(1, overtime.minutes)) * 60_000, rest: overtime.rest, kind: .overtime)
    }

    /// Zero turns overtime pauses off.
    var overtimeAfterMs: Int64 { enabled && overtime.enabled ? Int64(max(1, overtime.everyMinutes)) * 60_000 : 0 }

    var scheduledEntries: [ScheduledBreak] {
        guard enabled else { return [] }
        return scheduled.compactMap { item in
            guard let start = clockMinute(item.at) else { return nil }
            return ScheduledBreak(id: item.id, startMinute: start, durationMs: Int64(max(1, item.minutes)) * 60_000, message: item.message)
        }
    }

    /// The account's copy replaces everything except which pause is next.
    /// An account from before the newer kinds leaves this Mac's copy of them alone.
    func adopting(_ remote: BreakSettingsPayload) -> BreakPlan {
        let items = remote.items.map {
            BreakItem(id: UUID(uuidString: $0.id) ?? UUID(), message: $0.message, minutes: $0.minutes, rest: $0.rest)
        }
        guard !items.isEmpty else { return self }
        return BreakPlan(
            enabled: remote.enabled,
            everyMinutes: remote.everyMinutes,
            items: items,
            cursor: cursor % items.count,
            recurringEnabled: remote.recurringEnabled ?? recurringEnabled,
            overtime: remote.overtime ?? overtime,
            scheduled: remote.scheduled ?? scheduled
        )
    }

    var payload: BreakSettingsPayload {
        BreakSettingsPayload(
            enabled: enabled,
            everyMinutes: everyMinutes,
            items: items.map { BreakItemPayload(id: $0.id.uuidString.lowercased(), message: $0.message, minutes: $0.minutes, rest: $0.rest) },
            updatedAtMs: nil,
            recurringEnabled: recurringEnabled,
            overtime: overtime,
            scheduled: scheduled
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
