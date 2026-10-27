import AppKit
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
    /// A check for web orders is in flight.
    private var commandsBusy = false
    /// A shutdown from the web is under way; nothing more is asked of the server.
    private var shuttingDown = false
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
    /// The account's day plan, the same on every Mac, and its version as last heard.
    private var accountPlan = PlanStore.plan()
    private var accountPlanAt = PlanStore.updatedAt()
    /// "15 more minutes" or an unlock, outside the plan's blocks.
    private var plannerPass = PlanStore.pass()
    /// Set while the cover for outside the blocks is up. It shares the pause cover, never at the same time.
    private var planCoverSince: Date?
    private let appWindow = AppWindow()
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
    /// What the password being asked for in the cover will unlock. Nil when nothing is asked.
    private var pendingUnlock: Unlocked?
    /// A password is being checked; typing meanwhile waits for the answer.
    private var checkingPassword = false
    private static let pauseLocksKey = "pauseNeedsPassword"
    private let power = PowerAssertion()
    /// Keeps the display on while a break covers it, so the break is a dark screen, not a sleeping one.
    private let breakPower = PowerAssertion()
    /// Set while pause mode is on, including a five-minute peek.
    private var pausedSince: Date?
    /// Runs during "Unpause for 5 minutes", then brings the pause cover back.
    private var peekTimer: Timer?
    var onChange: (() -> Void)?
    /// Today's scheduled shutdown from the plan, as of the last tick. A change re-arms the watch.
    private var shutdownRule: ShutdownRule?
    /// Where today's scheduled shutdown stands. Only the done day outlives a restart.
    private var shutdownWatch = ShutdownWatch(doneDay: UserDefaults.standard.string(forKey: AppModel.shutdownDoneKey))
    private let shutdownWarning = ShutdownWarning()
    /// When today's limit was crossed, for a shutdown set to come a delay after it.
    private var limitCrossing = LimitCrossing()
    /// The command's last run. `time` is nil when it failed or printed no time.
    private var shutdownCommandRan: (at: Date, command: String, time: Date?)?
    private var shutdownCommandBusy = false
    /// The menu's line about the scheduled shutdown. Nil when there is no schedule.
    private var shutdownNote: String?

    private let defaults = UserDefaults.standard

    /// Break edits made while signed in that the account has not stored yet.
    private static let breaksDirtyKey = "breakPlanDirty"
    /// The account's `updated_at_ms` for the break settings this Mac last stored or adopted.
    private static let breaksSyncedAtKey = "breakPlanSyncedAt"
    /// When this Mac's unsent break edit was made, to compare with an edit made elsewhere.
    private static let breaksEditedAtKey = "breakPlanEditedAt"
    /// The order and settings check: every minute, or every five while someone is at this Mac.
    private static let checkEverySeconds: TimeInterval = 60
    private static let attendedCheckEverySeconds: TimeInterval = 300
    /// Opening the menu twice in a row checks once.
    private static let checkAtMostEverySeconds: TimeInterval = 15
    /// When the last check went out, so the timer and the menu do not repeat one too soon.
    private var lastCheckAt: Date?
    /// Whether someone was at this Mac on the last tick.
    private var attendingNow = false
    private static let scheduledHandledKey = "scheduledHandled"
    private static let shutdownDoneKey = "scheduledShutdownDoneDay"

    init(store: LocalStore) {
        self.store = store
        scheduledHandled = UserDefaults.standard.dictionary(forKey: Self.scheduledHandledKey) as? [String: String] ?? [:]
        reminderConfig.breakAfterMs = plan.breakAfterMs
        editor.onSave = { [weak self] saved in self?.replacePlan(saved) }
        overlay.onSkip = { [weak self] in self?.skipActiveBreak() }
        overlay.onSnooze = { [weak self] in self?.snoozeActiveBreak() }
        pauseOverlay.onUnpause = { [weak self] in
            guard let self else { return }
            self.unlock(then: self.planCovering ? .planUnlock : .unpause)
        }
        pauseOverlay.onPeek = { [weak self] in
            guard let self else { return }
            if self.planCovering { self.planMore() } else { self.unlock(then: .peek) }
        }
        pauseOverlay.onPassword = { [weak self] secret in self?.checkPassword(secret) }
        pauseOverlay.onCancelPassword = { [weak self] in
            self?.pendingUnlock = nil
            self?.pauseOverlay.endPasswordPrompt()
        }
        backlight.restoreAfterCrash()
        overlay.backlight = backlight
        pauseOverlay.backlight = backlight
        PlanStore.dropOldKeys()
        shutdownRule = todayShutdownRule(now: Date())
        appWindow.onRequest = { [weak self] request in self?.handle(request) }
        shutdownWarning.onCancel = { [weak self] in self?.noteShutdown("Scheduled shutdown cancelled for today.") }
        shutdownWarning.onShutDown = { [weak self] in self?.runScheduledShutdown() }
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
        settingsTimer = Timer.scheduledTimer(withTimeInterval: Self.checkEverySeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        scheduleSync()
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

    /// Short text beside the menu bar icon. Nil shows the icon alone.
    var statusBadge: String? {
        if isPaused { return "Paused" }
        if covering { return "Break" }
        if planCovering { return "Off plan" }
        return nil
    }

    /// Today's looking, across every device: the account's last merge, or this Mac if it is ahead.
    /// It counts against the daily limit, or with the planner, the time today's blocks add up to.
    func todayUsage(now: Date = Date()) -> (usedMs: Int64, ceilingMs: Int64?) {
        let range = dayRange(now)
        let local = store.attendedMs(dayStart: range.start, dayEnd: range.end)
        let ceiling = accountPlan.mode == .planner ? Int64(plannedMinutes(todayBlocks(now))) * 60_000 : ceilingMs
        return (max(syncedCreditedMs ?? 0, local), ceiling)
    }

    /// The plan's blocks for today on this Mac's calendar.
    private func todayBlocks(_ now: Date) -> [[Int]] {
        blocksFor(accountPlan, day: civilDay(now), weekend: Calendar.current.isDateInWeekend(now))
    }

    private func todayShutdownRule(now: Date) -> ShutdownRule? {
        planShutdownRule(accountPlan, blocks: todayBlocks(now))
    }

    private func minuteOfDay(_ now: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
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
        PlanStore.clear()
        accountPlan = AccountPlan()
        accountPlanAt = nil
        plannerPass = nil
        lowerPlanCover()
        shutdownRule = nil
        shutdownWatch = shutdownRuleChanged(shutdownWatch)
        ceilingMs = nil
        syncedCreditedMs = nil
        problem = nil
        appWindow.close()
        onChange?()
    }

    /// The dashboard or settings window. Logged out, it asks for a login first.
    func openWindow(tab: String) {
        // It would open behind the cover and put the app back in the Dock, where it cannot cover full-screen apps.
        guard !coverIsUp else { return }
        guard let token = TokenStore.get("session") else {
            promptLogin { [weak self] in self?.openWindow(tab: tab) }
            return
        }
        appWindow.show(tab: tab, token: token, state: macState)
        checkSoon()
    }

    /// What the page's "This Mac" panel shows. These settings live on this Mac, not in the account.
    private var macState: [String: Any] {
        [
            "version": appVersion(),
            "openAtLogin": LoginItem.isOn,
            "openAtLoginNeedsApproval": LoginItem.needsApproval,
            "pauseLocks": pauseLocks,
        ]
    }

    private func handle(_ request: AppWindow.Request) {
        switch request {
        case .openAtLogin(let on):
            LoginItem.set(on)
        case .logOut:
            logout()
            return
        case .saved:
            pullSettingsNow()
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
        if accountPlan.mode == .planner {
            lines.append("Today: \(formatDuration(usage.usedMs)) of \(formatDuration(usage.ceilingMs ?? 0)) planned")
            lines.append(planLine(now: Date()))
        } else if let ceiling = usage.ceilingMs {
            var line = "Today: \(formatDuration(usage.usedMs)) of \(formatDuration(ceiling))"
            if usage.usedMs > ceiling { line += ", \(formatDuration(usage.usedMs - ceiling)) over" }
            lines.append(line)
        } else {
            lines.append("Today: \(formatDuration(usage.usedMs))")
        }
        if let line = breakLine() { lines.append(line) }
        if let shutdownNote { lines.append(shutdownNote) }
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

    /// Where today's plan stands: in a block, between them, or done.
    private func planLine(now: Date) -> String {
        let blocks = todayBlocks(now)
        let minute = minuteOfDay(now)
        if let block = blocks.first(where: { $0[0] <= minute && minute < $0[1] }) {
            return "In a block until \(minuteText(block[1]))."
        }
        let next = nextBlockStart(blocks, minute: minute)
        if let pass = plannerPass, pass.day == civilDay(now), minute < pass.untilMinute {
            return "Outside your plan, unlocked until \(minuteText(min(pass.untilMinute, 1439)))."
        }
        if let next { return "Next block at \(minuteText(next))." }
        return blocks.isEmpty ? "No blocks planned today." : "Today's blocks are done."
    }

    /// The cover outside the blocks. Its plain button unlocks with the password until the next block.
    private func planFace(now: Date) -> PauseOverlay.Face {
        let next = nextBlockStart(todayBlocks(now), minute: minuteOfDay(now))
        return PauseOverlay.Face(
            title: "Outside your plan",
            note: next.map { "Next block at \(minuteText($0)). This time is not counted." }
                ?? "Today's blocks are done. This time is not counted.",
            elapsed: "Covered for",
            peek: "15 more minutes",
            unpause: next.map { "Unlock until \(minuteText($0))" } ?? "Unlock for today"
        )
    }

    /// The plan's cover is on the screen.
    private var planCovering: Bool { planCoverSince != nil }

    /// Raised outside the blocks, lowered inside one or with a pass. A break, a call, or a pause of
    /// one's own comes first; the cover waits for them. It does not keep the Mac awake or lock the keyboard.
    private func checkPlanCover(now: Date) {
        let covers = plannerCovers(
            accountPlan, blocks: todayBlocks(now), day: civilDay(now), minute: minuteOfDay(now), pass: plannerPass
        )
        if !covers {
            lowerPlanCover()
            return
        }
        guard !planCovering, !covering, !onCall, !isPaused, !shuttingDown else { return }
        store.seal()
        planCoverSince = now
        fitActivationPolicy()
        pauseOverlay.show(since: now, locked: false, face: planFace(now: now))
    }

    private func lowerPlanCover() {
        guard planCovering else { return }
        planCoverSince = nil
        pendingUnlock = nil
        pauseOverlay.hide()
        fitActivationPolicy()
    }

    private func grantPass(_ pass: PlannerPass) {
        plannerPass = pass
        PlanStore.savePass(pass)
        lowerPlanCover()
        tick()
    }

    /// "15 more minutes" outside the blocks. No password: it is short and comes back on its own.
    private func planMore() {
        let now = Date()
        grantPass(morePass(day: civilDay(now), minute: minuteOfDay(now)))
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

    var canTakeBreak: Bool { reminder.activeBreak == nil && !pauseCovering && !planCovering }

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

    /// A break or the pause cover is on the screen. Hiding the app would take it down and leave only the dimmed backlight.
    var coverIsUp: Bool { covering || pauseCovering || planCovering }

    enum Unlocked: Sendable { case unpause, peek, planUnlock }

    private func proceed(_ next: Unlocked) {
        switch next {
        case .unpause: unpause()
        case .peek: peek()
        case .planUnlock:
            let now = Date()
            grantPass(unlockPass(todayBlocks(now), day: civilDay(now), minute: minuteOfDay(now)))
        }
    }

    /// Asks for the Mac's password, in the cover, before leaving a locked pause, and always before
    /// unlocking outside the plan. A Mac with no account to check against does not lock anyone out.
    /// The field is on every display, so a click on another display's button just moves the typing there.
    private func unlock(then next: Unlocked) {
        guard pauseLocks || next == .planUnlock else { return proceed(next) }
        guard MacPassword.canCheck() else { return proceed(next) }
        pendingUnlock = next
        let caption = next == .planUnlock ? "Enter your Mac password to use it outside your plan" : "Enter your Mac password to unlock"
        pauseOverlay.askPassword(caption: caption)
    }

    private func checkPassword(_ secret: String) {
        guard let next = pendingUnlock, !checkingPassword else { return }
        checkingPassword = true
        Task { @MainActor [weak self] in
            let ok = await MacPassword.check(secret)
            guard let self else { return }
            self.checkingPassword = false
            // The ask may have been cancelled, or the cover lowered (at a block's start, say), while checking.
            guard self.pendingUnlock == next, self.pauseOverlay.isAskingPassword else { return }
            guard ok else { return self.pauseOverlay.passwordWrong() }
            self.pendingUnlock = nil
            self.pauseOverlay.endPasswordPrompt()
            self.proceed(next)
        }
    }

    /// The pause cover is up: pause mode is on and this is not a five-minute peek.
    private var pauseCovering: Bool { pausedSince != nil && peekTimer == nil }

    /// Away while an agent works: the Mac stays awake, the screen is covered, and nothing counts.
    func pause() {
        guard pausedSince == nil else { return }
        // A pause of one's own takes the cover over; the plan's comes back after the unpause if still due.
        lowerPlanCover()
        pausedSince = Date()
        power.hold(reason: "Workholic is paused while you are away.")
        coverForPause()
    }

    /// Five minutes of normal use. Time counts again until the cover comes back.
    func peek() {
        guard pausedSince != nil, peekTimer == nil else { return }
        pauseOverlay.hide()
        fitActivationPolicy()
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
        fitActivationPolicy()
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
        // pauseCovering is already true here, so this steps out of the Dock before the cover goes up.
        fitActivationPolicy()
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
            pullSettingsNow()
        }
    }

    /// A break edit to push, or one saved in the window to take, goes at once.
    private func pullSettingsNow() {
        Task { await self.pullSettings() }
    }

    /// Every minute when nobody is at this Mac, such as one left running an agent, so a shutdown
    /// from the web lands quickly. Every five minutes while someone is: they can shut it down themselves.
    private func checkIfDue() {
        let every = attendingNow ? Self.attendedCheckEverySeconds : Self.checkEverySeconds
        // A few seconds early is fine: the timer and the last check never line up exactly.
        if let last = lastCheckAt, Date().timeIntervalSince(last) < every - 5 { return }
        checkIn()
    }

    /// Opening the menu or a window, or waking, checks at once instead of waiting for the timer.
    func checkSoon() {
        if let last = lastCheckAt, Date().timeIntervalSince(last) < Self.checkAtMostEverySeconds { return }
        checkIn()
    }

    private func checkIn() {
        lastCheckAt = Date()
        Task {
            if await !self.checkCommands() { await self.pullSettings() }
        }
    }

    /// Orders from the web for this Mac, read with its device token, so only this Mac's own.
    /// Each is acknowledged before it runs: a restart cannot run it twice, and one cancelled
    /// in the meantime comes back with `go` false and is dropped.
    /// The same answer carries the settings check. False when it did not, so they still need asking.
    private func checkCommands() async -> Bool {
        guard !commandsBusy, !shuttingDown else { return true }
        guard let device = TokenStore.get("device") else { return false }
        commandsBusy = true
        defer { commandsBusy = false }
        let api = ApiClient(baseURL: ApiOrigin.baseURL)
        // A failed check is retried with the next one. It never signs out: that is the session's job.
        guard let pending = try? await api.commands(
            deviceToken: device, deviceId: deviceId, planAt: accountPlanAt
        ) else { return true }
        if let at = pending.dayPlanUpdatedAtMs, let sent = pending.dayPlan {
            adoptPlan(sent.flatMap { validAccountPlan($0) ? $0 : nil } ?? AccountPlan(), at: at)
        }
        for command in pending.commands where command.kind == "shutdown" {
            guard let ack = try? await api.ackCommand(
                deviceToken: device, deviceId: deviceId, commandId: command.commandId, result: "delivered"
            ), ack.go else { continue }
            shutDown(api: api, deviceToken: device, commandId: command.commandId)
            return true
        }
        guard let settings = pending.settings else { return false }
        await adoptSettings(
            idleThresholdMs: settings.idleThresholdMs,
            limitMs: settings.limitMs,
            breaksUpdatedAtMs: settings.breaksUpdatedAtMs,
            api: api
        )
        return true
    }

    /// A plan that fails the Mac's own checks counts as none: a limit, no blocks, no shutdown.
    private func adoptPlan(_ next: AccountPlan, at: Int64) {
        accountPlanAt = at
        PlanStore.save(next, updatedAt: at)
        guard next != accountPlan else { return }
        accountPlan = next
        tick()
    }

    /// Clears everything of Workholic's that would stand in the way: the covers, the locked pause's
    /// kiosk mode that blocks shutting down, and the quit guard. Then asks macOS to shut down.
    private func shutDown(api: ApiClient, deviceToken: String, commandId: String) {
        let status = clearAndShutDown()
        guard status != noErr else { return }
        let deviceId = deviceId
        Task {
            _ = try? await api.ackCommand(
                deviceToken: deviceToken, deviceId: deviceId, commandId: commandId, result: "failed:apple-event \(status)"
            )
        }
    }

    /// The Apple Event's status. On a refusal Workholic carries on as before.
    private func clearAndShutDown() -> OSStatus {
        shuttingDown = true
        if reminder.activeBreak != nil {
            reminder = skipBreak(state: reminder)
        }
        endBreak()
        pausedSince = nil
        planCoverSince = nil
        peekTimer?.invalidate()
        peekTimer = nil
        pauseOverlay.hide()
        power.release()
        NSApp.presentationOptions = []
        store.seal()
        onChange?()
        let status = SystemShutdown.request()
        if status != noErr { shuttingDown = false }
        return status
    }

    /// The settings check on its own: one small request for the limit and when breaks last changed.
    /// For a break edit, and for a server whose order check does not carry it.
    private func pullSettings() async {
        guard let session = TokenStore.get("session") else { return }
        let api = ApiClient(baseURL: ApiOrigin.baseURL)
        do {
            let settings = try await api.settings(token: session)
            await adoptSettings(
                idleThresholdMs: settings.idleThresholdMs,
                limitMs: settings.limitMs,
                breaksUpdatedAtMs: settings.breaksUpdatedAtMs,
                api: api
            )
        } catch {
            if ApiError.isSignedOut(error) { logout() }
            // Anything else is a missed check. The next one tries again.
        }
    }

    /// Breaks are fetched or pushed only when one side moved. Readings still upload on the slower sync.
    private func adoptSettings(idleThresholdMs: Int64, limitMs: Int64?, breaksUpdatedAtMs: Int64?, api: ApiClient) async {
        guard let session = TokenStore.get("session") else { return }
        config.idleThresholdMs = idleThresholdMs
        // An older server sends neither field; then the limit waits for the full sync.
        if let breaksAt = breaksUpdatedAtMs {
            ceilingMs = limitMs
            if defaults.bool(forKey: Self.breaksDirtyKey) || breaksAt != syncedBreaksAt {
                do {
                    try await syncBreaks(api: api, session: session)
                } catch {
                    if ApiError.isSignedOut(error) { logout() }
                    return
                }
            }
        }
        onChange?()
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
            tick: ReminderTick(slept: true, onCall: onCall || pauseCovering || planCovering, displayAwake: false, dueBreak: plan.due),
            config: reminderConfig
        )
        reminder = next
        deliver(notices)
        onChange?()
    }

    @objc private func didWake() {
        tick()
        checkSoon()
    }

    private func tick() {
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
                covered: covering || pauseCovering || planCovering
            ),
            idleThresholdMs: config.idleThresholdMs
        )
        attendingNow = isAttending
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
        // The pause and plan covers hold every break the way a call does.
        let (next, notices) = reminderStep(
            state: reminder,
            tick: ReminderTick(
                attendedAddMs: attendedAddMs(step),
                gapMs: gap,
                slept: broke,
                onCall: onCall || pauseCovering || planCovering,
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
        checkPlanCover(now: now)
        // The plan, or the day and so its blocks, may have changed the shutdown since the last tick.
        let rule = todayShutdownRule(now: now)
        if rule != shutdownRule {
            shutdownRule = rule
            shutdownWatch = shutdownRuleChanged(shutdownWatch)
        }
        checkScheduledShutdown(now: now)
        onChange?()
    }

    /// Anything unclear means no shutdown: a rule that fails the checks, a failed script, output that is
    /// not a time, or a total not known yet. A call holds it. When everything holds, a 60-second warning can cancel it.
    private func checkScheduledShutdown(now: Date) {
        guard !shuttingDown, !shutdownWarning.isVisible else { return }
        guard let rule = shutdownRule else {
            shutdownNote = nil
            return
        }
        guard validShutdownRule(rule) else {
            shutdownNote = "Scheduled shutdown is off: its settings do not read."
            return
        }
        let day = civilDay(now)
        var over = false
        if rule.when == .limit {
            let usage = todayUsage(now: now)
            guard let ceiling = committedMs(now: now) else {
                shutdownNote = "Scheduled shutdown waits for a daily limit."
                return
            }
            // Signed in, other devices count. Until the first sync that total is not known, and
            // arming on a low local count could shut down right after launch.
            if signedIn, syncedCreditedMs == nil {
                shutdownNote = "Scheduled shutdown waits for today's total."
                return
            }
            over = usage.usedMs >= ceiling
            limitCrossing = limitCrossingStep(limitCrossing, day: day, over: over, now: now)
        }
        let gate = shutdownGateOpen(
            rule, msIntoDay: msIntoDay(now), overLimit: over, crossedAt: limitCrossing.crossedAt, now: now
        )
        let (watch, status) = shutdownStep(shutdownWatch, day: day, gateOpen: gate)
        shutdownWatch = watch
        switch status {
        case .waiting:
            shutdownNote = "Shuts down \(describeShutdown(rule))."
        case .missed:
            shutdownNote = "No scheduled shutdown today: it was already due when Workholic started."
        case .done:
            if shutdownNote == nil || shutdownNote?.hasPrefix("Shuts down") == true {
                shutdownNote = "Scheduled shutdown done for today."
            }
        case .ready:
            if onCall {
                shutdownNote = "Scheduled shutdown waits until the call ends."
                return
            }
            guard let command = rule.command else {
                warnShutdown(day: day, reason: "Scheduled \(describeShutdown(rule)).")
                return
            }
            askShutdownCommand(command, rule: rule, day: day, now: now)
        }
    }

    /// The script says when shutting down is fine; the later of its time and the set time wins, since
    /// the gate already held the set time. A printed time that has passed is trusted only from a run
    /// in the last minute, so the warning always rests on a fresh answer.
    private func askShutdownCommand(_ command: String, rule: ShutdownRule, day: String, now: Date) {
        if let ran = shutdownCommandRan, ran.command == command, now.timeIntervalSince(ran.at) < 300 {
            guard let time = ran.time else { return }
            if time > now {
                shutdownNote = "Shuts down after \(clockText(time)), from \(command)."
                return
            }
            if now.timeIntervalSince(ran.at) < 60 {
                warnShutdown(day: day, reason: "Scheduled \(describeShutdown(rule)); \(command) said after \(clockText(time)).")
                return
            }
        }
        guard !shutdownCommandBusy else { return }
        shutdownCommandBusy = true
        shutdownNote = "Asking \(command) when to shut down…"
        Task {
            let result = await runShutdownCommand(command)
            let ranAt = Date()
            self.shutdownCommandBusy = false
            switch result {
            case .failed(let why):
                self.shutdownCommandRan = (ranAt, command, nil)
                self.shutdownNote = "Shutdown script \(why). Not shutting down; trying again in 5 minutes."
            case .printed(let text):
                let time = readShutdownTime(text, now: ranAt)
                self.shutdownCommandRan = (ranAt, command, time)
                if time == nil {
                    self.shutdownNote = "\(command) printed no time. Not shutting down; trying again in 5 minutes."
                } else {
                    // Everything is looked at again: the day, the schedule, or a call may have changed meanwhile.
                    self.checkScheduledShutdown(now: Date())
                }
            }
            self.onChange?()
        }
    }

    /// The day is done once warned, so a cancel or a refusal is not tried again until tomorrow.
    private func warnShutdown(day: String, reason: String) {
        shutdownWatch.doneDay = day
        defaults.set(day, forKey: Self.shutdownDoneKey)
        shutdownNote = "Scheduled shutdown in 60 seconds."
        shutdownWarning.show(seconds: 60, reason: reason)
    }

    private func runScheduledShutdown() {
        // A call that started during the countdown wins.
        if callInProgress() {
            noteShutdown("Scheduled shutdown skipped today: a call was going.")
            return
        }
        let status = clearAndShutDown()
        noteShutdown(status == noErr ? "Shutting down…" : "Scheduled shutdown did not go through (macOS said \(status)).")
    }

    private func noteShutdown(_ note: String) {
        shutdownNote = note
        onChange?()
    }

    private func describeShutdown(_ rule: ShutdownRule) -> String {
        var text: String
        switch rule.when {
        case .time:
            text = "after \(rule.after ?? "")"
        case .limit:
            text = rule.delayMinutes > 0 ? "\(formatDuration(Int64(rule.delayMinutes) * 60_000)) after today's limit" : "once past today's limit"
        }
        if let command = rule.command { text += ", or later if \(command) says so" }
        return text
    }

    private func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }

    /// Only asked when overtime pauses are on, since it reads today's total.
    private func overLimit(now: Date) -> Bool {
        guard plan.overtimeAfterMs > 0, let ceiling = committedMs(now: now) else { return false }
        let range = dayRange(now)
        let local = store.attendedMs(dayStart: range.start, dayEnd: range.end)
        return max(local, syncedCreditedMs ?? 0) >= ceiling
    }

    /// A scheduled entry whose window is open now shows what is left of it. It does not open over
    /// another pause, while one is snoozed, on a call, under a cover, or on a dark screen.
    private func openScheduled(now: Date, displayAwake: Bool) {
        guard reminder.activeBreak == nil, reminder.snoozed == nil, !onCall, !pauseCovering, !planCovering,
              displayAwake else { return }
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

    /// The daily limit, which only limit mode has. The planner's blocks are not a limit.
    private func committedMs(now: Date) -> Int64? {
        accountPlan.mode == .limit ? ceilingMs : nil
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
        fitActivationPolicy()
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
        fitActivationPolicy()
    }

    /// With the dashboard open the app is a Dock app, and a Dock app's windows cannot cover
    /// another app's full-screen Space: the break would only dim the screen. So while a cover
    /// is up the app is a menu bar app again, and the Dock icon comes back after.
    private func fitActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = coverIsUp || !appWindow.isVisible ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func endBreak() {
        uncover()
        // Whatever path ended the break, the screen comes back to full brightness unless the pause cover has it.
        if !pauseCovering { backlight.restore() }
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
