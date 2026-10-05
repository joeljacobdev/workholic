import Foundation

/// A pause at a local clock time, such as lunch. It covers the window from its start for its length,
/// once per civil day. A window does not run past midnight.
public struct ScheduledBreak: Sendable, Equatable {
    public var id: String
    /// Minutes after local midnight.
    public var startMinute: Int
    public var durationMs: Int64
    public var message: String

    public init(id: String, startMinute: Int, durationMs: Int64, message: String) {
        self.id = id
        self.startMinute = startMinute
        self.durationMs = durationMs
        self.message = message
    }
}

/// Reads 24-hour `HH:MM`, the shape the account stores. Anything else is nil.
public func clockMinute(_ text: String) -> Int? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
          parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
          let hour = Int(parts[0]), let minute = Int(parts[1]),
          hour < 24, minute < 60 else { return nil }
    return hour * 60 + minute
}

/// The entry whose window holds `msIntoDay` and that has not been handled on `day`.
/// When windows overlap, the earliest start wins. The time left is what remains of its window,
/// so waking the Mac halfway through lunch shows only the second half.
public func dueScheduled(
    _ entries: [ScheduledBreak],
    msIntoDay: Int64,
    day: String,
    handled: [String: String]
) -> (entry: ScheduledBreak, remainingMs: Int64)? {
    var best: (entry: ScheduledBreak, remainingMs: Int64)?
    for entry in entries where handled[entry.id] != day && entry.durationMs > 0 {
        let start = Int64(entry.startMinute) * 60_000
        let end = start + entry.durationMs
        guard msIntoDay >= start, msIntoDay < end else { continue }
        if let current = best, current.entry.startMinute <= entry.startMinute { continue }
        best = (entry, end - msIntoDay)
    }
    return best
}

/// Opens a scheduled pause unless another pause is already up. A dark screen does not end it.
public func beginScheduledBreak(state: ReminderState, entry: ScheduledBreak, remainingMs: Int64) -> (ReminderState, [ReminderNotice]) {
    guard state.activeBreak == nil, remainingMs > 0 else { return (state, []) }
    var state = state
    let active = ActiveBreak(
        message: entry.message,
        remainingMs: remainingMs,
        durationMs: entry.durationMs,
        rest: false,
        kind: .scheduled,
        scheduleId: entry.id
    )
    state.activeBreak = active
    return (state, [.beginBreak(active)])
}

/// "5 more minutes": takes an automatic pause down and brings it back with the time it had left.
/// Unlike Skip, it does not count as a pause taken. A pause the user started cannot be put off.
public func snoozeBreak(state: ReminderState) -> (ReminderState, ActiveBreak?) {
    guard let active = state.activeBreak, active.kind != .manual else { return (state, nil) }
    var state = state
    state.activeBreak = nil
    var held = active
    held.paused = false
    state.snoozed = held
    state.snoozeLeftMs = BreakTiming.snoozeMs
    return (state, held)
}
