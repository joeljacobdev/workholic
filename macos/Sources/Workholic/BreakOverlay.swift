import AppKit

/// One full-screen window on every display: the user's sentence, a countdown, and a quiet way out.
///
/// The screen stays dark. The countdown and the buttons fade out a few seconds in, so a long
/// break is not a clock to watch; the sentence dims but stays readable, so the dark screen
/// always says why it is dark. Everything comes back for the last three minutes, and for a few
/// seconds whenever the mouse moves.
///
/// While it is up, app switching, the Dock, and Hide are blocked, and the cover puts itself back
/// when a display comes or goes or the Space changes. Esc still skips.
@MainActor
final class BreakOverlay: NSObject {
    var onSkip: (() -> Void)?
    var onSnooze: (() -> Void)?
    /// Turned down while the words are faded, and back up whenever they show.
    var backlight: Backlight?
    private var windows: [NSWindow] = []
    private var messages: [NSTextField] = []
    private var countdowns: [NSTextField] = []
    private var skips: [NSButton] = []
    private var snoozes: [NSButton] = []
    /// One per window, holding the countdown and the buttons, which fade almost to nothing.
    private var faders: [NSView] = []
    private var shownAt = Date()
    private var wakeUntil: Date?
    private var remainingMs: Int64 = 0
    private let input = InputWatcher()
    /// The cover is meant to be on screen: set by `show`, cleared by `hide`.
    private var up = false
    private var message = ""
    private var snoozable = false

    private static let quietAfter: TimeInterval = 8
    private static let wakeFor: TimeInterval = 5
    private static let loudUnderMs: Int64 = 3 * 60_000
    private static let quietAlpha: CGFloat = 0.05
    private static let quietMessageAlpha: CGFloat = 0.6
    /// Dock and menu bar hidden, no Cmd-Tab, no Hide. Process switching needs the Dock hidden.
    private static let lockdown: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication,
    ]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    /// `snoozable` adds "5 more minutes", which scheduled pauses offer.
    func show(message: String, remainingMs: Int64, snoozable: Bool = false) {
        // Only a cover going up anew starts loud. A rebuild for a new desktop or display keeps the quiet.
        let wasHidden = !up
        up = true
        self.message = message
        self.snoozable = snoozable
        layout()
        if wasHidden {
            shownAt = Date()
            wakeUntil = nil
            for view in faders + messages { view.alphaValue = 1 }
        }
        for button in snoozes {
            button.isHidden = !snoozable
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        for window in windows {
            window.orderFrontRegardless()
        }
        orderedAt = Date()
        NSApp.presentationOptions = Self.lockdown
        apply(message: message, remainingMs: remainingMs)
        input.start { [weak self] in self?.wake() }
        // The overlay covers the menu bar, so it must take keys for Esc to reach the skip button.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    @objc private func skip() {
        onSkip?()
    }

    @objc private func snooze() {
        onSnooze?()
    }

    /// Runs every second while the break counts down. A cover that something took down goes back up.
    func update(message: String? = nil, remainingMs: Int64) {
        if up, !fitsScreens || (strandedOnOtherSpace && !settling) {
            rebuild(message: message ?? self.message, remainingMs: remainingMs)
            return
        }
        apply(message: message, remainingMs: remainingMs)
    }

    /// The window server lists a window as on screen only a run loop turn after it is ordered front.
    /// Until then a cover cannot be judged missing, and the backlight is left as it is.
    private var orderedAt = Date.distantPast
    private var settling: Bool {
        Date().timeIntervalSince(orderedAt) < 1.5
    }

    /// Windows set to join every Space can still be left behind on the desktop they opened on,
    /// or be taken down by something else. Either way some display shows no cover.
    private var strandedOnOtherSpace: Bool {
        !allOnScreen(windows)
    }

    /// New windows, ordered front on the desktop now showing.
    private func rebuild(message: String, remainingMs: Int64) {
        if strandedOnOtherSpace { laidOutFor = nil }
        show(message: message, remainingMs: remainingMs, snoozable: snoozable)
    }

    /// Only a cover that is up gives back the backlight and the presentation options.
    /// The pause cover uses both, and a break ending under it must not undo them.
    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
        input.stop()
        guard up else { return }
        up = false
        NSApp.presentationOptions = []
        backlight?.restore()
    }

    @objc private func screensChanged() {
        guard up else { return }
        show(message: message, remainingMs: remainingMs, snoozable: snoozable)
    }

    /// The window server shows a window as on screen only a run loop turn after it is ordered front,
    /// so the check waits a moment.
    @objc private func spaceChanged() {
        guard up else { return }
        for window in windows {
            window.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.up else { return }
            if self.strandedOnOtherSpace {
                self.rebuild(message: self.message, remainingMs: self.remainingMs)
                return
            }
            self.fade()
        }
    }

    private func wake() {
        wakeUntil = Date().addingTimeInterval(Self.wakeFor)
        fade()
    }

    /// Loud at the start, near the end, and just after the mouse moved. Quiet otherwise.
    /// The backlight goes down only while every display really shows the cover.
    private func fade() {
        let now = Date()
        let loud = remainingMs <= Self.loudUnderMs
            || now.timeIntervalSince(shownAt) < Self.quietAfter
            || (wakeUntil.map { now < $0 } ?? false)
        let covered = up && allOnScreen(windows)
        if loud || (!covered && !settling) { backlight?.restore() } else if covered { backlight?.dim() }
        let target: CGFloat = loud ? 1 : Self.quietAlpha
        let messageTarget: CGFloat = loud ? 1 : Self.quietMessageAlpha
        guard let current = faders.first?.alphaValue, abs(current - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = loud ? 0.3 : 2
            for fader in faders {
                fader.animator().alphaValue = target
            }
            for field in messages {
                field.animator().alphaValue = messageTarget
            }
        }
    }

    /// The screen frames the windows were built for.
    private var laidOutFor: [NSRect]?

    private var fitsScreens: Bool {
        laidOutFor == NSScreen.screens.map(\.frame)
    }

    private func layout() {
        if fitsScreens { return }
        for window in windows {
            window.orderOut(nil)
        }
        let screens = NSScreen.screens
        laidOutFor = screens.map(\.frame)
        windows = []
        messages = []
        countdowns = []
        skips = []
        snoozes = []
        faders = []
        for screen in screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.cover(screen)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true

            let message = label(size: 40, weight: .semibold)
            let countdown = label(size: 96, weight: .medium)
            countdown.font = NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .medium)
            let skip = skipButton()
            let snooze = snoozeButton()
            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let fader = NSView(frame: content.bounds)
            fader.wantsLayer = true
            fader.autoresizingMask = [.width, .height]
            message.wantsLayer = true
            fader.addSubview(countdown)
            fader.addSubview(skip)
            fader.addSubview(snooze)
            content.addSubview(fader)
            content.addSubview(message)
            window.contentView = content
            faders.append(fader)
            place(message: message, countdown: countdown, in: content.bounds.size)
            skip.frame = NSRect(x: (content.bounds.width - 220) / 2, y: 56, width: 220, height: 32)
            snooze.frame = NSRect(x: (content.bounds.width - 220) / 2, y: 100, width: 220, height: 36)
            windows.append(window)
            messages.append(message)
            countdowns.append(countdown)
            skips.append(skip)
            snoozes.append(snooze)
        }
    }

    private func snoozeButton() -> NSButton {
        let button = FirstClickButton(title: "", target: self, action: #selector(snooze))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 18
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor(calibratedWhite: 0.45, alpha: 1).cgColor
        button.attributedTitle = NSAttributedString(
            string: "5 more minutes",
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            ]
        )
        button.isHidden = true
        return button
    }

    private func skipButton() -> NSButton {
        let button = FirstClickButton(title: "", target: self, action: #selector(skip))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: "Skip this break  (esc)",
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1),
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            ]
        )
        button.keyEquivalent = "\u{1b}"
        return button
    }

    private func apply(message: String?, remainingMs: Int64) {
        self.remainingMs = remainingMs
        fade()
        let time = formatCountdown(remainingMs)
        for field in countdowns {
            field.stringValue = time
        }
        if let message {
            for field in messages {
                field.stringValue = message
            }
        }
    }

    private func place(message: NSTextField, countdown: NSTextField, in size: NSSize) {
        let width = min(760, size.width - 120)
        message.frame = NSRect(x: (size.width - width) / 2, y: size.height / 2 + 8, width: width, height: 160)
        countdown.frame = NSRect(x: (size.width - width) / 2, y: size.height / 2 - 130, width: width, height: 120)
    }

    private func label(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.alignment = .center
        field.maximumNumberOfLines = 4
        field.lineBreakMode = .byWordWrapping
        field.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }
}

/// Borderless windows refuse key status by default, which would leave Esc with nowhere to go.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// Given a screen, the window initializer reads the content rect relative to that screen's corner,
    /// so `screen.frame` lands a second display's cover off to the side. The frame is set outright instead.
    func cover(_ screen: NSScreen) {
        setFrame(screen.frame, display: false)
    }
}

/// Whether every window is really on the screen: on the desktop each display shows now.
/// `isOnActiveSpace` can call a window present that sits on a desktop no display is showing,
/// above all with a second monitor, so this asks the window server instead.
@MainActor
func allOnScreen(_ windows: [NSWindow]) -> Bool {
    guard !windows.isEmpty else { return false }
    // Behind the macOS lock screen or another user's session nothing of ours shows; that is no missing cover.
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
       (session[kCGSessionOnConsoleKey as String] as? Bool) == false || (session["CGSSessionScreenIsLocked"] as? Bool) == true {
        return true
    }
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return true }
    let pid = ProcessInfo.processInfo.processIdentifier
    let showing = Set(info.compactMap { entry -> Int? in
        guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
        return (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
    })
    return windows.allSatisfy { showing.contains($0.windowNumber) }
}

/// Calls back when the mouse moves, clicks, scrolls, or a key is pressed, whether or not Workholic
/// is the active app. A local monitor alone misses everything once another app has the focus.
/// Keys pressed in other apps reach it only with Accessibility access; the mouse always does.
///
/// The monitors are fast but can miss input: an active app gets no mouse moves unless its key window
/// asks for them, and that window may sit on a desktop out of sight. So a check once a second of when
/// the keyboard or mouse was last touched catches the rest. It needs no permission.
@MainActor
final class InputWatcher {
    private var monitors: [Any] = []
    private var poll: Timer?
    private static let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
    private static let anyInput = CGEventType(rawValue: ~0)!

    func start(_ handler: @escaping @MainActor () -> Void) {
        guard poll == nil else { return }
        var seen = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInput)
                let touched = Date().addingTimeInterval(-idle)
                guard touched > seen.addingTimeInterval(0.05) else { return }
                seen = touched
                handler()
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.events, handler: { event in
            MainActor.assumeIsolated { handler() }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.events, handler: { _ in
            MainActor.assumeIsolated { handler() }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }
}

/// Works on the first click even though the overlay window was not active yet.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func formatCountdown(_ ms: Int64) -> String {
    let total = max(0, ms) / 1000
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%d:%02d", minutes, seconds)
}
