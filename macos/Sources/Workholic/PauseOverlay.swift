import AppKit
import QuartzCore

/// A black cover on every display while the user is away and an agent works.
/// It is built to cost little: no per-second timer, dim text, and one slow dot
/// that the window server animates at a low frame rate without waking the app.
/// The backlight goes down with it.
///
/// Locked, it also blocks app switching, Force Quit, and logging out while it is up, and the
/// buttons ask for the Mac's password first. Programs keep running and the Mac stays awake.
/// It is a lock against someone at the keyboard, not against someone who can kill the app.
@MainActor
final class PauseOverlay: NSObject {
    var onUnpause: (() -> Void)?
    var onPeek: (() -> Void)?
    var backlight: Backlight?
    private var windows: [NSWindow] = []
    private var elapsedLabels: [NSTextField] = []
    private var notes: [NSTextField] = []
    private var dots: [CALayer] = []
    private var minuteTimer: Timer?
    private var since = Date()
    private var locked = false

    private static let kiosk: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching,
        .disableForceQuit, .disableSessionTermination, .disableHideApplication,
    ]

    var isVisible: Bool { windows.contains { $0.isVisible } }

    func show(since: Date, locked: Bool) {
        self.since = since
        self.locked = locked
        layout()
        refreshElapsed()
        let note = locked
            ? "Locked. Your Mac stays awake and this time is not counted. Unpausing asks for your Mac password."
            : "Your Mac stays awake. This time is not counted."
        for field in notes {
            field.stringValue = note
        }
        for window in windows {
            window.level = .screenSaver
            window.orderFrontRegardless()
        }
        backlight?.dim()
        if locked { NSApp.presentationOptions = Self.kiosk }
        for dot in dots {
            breathe(dot)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        minuteTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshElapsed() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    func hide() {
        minuteTimer?.invalidate()
        minuteTimer = nil
        for dot in dots {
            dot.removeAllAnimations()
        }
        for window in windows {
            window.orderOut(nil)
        }
        backlight?.restore()
        if locked { NSApp.presentationOptions = [] }
    }

    /// While the password prompt is up, the cover steps below it and the screen brightens to read it.
    func makeRoomForPrompt(_ prompting: Bool) {
        for window in windows {
            window.level = prompting ? .normal : .screenSaver
        }
        if prompting { backlight?.restore() } else { backlight?.dim() }
    }

    @objc private func unpause() {
        onUnpause?()
    }

    @objc private func peek() {
        onPeek?()
    }

    private func refreshElapsed() {
        let text = "Paused for \(formatDuration(Int64(Date().timeIntervalSince(since) * 1000)))"
        for label in elapsedLabels {
            label.stringValue = text
        }
    }

    private func breathe(_ dot: CALayer) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.12
        animation.toValue = 0.45
        animation.duration = 4
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 10, preferred: 10)
        dot.add(animation, forKey: "breathe")
    }

    private func layout() {
        let screens = NSScreen.screens
        if windows.count == screens.count, zip(windows, screens).allSatisfy({ $0.frame.equalTo($1.frame) }) {
            return
        }
        hide()
        windows = []
        elapsedLabels = []
        notes = []
        dots = []
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
            window.backgroundColor = .black
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false

            let size = screen.frame.size
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor

            let dot = CALayer()
            dot.frame = CGRect(x: size.width / 2 - 5, y: size.height / 2 + 72, width: 10, height: 10)
            dot.cornerRadius = 5
            dot.backgroundColor = NSColor(calibratedWhite: 0.85, alpha: 1).cgColor
            dot.opacity = 0.12
            content.layer?.addSublayer(dot)

            let title = label("Paused", size: 30, white: 0.5, weight: .medium)
            title.frame = NSRect(x: 0, y: size.height / 2 + 16, width: size.width, height: 40)
            let note = label("", size: 15, white: 0.32, weight: .regular)
            note.frame = NSRect(x: 0, y: size.height / 2 - 14, width: size.width, height: 22)
            notes.append(note)
            let elapsed = label("", size: 14, white: 0.28, weight: .regular)
            elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            elapsed.frame = NSRect(x: 0, y: size.height / 2 - 40, width: size.width, height: 20)

            let peek = button("Unpause for 5 minutes", action: #selector(peek), outlined: true)
            peek.frame = NSRect(x: size.width / 2 - 120, y: 104, width: 240, height: 36)
            let unpause = button("Unpause", action: #selector(unpause), outlined: false)
            unpause.frame = NSRect(x: size.width / 2 - 120, y: 60, width: 240, height: 32)

            for view in [title, note, elapsed, peek, unpause] {
                content.addSubview(view)
            }
            window.contentView = content
            windows.append(window)
            elapsedLabels.append(elapsed)
            dots.append(dot)
        }
    }

    private func label(_ text: String, size: CGFloat, white: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .center
        field.textColor = NSColor(calibratedWhite: white, alpha: 1)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        return field
    }

    private func button(_ title: String, action: Selector, outlined: Bool) -> NSButton {
        let button = FirstClickButton(title: "", target: self, action: action)
        button.isBordered = false
        if outlined {
            button.wantsLayer = true
            button.layer?.cornerRadius = 18
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
        }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: outlined ? 0.7 : 0.45, alpha: 1),
                .font: NSFont.systemFont(ofSize: 15, weight: outlined ? .medium : .regular),
            ]
        )
        return button
    }
}
