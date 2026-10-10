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
    private var mouseMonitor: Any?
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
        up = true
        self.message = message
        self.snoozable = snoozable
        layout()
        let wasHidden = !(windows.first?.isVisible ?? false)
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
        NSApp.presentationOptions = Self.lockdown
        apply(message: message, remainingMs: remainingMs)
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] event in
                self?.wake()
                return event
            }
        }
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
        if up, !fitsScreens || windows.contains(where: { !$0.isVisible }) {
            show(message: message ?? self.message, remainingMs: remainingMs, snoozable: snoozable)
            return
        }
        apply(message: message, remainingMs: remainingMs)
    }

    /// Only a cover that is up gives back the backlight and the presentation options.
    /// The pause cover uses both, and a break ending under it must not undo them.
    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        guard up else { return }
        up = false
        NSApp.presentationOptions = []
        backlight?.restore()
    }

    @objc private func screensChanged() {
        guard up else { return }
        show(message: message, remainingMs: remainingMs, snoozable: snoozable)
    }

    @objc private func spaceChanged() {
        guard up else { return }
        for window in windows {
            window.orderFrontRegardless()
        }
        fade()
    }

    private func wake() {
        wakeUntil = Date().addingTimeInterval(Self.wakeFor)
        fade()
    }

    /// Loud at the start, near the end, and just after the mouse moved. Quiet otherwise.
    /// The backlight goes down only while the cover is really on the screen being looked at.
    private func fade() {
        let now = Date()
        let loud = remainingMs <= Self.loudUnderMs
            || now.timeIntervalSince(shownAt) < Self.quietAfter
            || (wakeUntil.map { now < $0 } ?? false)
        let covered = windows.contains { $0.isVisible && $0.isOnActiveSpace }
        if loud || !covered { backlight?.restore() } else { backlight?.dim() }
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
