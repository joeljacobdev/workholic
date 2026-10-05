import AppKit
import Foundation
import UserNotifications
import WorkholicCore

@MainActor
final class AppModel {
    let store: LocalStore
    private var config = CaptureConfig()
    private var timer: Timer?
    private var syncTimer: Timer?
    private var lastSample: MachineSample?
    private(set) var statusLine = "Starting"
    private(set) var syncedLine = "Not signed in. Time stays on this Mac."
    private(set) var reminder = ReminderState()
    private(set) var onCall = false
    private var reminderLine: String?
    private var banners: Set<Banner> = []
    private var ceilingMs: Int64?
    private var syncedCreditedMs: Int64?
    private var plan = BreakPlan.load()
    private var reminderConfig = ReminderConfig()
    private let overlay = BreakOverlay()
    private let editor = BreakEditor()
    private var budgetMode = BudgetStore.mode()
    private var dayPlan = BudgetStore.plan()
    private let dayEditor = DayPlanEditor()
    private var civilDaySeen = civilDay(Date())
    /// A day-start prompt was due while a pause or a call had the screen.
    private var dayPlanDeferred = false
    private var countdownTimer: Timer?
    private var covering = false
    /// When the last countdown second ran. A scheduled pause counts down by the wall clock, sleep included.
    private var lastCountdownAt: Date?
    /// Past the daily limit with overtime pauses on, as of the last sample.
    /// The overtime stretch then replaces the every-few-minutes one.
    private var overtimeInCharge = false
    /// Scheduled entries already shown or skipped, by id, with the civil day they were handled on.
    private var scheduledHandled: [String: String]
    private let pauseOverlay = PauseOverlay()
    private let power = PowerAssertion()
    /// Set while pause mode is on, including a five-minute peek.
    private var pausedSince: Date?
    /// Runs during "Unpause for 5 minutes", then brings the pause cover back.
    private var peekTimer: Timer?
    var onChange: (() -> Void)?

    private enum Banner: Hashable {
        case sessionBudget
    }

    private let defaults = UserDefaults.standard

    /// Break edits made while signed in that the account has not stored yet.
    private static let breaksDirtyKey = "breakPlanDirty"
    /// The account's `updated_at_ms` for the break settings this Mac last stored or adopted.
    private static let breaksSyncedAtKey = "breakPlanSyncedAt"
    private static let scheduledHandledKey = "scheduledHandled"

    init(store: LocalStore) {
        self.store = store
        scheduledHandled = UserDefaults.standard.dictionary(forKey: Self.scheduledHandledKey) as? [String: String] ?? [:]
        reminderConfig.breakAfterMs = plan.breakAfterMs
        editor.onSave = { [weak self] saved in self?.replacePlan(saved) }
        overlay.onSkip = { [weak self] in self?.skipActiveBreak() }
        overlay.onSnooze = { [weak self] in self?.snoozeActiveBreak() }
        pauseOverlay.onUnpause = { [weak self] in self?.unpause() }
        pauseOverlay.onPeek = { [weak self] in self?.peek() }
        dayEditor.onSave = { [weak self] saved in self?.replaceDayPlan(saved) }
        store.setBootId(bootIdentifier())
        store.closeOpenAtLaunch()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
        scheduleSync()
        promptDayPlanIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        syncTimer?.invalidate()
        countdownTimer?.invalidate()
        peekTimer?.invalidate()
        overlay.hide()
        pauseOverlay.hide()
        power.release()
        store.seal()
        onChange?()
    }

    var signedIn: Bool { TokenStore.get("session") != nil }

    var usesTasks: Bool { budgetMode == .dynamic }

    var hasTodayPlan: Bool {
        budgetForDay(dayPlan, today: civilDay(Date())) != nil
    }

    /// Short text beside the menu bar icon. Nil shows the icon alone.
    var statusBadge: String? {
        if isPaused { return "Paused" }
        if covering { return "Break" }
        if banners.contains(.sessionBudget) { return "Session" }
        return nil
    }

    /// How much of today's budget is used, for the menu bar gauge. Nil when no budget is set.
    var usageFraction: Double? {
        let now = Date()
        let range = dayRange(now)
        let local = store.attendedMs(dayStart: range.start, dayEnd: range.end)
        let used: Int64
        let ceiling: Int64
        if budgetMode == .dynamic {
            guard let todayPlan = budgetForDay(dayPlan, today: civilDay(now)) else { return nil }
            used = local
            ceiling = dayBudgetMs(todayPlan.tasks)
        } else {
            guard let ceilingMs else { return nil }
            used = max(syncedCreditedMs ?? 0, local)
            ceiling = ceilingMs
        }
        guard ceiling > 0 else { return used > 0 ? 1 : 0 }
        return Double(used) / Double(ceiling)
    }

    var sessionActive: Bool { reminder.session != nil }

    func promptLogin() {
        let username = NSTextField(string: defaults.string(forKey: "username") ?? "")
        let password = NSSecureTextField(string: "")
        username.placeholderString = "Username"
        password.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        for (field, y) in [(username, 32.0), (password, 0.0)] {
            field.frame = NSRect(x: 0, y: y, width: 280, height: 24)
            box.addSubview(field)
        }
        let alert = NSAlert()
        alert.messageText = "Log in to Workholic"
        alert.informativeText = "No account yet? Create the username with the CLI. Until you log in, recordings stay on this Mac."
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = box
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password.stringValue
        guard !name.isEmpty, secret.count >= 8 else {
            statusLine = "Need a username and a password of at least 8 characters."
            onChange?()
            return
        }
        defaults.set(name, forKey: "username")
        Task { await self.login(username: name, password: secret) }
    }

    func logout() {
        TokenStore.delete("session")
        TokenStore.delete("device")
        defaults.removeObject(forKey: Self.breaksDirtyKey)
        defaults.removeObject(forKey: Self.breaksSyncedAtKey)
        ceilingMs = nil
        syncedCreditedMs = nil
        syncedLine = "Not signed in. Time stays on this Mac."
        statusLine = "Signed out. Local recording continues."
        onChange?()
    }

    func menuLines() -> [String] {
        let now = Date()
        let range = dayRange(now)
        let local = store.attendedMs(dayStart: range.start, dayEnd: range.end)
        let unsent = store.unsentMs(dayStart: range.start, dayEnd: range.end)
        var lines: [String] = []
        if isPaused {
            lines.append(pauseCovering
                ? "Paused. Not counted, and this Mac stays awake."
                : "Unpaused for 5 minutes. The pause comes back.")
        }
        if let reminderLine { lines.append(reminderLine) }
        if budgetMode == .dynamic {
            lines.append("Budget: tasks for today")
            if let todayPlan = budgetForDay(dayPlan, today: civilDay(now)) {
                let ceiling = dayBudgetMs(todayPlan.tasks)
                lines.append("On this Mac: \(formatDuration(local)) of \(formatDuration(ceiling))")
                let shown = todayPlan.tasks.prefix(8)
                for task in shown {
                    lines.append(taskLine(task))
                }
                let extra = todayPlan.tasks.count - shown.count
                if extra > 0 { lines.append("\(extra) more") }
            } else {
                lines.append("On this Mac: \(formatDuration(local))")
                lines.append("Today: set tasks for this day")
            }
        } else {
            lines.append("Budget: fixed daily limit")
            lines.append("On this Mac: \(formatDuration(local))")
            if let ceiling = ceilingMs {
                lines.append("Limit: \(formatDuration(ceiling))")
                let counted = formatDuration(syncedCreditedMs ?? 0)
                lines.append("Synced: \(counted) of \(formatDuration(ceiling))")
            } else if signedIn {
                lines.append("Limit: not set")
                lines.append(syncedLine)
            } else {
                lines.append("Limit: sign in to set one")
                lines.append(syncedLine)
            }
        }
        lines.append("Not uploaded: \(formatDuration(unsent))")
        if !plan.enabled {
            lines.append("Breaks are off.")
        } else if let active = reminder.activeBreak {
            lines.append(active.paused ? "Pause is waiting until the call ends." : "Pause is on the screen.")
        } else if overtimeInCharge {
            let left = max(0, plan.overtimeAfterMs - reminder.overtimeMs)
            let when = left < 60_000 ? "less than a minute" : formatDuration(left)
            lines.append("Past the limit. Next pause in \(when): \(plan.overtime.message)")
        } else if plan.recurringEnabled, let next = plan.upcoming {
            let left = max(0, plan.everyMs - reminder.stretchMs)
            let when = left < 60_000 ? "less than a minute" : formatDuration(left)
            lines.append("Next pause in \(when): \(next.message)")
        }
        if plan.enabled {
            if let snoozed = reminder.snoozed {
                lines.append("Back in under 5 minutes: \(snoozed.message)")
            }
            if let waiting = reminder.extraDue {
                lines.append("Waiting to show: \(waiting.message)")
            }
        }
        if reminder.stretchMs >= 60_000 {
            lines.append("At it for \(formatDuration(reminder.stretchMs))")
        }
        if let session = reminder.session {
            let label = session.notified ? "Session done" : "Session"
            lines.append("\(label): \(formatDuration(session.attendedMs)) of \(formatDuration(session.budgetMs))")
        }
        if onCall {
            let waiting = reminder.heldBreak || reminder.heldSession
            lines.append(waiting ? "On a call. The reminder waits until it ends." : "On a call.")
        }
        lines.append(statusLine)
        lines.append("Version \(appVersion())")
        return lines
    }

    /// What is left under the ceiling for the active mode.
    /// Fixed mode uses the standing limit and the larger of this Mac and the last sync.
    /// Dynamic mode uses today's task total and this Mac only. That total is not the standing limit.
    func restOfTodayMs(now: Date = Date()) -> Int64? {
        guard let ceiling = committedMs(now: now) else { return nil }
        let range = dayRange(now)
        let local = store.attendedMs(dayStart: range.start, dayEnd: range.end)
        let used = budgetMode == .dynamic ? local : max(local, syncedCreditedMs ?? 0)
        let rest = ceiling - used
        guard rest >= 60_000 else { return nil }
        return rest
    }

    func useFixedBudget() {
        guard budgetMode != .fixed else { return }
        budgetMode = .fixed
        BudgetStore.setMode(.fixed)
        dayPlanDeferred = false
        onChange?()
    }

    func useDynamicBudget() {
        budgetMode = .dynamic
        BudgetStore.setMode(.dynamic)
        onChange?()
        promptDayPlanIfNeeded()
    }

    func editDayPlan() {
        let today = civilDay(Date())
        let tasks = budgetForDay(dayPlan, today: today)?.tasks ?? []
        dayEditor.show(day: today, tasks: tasks)
    }

    func replaceDayPlan(_ saved: DayBudget) {
        let today = civilDay(Date())
        guard saved.day == today else {
            statusLine = "That list was for another day, so it was not kept."
            dayPlanDeferred = true
            onChange?()
            return
        }
        dayPlan = saved
        BudgetStore.savePlan(saved)
        dayPlanDeferred = false
        statusLine = "Today is \(formatDuration(dayBudgetMs(saved.tasks)))."
        onChange?()
    }

    func startSession(budgetMs: Int64) {
        guard budgetMs > 0 else { return }
        reminder.session = BudgetSession(budgetMs: budgetMs)
        reminder.heldSession = false
        banners.remove(.sessionBudget)
        if banners.isEmpty { reminderLine = nil }
        onChange?()
    }

    func stopSession() {
        reminder.session = nil
        reminder.heldSession = false
        banners.remove(.sessionBudget)
        if banners.isEmpty { reminderLine = nil }
        onChange?()
    }

    /// The menu opened, so the status-item title can go back to normal.
    func acknowledgeBanner() {
        banners.removeAll()
        reminderLine = nil
    }

    func editBreaks() {
        editor.show(plan: plan)
    }

    func promptLimit() {
        guard signedIn else {
            statusLine = "Log in before setting the limit."
            onChange?()
            return
        }
        let hours = NSTextField(string: "")
        hours.placeholderString = "Hours, such as 7"
        hours.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        let alert = NSAlert()
        alert.messageText = "Daily limit"
        alert.informativeText = "This applies to today, and it stays until you change it. Changing it tomorrow does not rewrite today."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = hours
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = Double(hours.stringValue.trimmingCharacters(in: .whitespaces)) ?? -1
        guard value >= 0, value <= 24 else {
            statusLine = "Enter a limit from 0 to 24 hours."
            onChange?()
            return
        }
        let limitMs = Int64((value * 3_600_000).rounded())
        Task { await self.commitLimit(limitMs) }
    }

    private func commitLimit(_ limitMs: Int64) async {
        guard let session = TokenStore.get("session") else { return }
        do {
            let api = ApiClient(baseURL: ApiOrigin.baseURL)
            try await api.setLimit(sessionToken: session, limitMs: limitMs)
            statusLine = "Limit is \(formatDuration(limitMs)) until you change it."
            await sync()
        } catch {
            statusLine = "Could not set the limit. \(error)"
            onChange?()
        }
    }

    var breaksEnabled: Bool { plan.enabled }

    func skipActiveBreak() {
        guard let active = reminder.activeBreak else { return }
        reminder = skipBreak(state: reminder)
        endBreak()
        switch active.kind {
        case .recurring:
            statusLine = "Break skipped. The next one is \(formatDuration(plan.everyMs)) away."
        case .manual:
            statusLine = "Break ended."
        case .session, .overtime, .scheduled:
            statusLine = "Break skipped."
        }
        onChange?()
    }

    /// "5 more minutes" on an automatic pause. It comes back with the time it had left.
    func snoozeActiveBreak() {
        let (next, held) = snoozeBreak(state: reminder)
        guard held != nil else { return }
        reminder = next
        endBreak()
        statusLine = "Break moved 5 minutes later."
        onChange?()
    }

    var canTakeBreak: Bool { reminder.activeBreak == nil && !pauseCovering }

    /// A pause started from the menu bar. It covers the screen like any other and cannot be put off.
    func takeBreak(minutes: Int) {
        guard canTakeBreak else { return }
        let (next, notices) = beginManualBreak(
            state: reminder,
            message: "Break. Step away from the screen.",
            durationMs: Int64(minutes) * 60_000
        )
        reminder = next
        deliver(notices)
        onChange?()
    }

    var isPaused: Bool { pausedSince != nil }

    /// The pause cover is up: pause mode is on and this is not a five-minute peek.
    private var pauseCovering: Bool { pausedSince != nil && peekTimer == nil }

    /// Away while an agent works: the Mac stays awake, the screen is covered, and nothing counts.
    func pause() {
        guard pausedSince == nil else { return }
        pausedSince = Date()
        power.hold(reason: "Workholic is paused while you are away.")
        coverForPause()
    }

    /// Five minutes of normal use. Time counts again until the cover comes back.
    func peek() {
        guard pausedSince != nil, peekTimer == nil else { return }
        pauseOverlay.hide()
        peekTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.peekTimer = nil
                self?.coverForPause()
            }
        }
        statusLine = "Unpaused for 5 minutes."
        onChange?()
    }

    func unpause() {
        guard pausedSince != nil else { return }
        pausedSince = nil
        peekTimer?.invalidate()
        peekTimer = nil
        pauseOverlay.hide()
        power.release()
        statusLine = "Unpaused."
        tick()
    }

    /// A pause visible when the cover goes up counts as taken: the user is stepping away anyway.
    private func coverForPause() {
        guard let since = pausedSince else { return }
        store.seal()
        if reminder.activeBreak != nil {
            reminder = skipBreak(state: reminder)
            endBreak()
        }
        pauseOverlay.show(since: since)
        onChange?()
    }

    func toggleBreaks() {
        var next = plan
        next.enabled.toggle()
        replacePlan(next)
    }

    /// A local edit. Signed in, it is pushed to the account; signed out, it stays on this Mac.
    func replacePlan(_ saved: BreakPlan) {
        applyPlan(saved)
        if signedIn {
            defaults.set(true, forKey: Self.breaksDirtyKey)
            scheduleSync()
        }
    }

    private func applyPlan(_ next: BreakPlan) {
        plan = next
        plan.save()
        reminderConfig.breakAfterMs = plan.breakAfterMs
        if !plan.enabled {
            reminder.activeBreak = nil
            reminder.heldBreak = false
            reminder.breakNotified = false
            reminder.stretchMs = 0
            endBreak()
        }
        if let waiting = reminder.extraDue {
            let kept = waiting.kind == .session ? plan.sessionDue != nil : plan.overtimeDue != nil
            if !kept { reminder.extraDue = nil }
        }
        if plan.overtimeAfterMs == 0 {
            reminder.overtimeMs = 0
        }
        if let held = reminder.snoozed {
            let kept: Bool
            switch held.kind {
            case .recurring: kept = plan.due != nil
            case .session: kept = plan.sessionDue != nil
            case .overtime: kept = plan.overtimeDue != nil
            case .scheduled: kept = plan.scheduledEntries.contains { $0.id == held.scheduleId }
            case .manual: kept = true
            }
            if !kept {
                reminder.snoozed = nil
                reminder.snoozeLeftMs = 0
                if held.kind == .recurring {
                    reminder.breakNotified = false
                    reminder.stretchMs = 0
                }
            }
        }
        onChange?()
    }

    /// The account copy wins unless this Mac has unsent edits, or the account has never stored one.
    private func syncBreaks(api: ApiClient, session: String) async throws {
        let remote = try await api.breaks(token: session)
        let remoteAt = remote.updatedAtMs ?? 0
        let syncedAt = (defaults.object(forKey: Self.breaksSyncedAtKey) as? NSNumber)?.int64Value ?? 0
        if defaults.bool(forKey: Self.breaksDirtyKey) || remoteAt == 0 {
            let saved = try await api.saveBreaks(sessionToken: session, settings: plan.payload)
            defaults.set(false, forKey: Self.breaksDirtyKey)
            defaults.set(NSNumber(value: saved.updatedAtMs ?? 0), forKey: Self.breaksSyncedAtKey)
        } else if remoteAt > syncedAt {
            applyPlan(plan.adopting(remote))
            defaults.set(NSNumber(value: remoteAt), forKey: Self.breaksSyncedAtKey)
        }
    }

    private var deviceId: String {
        if let existing = defaults.string(forKey: "deviceId") { return existing }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: "deviceId")
        return created
    }

    @objc private func willSleep() {
        store.seal()
        let (next, notices) = reminderStep(
            state: reminder,
            tick: ReminderTick(slept: true, onCall: onCall || pauseCovering, displayAwake: false, dueBreak: plan.due),
            config: reminderConfig
        )
        reminder = next
        deliver(notices)
        onChange?()
    }

    @objc private func didWake() {
        tick()
        promptDayPlanIfNeeded()
    }

    private func tick() {
        noteDay(Date())
        let sample = machineSample()
        let previous = lastSample
        lastSample = sample
        let broke = previous.map { sample.uptimeMs + 2_000 < $0.uptimeMs } ?? false
        let gap = previous.map { max(0, sample.uptimeMs - $0.uptimeMs) } ?? 0
        let isAttending = attending(
            sample: GateSample(
                onConsole: sample.onConsole,
                displayAwake: sample.displayAwake,
                idleMs: sample.idleMs,
                bundleId: sample.bundleId,
                covered: covering || pauseCovering
            ),
            idleThresholdMs: config.idleThresholdMs
        )
        let step = captureStep(
            open: store.open,
            sample: SampleTick(
                wallMs: sample.wallMs,
                uptimeMs: sample.uptimeMs,
                attending: isAttending,
                appKey: sanitizedAppKey(sample.bundleId),
                brokeContinuity: broke
            ),
            config: config
        )
        store.apply(step: step, displayName: sample.displayName, idleMs: sample.idleMs)
        onCall = callInProgress()
        let now = Date()
        let over = overLimit(now: now)
        // Past the limit, the overtime stretch replaces the every-few-minutes one.
        overtimeInCharge = over && plan.overtimeAfterMs > 0
        var stepConfig = reminderConfig
        if overtimeInCharge { stepConfig.breakAfterMs = 0 }
        // The pause cover holds every break the way a call does.
        let (next, notices) = reminderStep(
            state: reminder,
            tick: ReminderTick(
                attendedAddMs: attendedAddMs(step),
                gapMs: gap,
                slept: broke,
                onCall: onCall || pauseCovering,
                displayAwake: sample.displayAwake,
                dueBreak: overtimeInCharge ? nil : plan.due,
                overLimit: over,
                overtimeAfterMs: plan.overtimeAfterMs,
                overtimeBreak: plan.overtimeDue,
                sessionBreak: plan.sessionDue
            ),
            config: stepConfig
        )
        reminder = next
        deliver(notices)
        openScheduled(now: now, displayAwake: sample.displayAwake)
        if dayPlanDeferred { promptDayPlanIfNeeded() }
        onChange?()
    }

    /// Only asked when overtime pauses are on, since it reads today's total.
    private func overLimit(now: Date) -> Bool {
        guard plan.overtimeAfterMs > 0, let ceiling = committedMs(now: now) else { return false }
        let range = dayRange(now)
        let local = store.attendedMs(dayStart: range.start, dayEnd: range.end)
        let used = budgetMode == .dynamic ? local : max(local, syncedCreditedMs ?? 0)
        return used >= ceiling
    }

    /// A scheduled entry whose window is open now shows what is left of it. It does not open over
    /// another pause, while one is snoozed, on a call, under the pause cover, or on a dark screen.
    private func openScheduled(now: Date, displayAwake: Bool) {
        guard reminder.activeBreak == nil, reminder.snoozed == nil, !onCall, !pauseCovering, displayAwake else { return }
        let entries = plan.scheduledEntries
        guard !entries.isEmpty else { return }
        let today = civilDay(now)
        guard let due = dueScheduled(entries, msIntoDay: msIntoDay(now), day: today, handled: scheduledHandled) else { return }
        scheduledHandled = scheduledHandled.filter { $0.value == today }
        scheduledHandled[due.entry.id] = today
        defaults.set(scheduledHandled, forKey: Self.scheduledHandledKey)
        let (next, notices) = beginScheduledBreak(state: reminder, entry: due.entry, remainingMs: due.remainingMs)
        reminder = next
        deliver(notices)
    }

    private func msIntoDay(_ date: Date) -> Int64 {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let seconds = (parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        return Int64(seconds) * 1_000
    }

    private func noteDay(_ now: Date) {
        let today = civilDay(now)
        guard today != civilDaySeen else { return }
        civilDaySeen = today
        guard budgetMode == .dynamic else { return }
        if dayPlan?.day != today {
            dayPlan = nil
            BudgetStore.savePlan(nil)
        }
        promptDayPlanIfNeeded()
    }

    /// Opens the task list when this day has none. Launch, wake, and a new civil day ask.
    /// Closing the window does not ask again until the next one of those.
    private func promptDayPlanIfNeeded() {
        guard budgetMode == .dynamic else {
            dayPlanDeferred = false
            return
        }
        let today = civilDay(Date())
        guard budgetForDay(dayPlan, today: today) == nil else {
            dayPlanDeferred = false
            return
        }
        if covering || onCall || pauseCovering {
            dayPlanDeferred = true
            return
        }
        dayPlanDeferred = false
        guard !dayEditor.isVisible else { return }
        dayEditor.show(day: today, tasks: [])
    }

    private func committedMs(now: Date) -> Int64? {
        committedBudgetMs(mode: budgetMode, fixedMs: ceilingMs, dayPlan: dayPlan, today: civilDay(now))
    }

    private func taskLine(_ task: DayTask) -> String {
        let trimmed = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
        return "\(name): \(formatDuration(min(max(0, task.budgetMs), DayBudgetRule.capMs)))"
    }

    private func scheduleSync() {
        Task { await self.sync() }
    }

    private func login(username: String, password: String) async {
        do {
            let api = ApiClient(baseURL: ApiOrigin.baseURL)
            let session = try await api.login(username: username, password: password)
            TokenStore.set("session", session.sessionToken)
            let enrolled = try await api.enroll(
                sessionToken: session.sessionToken,
                deviceId: deviceId,
                displayName: Host.current().localizedName ?? "Mac"
            )
            TokenStore.set("device", enrolled.deviceToken)
            statusLine = "Signed in as \(session.username)"
            await sync()
        } catch {
            statusLine = "Login failed. \(error)"
            onChange?()
        }
    }

    private func sync() async {
        guard let session = TokenStore.get("session") else { return }
        let api = ApiClient(baseURL: ApiOrigin.baseURL)
        do {
            let settings = try await api.settings(token: session)
            config.idleThresholdMs = settings.idleThresholdMs
            var breakNote: String?
            do {
                try await syncBreaks(api: api, session: session)
            } catch {
                let text = String(describing: error)
                if text.contains("bad_token") || text.contains("401") { throw error }
                breakNote = "Break settings did not sync. \(text)"
            }
            if let device = TokenStore.get("device") {
                try await upload(api: api, deviceToken: device)
            }
            let stats = try await api.stats(token: session)
            if let today = stats.days.first {
                ceilingMs = today.ceilingMs
                syncedCreditedMs = today.creditedMs
                if let ceiling = today.ceilingMs {
                    syncedLine = "Synced today: \(formatDuration(today.creditedMs)) of \(formatDuration(ceiling))"
                } else {
                    syncedLine = "Synced today: \(formatDuration(today.creditedMs)). No ceiling yet."
                }
            }
            statusLine = breakNote ?? "Signed in as \(settings.username)"
        } catch {
            let text = String(describing: error)
            if text.contains("bad_token") || text.contains("401") {
                logout()
                statusLine = "Session rejected. Log in again. Local recording continues."
            } else {
                statusLine = "Not syncing. \(text)"
            }
        }
        onChange?()
    }

    private func upload(api: ApiClient, deviceToken: String) async throws {
        let rows = store.pending(limit: 200)
        if rows.isEmpty { return }
        let intervals: [[String: Any]] = rows.compactMap { row in
            guard let marks = try? JSONSerialization.jsonObject(with: Data(row.marksJson.utf8)) else { return nil }
            return [
                "interval_id": row.intervalId,
                "start_wall_ms": row.startWallMs,
                "end_wall_ms": row.endWallMs,
                "duration_ms": row.durationMs,
                "app_key": row.appKey,
                "app_display_name": row.displayName,
                "source": "os-window",
                "browser_family": NSNull(),
                "attendance": "input",
                "input_marks": marks,
                "media_bout_start_ms": NSNull(),
                "site_unknown": 0,
                "audible": NSNull(),
                "boot_id": row.bootId,
            ]
        }
        if intervals.isEmpty { return }
        let payload: [String: Any] = [
            "batch_id": UUID().uuidString.lowercased(),
            "device_wall_at_send": Int64(Date().timeIntervalSince1970 * 1000),
            "upload_period_ms": 300_000,
            "intervals": intervals,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await api.upload(deviceToken: deviceToken, deviceId: deviceId, body: body)
            store.markUploaded(rows.map(\.intervalId))
        } catch {
            let text = String(describing: error)
            if text.contains("clock_offset") {
                store.markIneligible(rows.map(\.intervalId))
            }
            throw error
        }
    }

    private func deliver(_ notices: [ReminderNotice]) {
        for notice in notices {
            switch notice {
            case .beginBreak(let active):
                if active.kind == .recurring {
                    plan.advance()
                    plan.save()
                }
                present(active)
            case .resumeBreak(let active):
                present(active)
            case .hideBreak:
                overlay.hide()
                covering = false
            case .breakFinished:
                endBreak()
            case .sessionBudget(_, let budgetMs):
                let content = UNMutableNotificationContent()
                content.title = "Session done"
                content.body = "This session reached \(formatDuration(budgetMs)) of attention."
                content.sound = .default
                banners.insert(.sessionBudget)
                if reminderLine == nil { reminderLine = content.body }
                let request = UNNotificationRequest(identifier: "workholic.session", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private func present(_ active: ActiveBreak) {
        // Time behind the cover is not counted, starting now rather than at the next sample.
        if !covering { store.seal() }
        covering = true
        overlay.show(message: active.message, remainingMs: active.remainingMs, snoozable: active.kind != .manual)
        guard countdownTimer == nil else { return }
        lastCountdownAt = Date()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownTick() }
        }
    }

    private func endBreak() {
        overlay.hide()
        covering = false
        countdownTimer?.invalidate()
        countdownTimer = nil
        lastCountdownAt = nil
    }

    private func countdownTick() {
        let awake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        let call = callInProgress()
        onCall = call
        let now = Date()
        var elapsedMs: Int64 = 1_000
        // Scheduled and hand-started pauses end on the clock, so lunch is over on time even after the Mac slept.
        let kind = reminder.activeBreak?.kind
        if kind == .scheduled || kind == .manual, let last = lastCountdownAt {
            elapsedMs = max(0, Int64(now.timeIntervalSince(last) * 1000))
        }
        lastCountdownAt = now
        let (next, effect) = countdownBreak(state: reminder, elapsedMs: elapsedMs, displayAwake: awake, onCall: call)
        reminder = next
        switch effect {
        case .running(let remaining):
            overlay.update(remainingMs: remaining)
        case .finished:
            endBreak()
            onChange?()
        case .hideForCall:
            overlay.hide()
            covering = false
            onChange?()
        case .resume(let active):
            present(active)
            onChange?()
        case nil:
            break
        }
    }

    private func dayRange(_ date: Date) -> (start: Int64, end: Int64) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }
}

func formatDuration(_ ms: Int64) -> String {
    let minutes = max(0, ms) / 60_000
    let hours = minutes / 60
    let rest = minutes % 60
    if hours > 0 && rest == 0 { return "\(hours)h" }
    if hours > 0 { return "\(hours)h \(rest)m" }
    return "\(rest)m"
}
