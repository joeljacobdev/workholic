import Foundation

/// The account's plan for the day, the same on every Mac. Either a daily limit, or time blocks
/// (one set for weekdays, one for weekends, which today can replace) with the screen covered
/// outside them. Times are minutes past local midnight on this Mac's clock; a block is `[start, end]`.
///
/// The shutdown is one for every Mac (`scope` `.all`), or each Mac's own entry under `each`
/// (`.each`), with the same four fields either way. A plan from before `scope` reads as `.all`.
public struct AccountPlan: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable { case limit, planner }
    public enum Outside: String, Sendable, Codable { case pause, none }
    public enum Shutdown: String, Sendable, Codable {
        case off, time, limit
        case lastBlock = "last_block"
    }
    public enum Scope: String, Sendable, Codable { case all, each }

    /// One Mac's own way of shutting down, under `each`.
    public struct MacShutdown: Sendable, Equatable, Codable {
        public var shutdown: Shutdown
        public var at: Int?
        public var delayMinutes: Int
        public var command: String?

        public init(shutdown: Shutdown = .off, at: Int? = nil, delayMinutes: Int = 0, command: String? = nil) {
            self.shutdown = shutdown
            self.at = at
            self.delayMinutes = delayMinutes
            self.command = command
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            shutdown = try values.decodeIfPresent(Shutdown.self, forKey: .shutdown) ?? .off
            at = try values.decodeIfPresent(Int.self, forKey: .at)
            delayMinutes = try values.decodeIfPresent(Int.self, forKey: .delayMinutes) ?? 0
            command = try values.decodeIfPresent(String.self, forKey: .command)
        }

        private enum CodingKeys: String, CodingKey {
            case shutdown, at, command
            case delayMinutes = "delay_minutes"
        }
    }

    public struct Today: Sendable, Equatable, Codable {
        public var day: String
        public var blocks: [[Int]]

        public init(day: String, blocks: [[Int]]) {
            self.day = day
            self.blocks = blocks
        }
    }

    public var mode: Mode
    public var weekdays: [[Int]]
    public var weekends: [[Int]]
    public var today: Today?
    public var outside: Outside
    public var shutdown: Shutdown
    public var at: Int?
    public var delayMinutes: Int
    public var command: String?
    public var scope: Scope
    public var each: [String: MacShutdown]

    public init(
        mode: Mode = .limit, weekdays: [[Int]] = [], weekends: [[Int]] = [], today: Today? = nil,
        outside: Outside = .pause, shutdown: Shutdown = .off, at: Int? = nil, delayMinutes: Int = 0, command: String? = nil,
        scope: Scope = .all, each: [String: MacShutdown] = [:]
    ) {
        self.mode = mode
        self.weekdays = weekdays
        self.weekends = weekends
        self.today = today
        self.outside = outside
        self.shutdown = shutdown
        self.at = at
        self.delayMinutes = delayMinutes
        self.command = command
        self.scope = scope
        self.each = each
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(Mode.self, forKey: .mode)
        weekdays = try values.decodeIfPresent([[Int]].self, forKey: .weekdays) ?? []
        weekends = try values.decodeIfPresent([[Int]].self, forKey: .weekends) ?? []
        today = try values.decodeIfPresent(Today.self, forKey: .today)
        outside = try values.decodeIfPresent(Outside.self, forKey: .outside) ?? .pause
        shutdown = try values.decodeIfPresent(Shutdown.self, forKey: .shutdown) ?? .off
        at = try values.decodeIfPresent(Int.self, forKey: .at)
        delayMinutes = try values.decodeIfPresent(Int.self, forKey: .delayMinutes) ?? 0
        command = try values.decodeIfPresent(String.self, forKey: .command)
        scope = try values.decodeIfPresent(Scope.self, forKey: .scope) ?? .all
        each = try values.decodeIfPresent([String: MacShutdown].self, forKey: .each) ?? [:]
    }

    /// How this Mac shuts down: the plan's own way, or its entry, or not at all.
    public func shutdownFor(deviceId: String?) -> MacShutdown {
        guard scope == .each else { return MacShutdown(shutdown: shutdown, at: at, delayMinutes: delayMinutes, command: command) }
        guard let deviceId, let own = each[deviceId] else { return MacShutdown() }
        return own
    }

    private enum CodingKeys: String, CodingKey {
        case mode, weekdays, weekends, today, outside, shutdown, at, command, scope, each
        case delayMinutes = "delay_minutes"
    }
}

private let dayMinutes = 24 * 60

private func validBlocks(_ blocks: [[Int]]) -> Bool {
    guard blocks.count <= 8 else { return false }
    var previousEnd = 0
    for block in blocks {
        guard block.count == 2, block[0] >= previousEnd, block[0] < block[1], block[1] <= dayMinutes else { return false }
        previousEnd = block[1]
    }
    return true
}

/// Checked again on the Mac, whatever the server said. A plan that fails is no plan.
public func validAccountPlan(_ plan: AccountPlan) -> Bool {
    guard validBlocks(plan.weekdays), validBlocks(plan.weekends) else { return false }
    if let today = plan.today, !validBlocks(today.blocks) { return false }
    guard validShutdown(plan.shutdownFor(deviceId: nil), mode: plan.mode) else { return false }
    return plan.each.values.allSatisfy { validShutdown($0, mode: plan.mode) }
}

private func validShutdown(_ own: AccountPlan.MacShutdown, mode: AccountPlan.Mode) -> Bool {
    switch own.shutdown {
    case .off: break
    case .time:
        guard let at = own.at, (0..<dayMinutes).contains(at) else { return false }
    case .limit:
        guard mode == .limit, (0...720).contains(own.delayMinutes) else { return false }
    case .lastBlock:
        guard mode == .planner else { return false }
    }
    if let command = own.command, !isScriptName(command) { return false }
    return true
}

/// The blocks that hold on `day`: today's own, or the usual set for a weekday or a weekend.
public func blocksFor(_ plan: AccountPlan, day: String, weekend: Bool) -> [[Int]] {
    if let today = plan.today, today.day == day { return today.blocks }
    return weekend ? plan.weekends : plan.weekdays
}

public func minuteText(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
}

/// The plan's shutdown for `deviceId` on a day with these blocks, as the rule the shutdown watch keeps.
/// The last block ending at midnight shuts down at 23:59. Nil when nothing is due that day.
public func planShutdownRule(_ plan: AccountPlan, blocks: [[Int]], deviceId: String? = nil) -> ShutdownRule? {
    let own = plan.shutdownFor(deviceId: deviceId)
    switch own.shutdown {
    case .off:
        return nil
    case .time:
        guard let at = own.at else { return nil }
        return ShutdownRule(when: .time, after: minuteText(at), command: own.command)
    case .limit:
        return ShutdownRule(when: .limit, delayMinutes: own.delayMinutes, command: own.command)
    case .lastBlock:
        guard let last = blocks.last else { return nil }
        return ShutdownRule(when: .time, after: minuteText(min(last[1], dayMinutes - 1)), command: own.command)
    }
}

public func inBlock(_ blocks: [[Int]], minute: Int) -> Bool {
    blocks.contains { $0[0] <= minute && minute < $0[1] }
}

/// When the next block starts today, or nil when none is left.
public func nextBlockStart(_ blocks: [[Int]], minute: Int) -> Int? {
    blocks.first { $0[0] > minute }?[0]
}

/// Leave to use the Mac outside the blocks, on one day, until a minute of it.
public struct PlannerPass: Sendable, Equatable, Codable {
    public var day: String
    public var untilMinute: Int

    public init(day: String, untilMinute: Int) {
        self.day = day
        self.untilMinute = untilMinute
    }
}

/// "15 more minutes": that long from now, at most to midnight.
public func morePass(day: String, minute: Int, minutes: Int = 15) -> PlannerPass {
    PlannerPass(day: day, untilMinute: min(minute + minutes, dayMinutes))
}

/// Unlocked with the password: until the next block starts, or the end of the day.
public func unlockPass(_ blocks: [[Int]], day: String, minute: Int) -> PlannerPass {
    PlannerPass(day: day, untilMinute: nextBlockStart(blocks, minute: minute) ?? dayMinutes)
}

/// The screen is covered: planner mode, set to pause outside the blocks, outside every block,
/// and no pass for this day still running.
public func plannerCovers(_ plan: AccountPlan, blocks: [[Int]], day: String, minute: Int, pass: PlannerPass? = nil) -> Bool {
    guard plan.mode == .planner, plan.outside == .pause, !inBlock(blocks, minute: minute) else { return false }
    if let pass, pass.day == day, minute < pass.untilMinute { return false }
    return true
}

/// Minutes planned for a day with these blocks.
public func plannedMinutes(_ blocks: [[Int]]) -> Int {
    blocks.reduce(0) { $0 + $1[1] - $1[0] }
}
