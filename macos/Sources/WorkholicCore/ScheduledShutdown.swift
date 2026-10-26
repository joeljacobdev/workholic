import Foundation

/// This Mac's daily scheduled shutdown, set per device in the account.
/// It comes due after a clock time, or a delay after today's limit is crossed. If a `command` script
/// is named, the Mac also waits for the time it prints: whichever is later wins.
public struct ShutdownRule: Sendable, Equatable, Codable {
    public enum When: String, Sendable, Codable {
        case time
        case limit
    }

    public var when: When
    /// 24-hour local `HH:MM`, for `.time`.
    public var after: String?
    /// Wall-clock minutes after the limit is crossed, for `.limit`.
    public var delayMinutes: Int
    /// A script's file name in this Mac's commands folder. Only a name: the account cannot send code.
    /// It runs only once the time or limit has come, so it is not asked all day.
    public var command: String?

    public init(when: When, after: String? = nil, delayMinutes: Int = 0, command: String? = nil) {
        self.when = when
        self.after = after
        self.delayMinutes = delayMinutes
        self.command = command
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // The first version had no `when` and was always a clock time.
        when = try values.decodeIfPresent(When.self, forKey: .when) ?? .time
        after = try values.decodeIfPresent(String.self, forKey: .after)
        delayMinutes = try values.decodeIfPresent(Int.self, forKey: .delayMinutes) ?? 0
        command = try values.decodeIfPresent(String.self, forKey: .command)
    }

    private enum CodingKeys: String, CodingKey {
        case when
        case after
        case delayMinutes = "delay_minutes"
        case command
    }
}

/// Checked again on the Mac, whatever the server said. A rule that fails is no rule.
public func validShutdownRule(_ rule: ShutdownRule) -> Bool {
    switch rule.when {
    case .time:
        guard let after = rule.after, clockMinute(after) != nil else { return false }
    case .limit:
        guard (0...720).contains(rule.delayMinutes) else { return false }
    }
    if let command = rule.command, !isScriptName(command) { return false }
    return true
}

/// When today's limit was crossed, as seen while Workholic watched. A crossing is recorded only
/// after the total was seen under the limit earlier that day, so a Mac started already over
/// has none, and its delay cannot count from the launch.
public struct LimitCrossing: Sendable, Equatable {
    public var underDay: String?
    public var crossedAt: Date?

    public init(underDay: String? = nil, crossedAt: Date? = nil) {
        self.underDay = underDay
        self.crossedAt = crossedAt
    }
}

public func limitCrossingStep(_ crossing: LimitCrossing, day: String, over: Bool, now: Date) -> LimitCrossing {
    var next = crossing
    if !over {
        next.underDay = day
        next.crossedAt = nil
    } else if next.underDay != day {
        // Over without being seen under today, or a crossing from another day: none.
        next.crossedAt = nil
    } else if next.crossedAt == nil {
        next.crossedAt = now
    }
    return next
}

/// Letters, digits, `.`, `_`, `-`; not starting with a dot, no `..`, at most 100. Never a path.
public func isScriptName(_ name: String) -> Bool {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return (1...100).contains(name.count) && name.allSatisfy(allowed.contains)
        && !name.hasPrefix(".") && !name.contains("..")
}

/// Whether the set time, or the limit and its delay, has come. The script is asked only after this.
/// Over the limit with no crossing seen today counts as open, which the watch then calls missed.
public func shutdownGateOpen(_ rule: ShutdownRule, msIntoDay: Int64, overLimit: Bool, crossedAt: Date?, now: Date) -> Bool {
    switch rule.when {
    case .time:
        guard let after = rule.after, let minute = clockMinute(after) else { return false }
        return msIntoDay >= Int64(minute) * 60_000
    case .limit:
        guard overLimit else { return false }
        guard let crossedAt else { return true }
        return now >= crossedAt.addingTimeInterval(TimeInterval(rule.delayMinutes * 60))
    }
}

/// What the command printed: ISO 8601 with a zone (`2026-10-17T21:30:00-07:00`, `...Z`),
/// or `HH:MM` on today's date in this Mac's time zone. Anything else is nil.
public func readShutdownTime(_ output: String, now: Date, calendar: Calendar = .current) -> Date? {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if let minute = clockMinute(text) {
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: now)
    }
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text)
}

/// Keeps a scheduled shutdown to the moment it comes due while Workholic watches.
/// The gate has to be seen shut earlier the same day (armed), so a Mac started after the
/// time does not shut down. Once warned, the day is done: a cancel or a refused shutdown
/// is not tried again until tomorrow.
public struct ShutdownWatch: Sendable, Equatable {
    public var armedDay: String?
    public var doneDay: String?

    public init(armedDay: String? = nil, doneDay: String? = nil) {
        self.armedDay = armedDay
        self.doneDay = doneDay
    }
}

public enum ShutdownStatus: Sendable, Equatable {
    case waiting
    /// The gate is open and it was seen shut today. Ask the command, if any, then warn.
    case ready
    /// The gate was already open the first time Workholic looked today.
    case missed
    case done
}

/// A rule that changes has to be seen shut again before it can fire, so one set to a time already
/// past today waits for tomorrow instead of warning at once. A day already done stays done.
public func shutdownRuleChanged(_ watch: ShutdownWatch) -> ShutdownWatch {
    ShutdownWatch(armedDay: nil, doneDay: watch.doneDay)
}

public func shutdownStep(_ watch: ShutdownWatch, day: String, gateOpen: Bool) -> (ShutdownWatch, ShutdownStatus) {
    var next = watch
    if watch.doneDay == day { return (next, .done) }
    guard gateOpen else {
        next.armedDay = day
        return (next, .waiting)
    }
    return (next, watch.armedDay == day ? .ready : .missed)
}
