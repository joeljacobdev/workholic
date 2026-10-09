import AppKit
import LocalAuthentication
import Foundation
import WorkholicCore

@MainActor
final class AppModel {
    let store: LocalStore
    private var config = CaptureConfig()
    private var timer: Timer?
    private var syncTimer: Timer?
    /// Asks the account every few seconds whether settings changed elsewhere.
    private var settingsTimer: Timer?
    /// A break push or pull is in flight, so a second one does not race it.
    private var breaksBusy = false
    private var lastSample: MachineSample?
    /// Something that needs the user: a failed login or sync. Nil when all is well.
    private(set) var problem: String?
    private(set) var reminder = ReminderState()
    private(set) var onCall = false
    private var ceilingMs: Int64?
    private var syncedCreditedMs: Int64?
    private var plan = BreakPlan.load()
    private var reminderConfig = ReminderConfig()
    private let overlay = BreakOverlay()
    private let editor = BreakEditor()
    private var budgetMode = BudgetStore.mode()
    private var dayPlan = BudgetStore.plan()
    private let dayEditor = DayPlanEditor()
    private let appWindow = AppWindow()
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
    /// Shared by the break and pause covers, which never show together.
    private let backlight = Backlight()
    /// The password prompt for a locked pause is up.
    private var unlocking = false
    private static let pauseLocksKey = "pauseNeedsPassword"
    private let power = PowerAssertion()
    /// Keeps the display on while a break covers it, so the break is a dark screen, not a sleeping one.
    private let breakPower = PowerAssertion()
    /// Set while pause mode is on, including a five-minute peek.
    private var pausedSince: Date?
    /// Runs during "Unpause for 5 minutes", then brings the pause cover back.
    private var peekTimer: Timer?
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    /// Break edits made while signed in that the account has not stored yet.
    private static let breaksDirtyKey = "breakPlanDirty"
    /// The account's `updated_at_ms` for the break settings this Mac last stored or adopted.
    private static let breaksSyncedAtKey = "breakPlanSyncedAt"
    /// When this Mac's unsent break edit was made, to compare with an edit made elsewhere.
    private static let breaksEditedAtKey = "breakPlanEditedAt"
    private static let settingsEverySeconds: TimeInterval = 10
    private static let scheduledHandledKey = "scheduledHandled"

    init(store: LocalStore) {
        self.store = store
        scheduledHandled = UserDefaults.standard.dictionary(forKey: Self.scheduledHandledKey) as? [String: String] ?? [:]
        reminderConfig.breakAfterMs = plan.breakAfterMs
        editor.onSave = { [weak self] saved in self?.replacePlan(saved) }
        overlay.onSkip = { [weak self] in self?.skipActiveBreak() }
        overlay.onSnooze = { [weak self] in self?.snoozeActiveBreak() }
        pauseOverlay.onUnpause = { [weak self] in self?.unlock(then: .unpause) }
        pauseOverlay.onPeek = { [weak self] in self?.unlock(then: .peek) }
        backlight.restoreAfterCrash()
        overlay.backlight = backlight
        pauseOverlay.backlight = backlight
        dayEditor.onSave = { [weak self] saved in self?.replaceDayPlan(saved) }
        appWindow.onRequest = { [weak self] request in self?.handle(request) }
        store.setBootId(bootIdentifier())
        store.closeOpenAtLaunch()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
        settingsTimer = Timer.scheduledTimer(withTimeInterval: Self.settingsEverySeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePull() }
        }
        scheduleSync()
        promptDayPlanIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        syncTimer?.invalidate()
        settingsTimer?.invalidate()
        countdownTimer?.invalidate()
        peekTimer?.invalidate()
        overlay.hide()
        pauseOverlay.hide()
        power.release()
        breakPower.release()
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
        return nil
    }

    /// Today's looking and the ceiling it counts against.
    /// Fixed mode counts every device: the account's last merge, or this Mac if it is ahead.
    /// Dynamic mode uses today's task total and this Mac only. That total is not the standing limit.
    func todayUsage(now: Date = Date()) -> (usedMs: Int64, ceilingMs: Int64?) {
        let range = dayRange(now)
        let local = store.attendedMs(dayStart: range.start, dayEnd: range.end)
        if budgetMode == .dynamic {
            return (local, budgetForDay(dayPlan, today: civilDay(now)).map { dayBudgetMs($0.tasks) })
        }
        return (max(syncedCreditedMs ?? 0, local), ceilingMs)
    }

    /// How much of today's budget is used, for the menu bar gauge. Nil when no budget is set.
    var usageFraction: Double? {
        let usage = todayUsage()
        guard let ceiling = usage.ceilingMs else { return nil }
        guard ceiling > 0 else { return usage.usedMs > 0 ? 1 : 0 }
        return Double(usage.usedMs) / Double(ceiling)
    }

    /// Logs in, then runs `then` once this Mac is enrolled. Cancelling skips it.
    func promptLogin(then: (() -> Void)? = nil) {
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
            problem = "Need a username and a password of at least 8 characters."
            onChange?()
            return
        }
        defaults.set(name, forKey: "username")
        Task {
            await self.login(username: name, password: secret)
            if self.signedIn { then?() }
        }
    }

    func logout() {
        TokenStore.delete("session")
        TokenStore.delete("device")
        defaults.removeObject(forKey: Self.breaksDirtyKey)
        defaults.removeObject(forKey: Self.breaksSyncedAtKey)
        defaults.removeObject(forKey: Self.breaksEditedAtKey)
        ceilingMs = nil
        syncedCreditedMs = nil
        problem = nil
        appWindow.close()
        onChange?()
    }

    /// The dashboard or settings window. Logged out, it asks for a login first.
    func openWindow(tab: String) {
        guard let token = TokenStore.get("session") else {
            promptLogin { [weak self] in self?.openWindow(tab: tab) }
            return
        }
        appWindow.show(tab: tab, token: token, state: macState)
    }

    /// What the page's "This Mac" panel shows. These settings live on this Mac, not in the account.
    private var macState: [String: Any] {
        [
            "version": appVersion(),
            "openAtLogin": LoginItem.isOn,
            "openAtLoginNeedsApproval": LoginItem.needsApproval,
            "budgetMode": usesTasks ? "dynamic" : "fixed",
            "hasTodayPlan": hasTodayPlan,
            "pauseLocks": pauseLocks,
        ]
    }

    private func handle(_ request: AppWindow.Request) {
        switch request {
        case .openAtLogin(let on):
            LoginItem.set(on)
        case .budgetMode(let dynamic):
            if dynamic { useDynamicBudget() } else { useFixedBudget() }
        case .planToday:
            editDayPlan()
        case .logOut:
            logout()
            return
        case .saved:
            schedulePull()
        case .pauseLocks(let on):
            defaults.set(on, forKey: Self.pauseLocksKey)
            onChange?()
        }
        appWindow.update(state: macState)
    }

    /// What the menu says before its commands: today's looking, the next break, and a problem if there is one.
    /// Upload bookkeeping stays out of it: the count already includes time not yet uploaded.
    func menuLines() -> [String] {
        var lines: [String] = []
        let usage = todayUsage()
        if let ceiling = usage.ceilingMs {
            var line = "Today: \(formatDuration(usage.usedMs)) of \(formatDuration(ceiling))"
            if usage.usedMs > ceiling { line += ", \(formatDuration(usage.usedMs - ceiling)) over" }
            lines.append(line)
        } else if usesTasks {
            lines.append("Today: \(formatDuration(usage.usedMs)). Plan today to set a budget.")
        } else {
            lines.append("Today: \(formatDuration(usage.usedMs))")
        }
        if let line = breakLine() { lines.append(line) }
        if !signedIn {
            lines.append("Not logged in. Time stays on this Mac.")
        } else if let problem {
            lines.append(problem)
        }
        return lines
    }

    private func breakLine() -> String? {
        if isPaused {
            return pauseCovering ? "Paused. Not counted, and this Mac stays awake." : "Unpaused for 5 minutes."
        }
        guard plan.enabled else { return "Breaks are off." }
        if let active = reminder.activeBreak {
            return active.paused ? "Break waits until the call ends." : "On a break."
        }
        if reminder.snoozed != nil { return "Break back in under 5 minutes." }
        if onCall && (reminder.heldBreak || reminder.extraDue != nil) { return "Break waits until the call ends." }
        if reminder.extraDue != nil { return "Break coming up." }
        if overtimeInCharge {
            return "Past the limit. Next break in \(within(plan.overtimeAfterMs - reminder.overtimeMs))."
        }
        if plan.recurringEnabled, plan.upcoming != nil {
            return "Next break in \(within(plan.everyMs - reminder.stretchMs))."
        }
        return nil
    }

    private func within(_ ms: Int64) -> String {
        ms < 60_000 ? "less than a minute" : formatDuration(ms)
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
            // That list was for another day. Ask again for today's.
            dayPlanDeferred = true
            onChange?()
            return
        }
        dayPlan = saved
        BudgetStore.savePlan(saved)
        dayPlanDeferred = false
        appWindow.update(state: macState)
        onChange?()
    }

    func editBreaks() {
        editor.show(plan: plan)
    }

    var breaksEnabled: Bool { plan.enabled }

    func skipActiveBreak() {
        guard reminder.activeBreak != nil else { return }
        reminder = skipBreak(state: reminder)
        endBreak()
        onChange?()
    }

    /// "5 more minutes" on an automatic pause. It comes back with the time it had left.
    func snoozeActiveBreak() {
        let (next, held) = snoozeBreak(state: reminder)
        guard held != nil else { return }
        reminder = next
        endBreak()
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

    /// The pause cover is locked with this Mac's password. Set from the Settings window.
    var pauseLocks: Bool { defaults.bool(forKey: Self.pauseLocksKey) }

    /// A locked pause cover is up, so quitting the app must not take it down.
    var blocksQuit: Bool { pauseCovering && pauseLocks }

    enum Unlocked: Sendable { case unpause, peek }

    private func proceed(_ next: Unlocked) {
        switch next {
        case .unpause: unpause()
        case .peek: peek()
        }
    }

    /// Asks for the Mac's password (or Touch ID) before leaving a locked pause.
    /// A Mac with no password to ask for does not lock anyone out.
    private func unlock(then next: Unlocked) {
        guard pauseLocks else { return proceed(next) }
        guard !unlocking else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return proceed(next) }
        unlocking = true
        pauseOverlay.makeRoomForPrompt(true)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock the paused screen") { ok, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.unlocking = false
                if ok {
                    self.proceed(next)
                } else if self.pauseCovering {
                    self.pauseOverlay.makeRoomForPrompt(false)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

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
        onChange?()
    }

    func unpause() {
        guard pausedSince != nil else { return }
        pausedSince = nil
        peekTimer?.invalidate()
        peekTimer = nil
        pauseOverlay.hide()
        power.release()
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
        pauseOverlay.show(since: since, locked: pauseLocks)
        onChange?()
    }

    func toggleBreaks() {
        var next = plan
        next.enabled.toggle()
        replacePlan(next)
    }

    /// A local edit. Signed in, it goes to the account right away; signed out, it stays on this Mac.
    func replacePlan(_ saved: BreakPlan) {
        applyPlan(saved)
        if signedIn {
            defaults.set(true, forKey: Self.breaksDirtyKey)
            defaults.set(NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000)), forKey: Self.breaksEditedAtKey)
            schedulePull()
        }
    }

    private func schedulePull() {
        Task { await self.pullSettings() }
    }

    /// The quick check: one small request for the limit and when breaks last changed.
    /// Breaks are fetched or pushed only when one side moved. Readings still upload on the slower sync.
    private func pullSettings() async {
        guard let session = TokenStore.get("session") else { return }
        let api = ApiClient(baseURL: ApiOrigin.baseURL)
        do {
            let settings = try await api.settings(token: session)
            config.idleThresholdMs = settings.idleThresholdMs
            // An older server sends neither field; then the limit waits for the full sync.
            if let breaksAt = settings.breaksUpdatedAtMs {
                ceilingMs = settings.limitMs
                if defaults.bool(forKey: Self.breaksDirtyKey) || breaksAt != syncedBreaksAt {
                    try await syncBreaks(api: api, session: session)
                }
            }
            onChange?()
        } catch {
            if ApiError.isSignedOut(error) { logout() }
            // Anything else is a missed check. The next one is seconds away.
        }
    }

    private var syncedBreaksAt: Int64 {
        (defaults.object(forKey: Self.breaksSyncedAtKey) as? NSNumber)?.int64Value ?? 0
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
            if waiting.kind == .overtime, plan.overtimeDue == nil { reminder.extraDue = nil }
        }
        if plan.overtimeAfterMs == 0 {
            reminder.overtimeMs = 0
        }
        if let held = reminder.snoozed {
            let kept: Bool
            switch held.kind {
            case .recurring: kept = plan.due != nil
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

    /// The latest edit wins. An unsent edit here goes up unless the account changed after it was made;
    /// then the account's newer copy replaces it. With no edit here, a changed account copy is adopted.
    private func syncBreaks(api: ApiClient, session: String) async throws {
        guard !breaksBusy else { return }
        breaksBusy = true
        defer { breaksBusy = false }
        let remote = try await api.breaks(token: session)
        let remoteAt = remote.updatedAtMs ?? 0
        let syncedAt = syncedBreaksAt
        let editedAt = (defaults.object(forKey: Self.breaksEditedAtKey) as? NSNumber)?.int64Value ?? 0
        let dirty = defaults.bool(forKey: Self.breaksDirtyKey)
        let remoteIsNewer = remoteAt > syncedAt && remoteAt > editedAt
        if remoteAt == 0 || (dirty && !remoteIsNewer) {
            let saved = try await api.saveBreaks(sessionToken: session, settings: plan.payload)
            defaults.set(NSNumber(value: saved.updatedAtMs ?? 0), forKey: Self.breaksSyncedAtKey)
        } else if remoteAt > syncedAt {
            applyPlan(plan.adopting(remote))
            defaults.set(NSNumber(value: remoteAt), forKey: Self.breaksSyncedAtKey)
        }
        // Another edit made while this one was in flight stays marked for the next check.
        if ((defaults.object(forKey: Self.breaksEditedAtKey) as? NSNumber)?.int64Value ?? 0) == editedAt {
            defaults.set(false, forKey: Self.breaksDirtyKey)
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
                overtimeBreak: plan.overtimeDue
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

    func scheduleSync() {
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
            problem = nil
            await sync()
        } catch {
            problem = "Login failed. \(error)"
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
                if ApiError.isSignedOut(error) { throw error }
                breakNote = "Break settings did not sync. \(error)"
            }
            if let device = TokenStore.get("device") {
                try await upload(api: api, deviceToken: device)
            }
            let stats = try await api.stats(token: session)
            if let today = stats.days.first {
                ceilingMs = today.ceilingMs
                syncedCreditedMs = today.creditedMs
            }
            problem = breakNote
        } catch {
            if ApiError.isSignedOut(error) {
                logout()
            } else {
                problem = "Not syncing. Today may be missing other devices. \(error)"
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
                uncover()
            case .breakFinished:
                endBreak()
            }
        }
    }

    private func present(_ active: ActiveBreak) {
        // Time behind the cover is not counted, starting now rather than at the next sample.
        if !covering { store.seal() }
        covering = true
        breakPower.hold(reason: "A Workholic break is on the screen.")
        overlay.show(message: active.message, remainingMs: active.remainingMs, snoozable: active.kind != .manual)
        guard countdownTimer == nil else { return }
        lastCountdownAt = Date()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownTick() }
        }
    }

    /// Takes the cover down. The break itself may still be held for a call.
    private func uncover() {
        overlay.hide()
        covering = false
        breakPower.release()
    }

    private func endBreak() {
        uncover()
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
            uncover()
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
