import Foundation

/// This Mac's daily scheduled shutdown, set per device in the account.
/// It shuts down after `after`, once past today's limit if `afterLimit`, and not before the time
/// the `command` script prints, if one is named: whichever comes last.
public struct ShutdownRule: Sendable, Equatable, Codable {
    /// 24-hour local `HH:MM`.
    public var after: String
    public var afterLimit: Bool
    /// A script's file name in this Mac's commands folder. Only a name: the account cannot send code.
    /// It runs only once the other parts hold, so it is not asked all day.
    public var command: String?

    public init(after: String, afterLimit: Bool = false, command: String? = nil) {
        self.after = after
        self.afterLimit = afterLimit
        self.command = command
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        after = try values.decode(String.self, forKey: .after)
        afterLimit = try values.decodeIfPresent(Bool.self, forKey: .afterLimit) ?? false
        command = try values.decodeIfPresent(String.self, forKey: .command)
    }

    private enum CodingKeys: String, CodingKey {
        case after
        case afterLimit = "after_limit"
        case command
    }
}

/// Checked again on the Mac, whatever the server said. A rule that fails is no rule.
public func validShutdownRule(_ rule: ShutdownRule) -> Bool {
    guard clockMinute(rule.after) != nil else { return false }
    if let command = rule.command, !isScriptName(command) { return false }
    return true
}

/// Letters, digits, `.`, `_`, `-`; not starting with a dot, no `..`, at most 100. Never a path.
public func isScriptName(_ name: String) -> Bool {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return (1...100).contains(name.count) && name.allSatisfy(allowed.contains)
        && !name.hasPrefix(".") && !name.contains("..")
}

/// The time and limit parts of the rule. The command is asked only after these hold.
public func shutdownGateOpen(_ rule: ShutdownRule, msIntoDay: Int64, overLimit: Bool) -> Bool {
    guard let minute = clockMinute(rule.after), msIntoDay >= Int64(minute) * 60_000 else { return false }
    if rule.afterLimit && !overLimit { return false }
    return true
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

public func shutdownStep(_ watch: ShutdownWatch, day: String, gateOpen: Bool) -> (ShutdownWatch, ShutdownStatus) {
    var next = watch
    if watch.doneDay == day { return (next, .done) }
    guard gateOpen else {
        next.armedDay = day
        return (next, .waiting)
    }
    return (next, watch.armedDay == day ? .ready : .missed)
}
