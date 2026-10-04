import AppKit

/// One full-screen window on every display: the user's sentence, a countdown, and a quiet way out.
@MainActor
final class BreakOverlay: NSObject {
    var onSkip: (() -> Void)?
    private var windows: [NSWindow] = []
    private var messages: [NSTextField] = []
    private var countdowns: [NSTextField] = []
    private var skips: [NSButton] = []

    func show(message: String, remainingMs: Int64) {
        layout()
        apply(message: message, remainingMs: remainingMs)
        for window in windows {
            window.orderFrontRegardless()
        }
        // The overlay covers the menu bar, so it must take keys for Esc to reach the skip button.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    @objc private func skip() {
        onSkip?()
    }

    func update(message: String? = nil, remainingMs: Int64) {
        apply(message: message, remainingMs: remainingMs)
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
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

            let message = label(size: 40, weight: .semibold)
            let countdown = label(size: 96, weight: .medium)
            countdown.font = NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .medium)
            let skip = skipButton()
            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            content.addSubview(message)
            content.addSubview(countdown)
            content.addSubview(skip)
            window.contentView = content
            place(message: message, countdown: countdown, in: content.bounds.size)
            skip.frame = NSRect(x: (content.bounds.width - 220) / 2, y: 56, width: 220, height: 32)
            windows.append(window)
            messages.append(message)
            countdowns.append(countdown)
            skips.append(skip)
        }
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
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Works on the first click even though the overlay window was not active yet.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func formatCountdown(_ ms: Int64) -> String {
    let total = max(0, ms) / 1000
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%d:%02d", minutes, seconds)
}
