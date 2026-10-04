import AppKit

/// One full-screen window on every display. The user's sentence and a countdown are the only contents.
@MainActor
final class BreakOverlay {
    private var windows: [NSWindow] = []
    private var messages: [NSTextField] = []
    private var countdowns: [NSTextField] = []

    func show(message: String, remainingMs: Int64) {
        layout()
        apply(message: message, remainingMs: remainingMs)
        for window in windows {
            window.orderFrontRegardless()
        }
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
        for screen in screens {
            let window = NSWindow(
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
            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            content.addSubview(message)
            content.addSubview(countdown)
            window.contentView = content
            place(message: message, countdown: countdown, in: content.bounds.size)
            windows.append(window)
            messages.append(message)
            countdowns.append(countdown)
        }
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

func formatCountdown(_ ms: Int64) -> String {
    let total = max(0, ms) / 1000
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%d:%02d", minutes, seconds)
}
