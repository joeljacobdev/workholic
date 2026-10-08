import AppKit

/// One full-screen window on every display: the user's sentence, a countdown, and a quiet way out.
///
/// The screen stays dark, but the words and the countdown fade out a few seconds in, so a long
/// break is not a clock to watch. They come back for the last three minutes, and for a few
/// seconds whenever the mouse moves.
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
    /// One per window, holding everything that fades.
    private var faders: [NSView] = []
    private var shownAt = Date()
    private var wakeUntil: Date?
    private var remainingMs: Int64 = 0
    private var mouseMonitor: Any?

    private static let quietAfter: TimeInterval = 8
    private static let wakeFor: TimeInterval = 5
    private static let loudUnderMs: Int64 = 3 * 60_000
    private static let quietAlpha: CGFloat = 0.05

    /// `snoozable` adds "5 more minutes", which scheduled pauses offer.
    func show(message: String, remainingMs: Int64, snoozable: Bool = false) {
        layout()
        let wasHidden = !(windows.first?.isVisible ?? false)
        if wasHidden {
            shownAt = Date()
            wakeUntil = nil
            for fader in faders { fader.alphaValue = 1 }
        }
        apply(message: message, remainingMs: remainingMs)
        for button in snoozes {
            button.isHidden = !snoozable
        }
        for window in windows {
            window.orderFrontRegardless()
        }
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

    func update(message: String? = nil, remainingMs: Int64) {
        apply(message: message, remainingMs: remainingMs)
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        backlight?.restore()
    }

    private func wake() {
        wakeUntil = Date().addingTimeInterval(Self.wakeFor)
        fade()
    }

    /// Loud at the start, near the end, and just after the mouse moved. Quiet otherwise.
    private func fade() {
        let now = Date()
        let loud = remainingMs <= Self.loudUnderMs
            || now.timeIntervalSince(shownAt) < Self.quietAfter
            || (wakeUntil.map { now < $0 } ?? false)
        if loud { backlight?.restore() } else { backlight?.dim() }
        let target: CGFloat = loud ? 1 : Self.quietAlpha
        guard let current = faders.first?.alphaValue, abs(current - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = loud ? 0.3 : 2
            for fader in faders {
                fader.animator().alphaValue = target
            }
        }
    }

    private func layout() {
        let screens = NSScreen.screens
        if windows.count == screens.count, zip(windows, screens).allSatisfy({ $0.frame.equalTo($1.frame) }) {
            return
        }
        hide()
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
            fader.addSubview(message)
            fader.addSubview(countdown)
            fader.addSubview(skip)
            fader.addSubview(snooze)
            content.addSubview(fader)
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
