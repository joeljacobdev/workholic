import Foundation

/// How long someone can look at the screen before the next pause,
/// and how long they have to step away before that stretch starts over.
public struct ReminderConfig: Sendable, Equatable {
    public var breakAfterMs: Int64
    public var awayResetMs: Int64

    public init(breakAfterMs: Int64 = 15 * 60_000, awayResetMs: Int64 = 5 * 60_000) {
        self.breakAfterMs = breakAfterMs
        self.awayResetMs = awayResetMs
    }
}

public enum SessionBudget {
    public static let shortMs: Int64 = 25 * 60_000
    public static let longMs: Int64 = 50 * 60_000
}

public struct BudgetSession: Sendable, Equatable {
    public var budgetMs: Int64
    public var attendedMs: Int64
    public var notified: Bool

    public init(budgetMs: Int64, attendedMs: Int64 = 0, notified: Bool = false) {
        self.budgetMs = budgetMs
        self.attendedMs = attendedMs
        self.notified = notified
    }
}

/// The pause to open when the work interval is reached. The words are the user's.
public struct DueBreak: Sendable, Equatable {
    public var message: String
    public var durationMs: Int64
    /// A rest is time away from the screen. The screen turning off completes it.
    public var rest: Bool

    public init(message: String, durationMs: Int64, rest: Bool) {
        self.message = message
        self.durationMs = durationMs
        self.rest = rest
    }
}

public struct ActiveBreak: Sendable, Equatable {
    public var message: String
    public var remainingMs: Int64
    public var durationMs: Int64
    public var rest: Bool
    public var paused: Bool

    public init(message: String, remainingMs: Int64, durationMs: Int64, rest: Bool, paused: Bool = false) {
        self.message = message
        self.remainingMs = remainingMs
        self.durationMs = durationMs
        self.rest = rest
        self.paused = paused
    }
}

public struct ReminderState: Sendable, Equatable {
    public var stretchMs: Int64
    public var awayMs: Int64
    public var breakNotified: Bool
    public var session: BudgetSession?
    /// The work interval was reached during a call, or an activity break is waiting for the screen.
    public var heldBreak: Bool
    /// A session budget was reached during a call. Deliver it once the call ends.
    public var heldSession: Bool
    public var activeBreak: ActiveBreak?

    public init(
        stretchMs: Int64 = 0,
        awayMs: Int64 = 0,
        breakNotified: Bool = false,
        session: BudgetSession? = nil,
        heldBreak: Bool = false,
        heldSession: Bool = false,
        activeBreak: ActiveBreak? = nil
    ) {
        self.stretchMs = stretchMs
        self.awayMs = awayMs
        self.breakNotified = breakNotified
        self.session = session
        self.heldBreak = heldBreak
        self.heldSession = heldSession
        self.activeBreak = activeBreak
    }
}

public enum ReminderNotice: Sendable, Equatable {
    case beginBreak(ActiveBreak)
    case resumeBreak(ActiveBreak)
    case hideBreak
    case breakFinished
    case sessionBudget(attendedMs: Int64, budgetMs: Int64)
}

public struct ReminderTick: Sendable, Equatable {
    /// Attended milliseconds `captureStep` just counted. Zero when this sample added none.
    public var attendedAddMs: Int64
    /// Uptime since the previous sample. Counted as away only when no attended time was added.
    public var gapMs: Int64
    public var slept: Bool
    public var onCall: Bool
    public var displayAwake: Bool
    /// The next pause in the user's list. Nil when they have not defined one.
    public var dueBreak: DueBreak?

    public init(
        attendedAddMs: Int64 = 0,
        gapMs: Int64 = 0,
        slept: Bool = false,
        onCall: Bool = false,
        displayAwake: Bool = true,
        dueBreak: DueBreak? = nil
    ) {
        self.attendedAddMs = attendedAddMs
        self.gapMs = gapMs
        self.slept = slept
        self.onCall = onCall
        self.displayAwake = displayAwake
        self.dueBreak = dueBreak
    }
}

public enum CountdownEffect: Sendable, Equatable {
    case running(remainingMs: Int64)
    case finished
    case hideForCall
    case resume(ActiveBreak)
}

/// Milliseconds of attention a capture step actually added.
/// A new slice, a seal, and a gap contribute nothing.
public func attendedAddMs(_ step: CaptureStep) -> Int64 {
    switch step {
    case .extend(let addMs):
        return max(0, addMs)
    case .fillSeal(let fillMs, _, _, _):
        return max(0, fillMs)
    case .hold, .start, .seal, .sealAndStart:
        return 0
    }
}

/// Advance the work stretch and the budget session by one sample.
///
/// The stretch grows only by attended time. It does not grow during a pause.
/// Sleep, a dark screen, or a real gap of `awayResetMs` clears it: for a rest,
/// that already is the pause. A due pause waits while a call is on, then covers
/// the screen. An activity pause is not completed by the screen turning off.
public func reminderStep(state: ReminderState, tick: ReminderTick, config: ReminderConfig) -> (ReminderState, [ReminderNotice]) {
    var state = state
    var notices: [ReminderNotice] = []
    recordSession(&state, tick: tick, notices: &notices)

    if state.activeBreak != nil {
        notices.append(contentsOf: trackActiveBreak(&state, tick: tick))
        return (state, notices)
    }

    if tick.slept || !tick.displayAwake {
        state.stretchMs = 0
        state.awayMs = 0
        state.breakNotified = false
        if state.heldBreak, tick.dueBreak?.rest != false {
            state.heldBreak = false
        } else if state.heldBreak {
            state.breakNotified = true
        }
        return (state, notices)
    }

    if tick.attendedAddMs > 0 {
        state.awayMs = 0
        if !state.heldBreak {
            state.stretchMs += tick.attendedAddMs
        }
        if !state.breakNotified && !state.heldBreak && config.breakAfterMs > 0 && state.stretchMs >= config.breakAfterMs {
            notices.append(contentsOf: openBreak(&state, tick: tick))
        }
    } else if tick.gapMs > 0 {
        state.awayMs += tick.gapMs
        if config.awayResetMs > 0 && state.awayMs >= config.awayResetMs {
            state.stretchMs = 0
            state.awayMs = 0
            state.breakNotified = false
            state.heldBreak = false
        }
    }

    if state.heldBreak && !tick.onCall && state.activeBreak == nil {
        notices.append(contentsOf: openBreak(&state, tick: tick))
    }

    return (state, notices)
}

/// Move a visible pause forward. The caller owns the one-second clock.
/// A rest ends immediately when the display is asleep. A call hides the pause
/// and keeps whatever time is left.
public func countdownBreak(
    state: ReminderState,
    elapsedMs: Int64,
    displayAwake: Bool,
    onCall: Bool
) -> (ReminderState, CountdownEffect?) {
    guard var active = state.activeBreak else { return (state, nil) }
    var state = state
    if onCall {
        if active.paused { return (state, nil) }
        active.paused = true
        state.activeBreak = active
        return (state, .hideForCall)
    }
    if active.paused {
        active.paused = false
        state.activeBreak = active
        if active.rest && !displayAwake { return finishBreak(state) }
        return (state, .resume(active))
    }
    if active.rest && !displayAwake { return finishBreak(state) }
    let remaining = active.remainingMs - max(0, elapsedMs)
    if remaining <= 0 { return finishBreak(state) }
    active.remainingMs = remaining
    state.activeBreak = active
    return (state, .running(remainingMs: remaining))
}

private func recordSession(_ state: inout ReminderState, tick: ReminderTick, notices: inout [ReminderNotice]) {
    if tick.attendedAddMs > 0, var session = state.session {
        session.attendedMs += tick.attendedAddMs
        if !session.notified && session.budgetMs > 0 && session.attendedMs >= session.budgetMs {
            session.notified = true
            if tick.onCall {
                state.heldSession = true
            } else {
                notices.append(.sessionBudget(attendedMs: session.attendedMs, budgetMs: session.budgetMs))
            }
        }
        state.session = session
    }
    if !tick.onCall, state.heldSession, let session = state.session {
        notices.append(.sessionBudget(attendedMs: session.attendedMs, budgetMs: session.budgetMs))
        state.heldSession = false
    } else if !tick.onCall, state.heldSession {
        state.heldSession = false
    }
}

private func trackActiveBreak(_ state: inout ReminderState, tick: ReminderTick) -> [ReminderNotice] {
    guard var active = state.activeBreak else { return [] }
    if active.rest && (tick.slept || !tick.displayAwake) {
        finishBreakState(&state)
        return [.breakFinished]
    }
    if tick.onCall {
        if active.paused { return [] }
        active.paused = true
        state.activeBreak = active
        return [.hideBreak]
    }
    if active.paused {
        active.paused = false
        state.activeBreak = active
        return [.resumeBreak(active)]
    }
    return []
}

private func openBreak(_ state: inout ReminderState, tick: ReminderTick) -> [ReminderNotice] {
    guard let due = tick.dueBreak, due.durationMs > 0 else {
        state.heldBreak = false
        state.breakNotified = false
        return []
    }
    if tick.onCall || (!tick.displayAwake && !due.rest) {
        state.heldBreak = true
        state.breakNotified = true
        return []
    }
    if !tick.displayAwake && due.rest {
        state.stretchMs = 0
        state.awayMs = 0
        state.heldBreak = false
        state.breakNotified = false
        return []
    }
    let active = ActiveBreak(
        message: due.message,
        remainingMs: due.durationMs,
        durationMs: due.durationMs,
        rest: due.rest
    )
    state.activeBreak = active
    state.heldBreak = false
    state.breakNotified = true
    return [.beginBreak(active)]
}

private func finishBreak(_ state: ReminderState) -> (ReminderState, CountdownEffect) {
    var state = state
    finishBreakState(&state)
    return (state, .finished)
}

private func finishBreakState(_ state: inout ReminderState) {
    state.activeBreak = nil
    state.stretchMs = 0
    state.awayMs = 0
    state.heldBreak = false
    state.breakNotified = false
}
