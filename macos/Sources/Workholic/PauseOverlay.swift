import AppKit
import QuartzCore

/// A black cover on every display while the user is away and an agent works.
/// It is built to cost little: dim text, one slow dot that the window server animates at a low
/// frame rate without waking the app, and only two light checks: input each second, the cover every two.
/// The backlight goes down with it, and comes up for a few seconds when the mouse moves or a key is pressed.
///
/// Locked, it also blocks app switching, Force Quit, and logging out while it is up, and the
/// buttons ask for the Mac's password first. Programs keep running and the Mac stays awake.
/// It is a lock against someone at the keyboard, not against someone who can kill the app.
///
/// The same cover goes up outside the day plan's blocks, with its own words.
@MainActor
final class PauseOverlay: NSObject {
    /// The words on the cover. The peek button is the outlined one, unpause the plain one below it.
    struct Face: Equatable {
        var title: String
        var note: String
        /// Before the time the cover has been up, as in "Paused for 12m".
        var elapsed: String
        var peek: String
        var unpause: String

        static func pause(locked: Bool) -> Face {
            Face(
                title: "Paused",
                note: locked
                    ? "Locked. Your Mac stays awake and this time is not counted. Unpausing asks for your Mac password."
                    : "Your Mac stays awake. This time is not counted.",
                elapsed: "Paused for",
                peek: "Unpause for 5 minutes",
                unpause: "Unpause"
            )
        }
    }

    var onUnpause: (() -> Void)?
    var onPeek: (() -> Void)?
    var backlight: Backlight?
    private var windows: [NSWindow] = []
    private var face = Face.pause(locked: false)
    private var titles: [NSTextField] = []
    private var peekButtons: [NSButton] = []
    private var unpauseButtons: [NSButton] = []
    private var elapsedLabels: [NSTextField] = []
    private var notes: [NSTextField] = []
    private var dots: [CALayer] = []
    private var minuteTimer: Timer?
    private var since = Date()
    private var locked = false
    /// The cover is meant to be on screen: set by `show`, cleared by `hide`.
    private var up = false
    private var prompting = false
    /// The next layout makes new windows even when the screens did not change.
    private var rebuildNext = false
    /// Moving the mouse brings the backlight up so the screen can be read; it goes down after a quiet spell.
    private let input = InputWatcher()
    private var lastInput = Date.distantPast
    private var dimTimer: Timer?
    /// Every two seconds while up, puts back a cover that is missing from some display.
    private var guardTimer: Timer?
    private var rebuiltAt = Date.distantPast
    /// Set while the cover is put back under the password prompt, which keeps the focus.
    private var keepFocus = false

    private static let wakeFor: TimeInterval = 8

    private static let kiosk: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching,
        .disableForceQuit, .disableSessionTermination, .disableHideApplication,
    ]

    var isVisible: Bool { windows.contains { $0.isVisible } }

    /// A display that comes or goes, or a Space change, would otherwise leave part of the screen uncovered.
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

    func show(since: Date, locked: Bool, face: Face? = nil) {
        self.since = since
        self.locked = locked
        self.face = face ?? .pause(locked: locked)
        // A pause going up anew starts dark, even if the last one was woken a moment ago.
        if !up { lastInput = .distantPast }
        up = true
        prompting = false
        if NSApp.isHidden { NSApp.unhide(nil) }
        layout()
        for window in windows {
            window.level = .screenSaver
            window.orderFrontRegardless()
        }
        refreshElapsed()
        for field in notes {
            field.stringValue = self.face.note
        }
        for field in titles {
            field.stringValue = self.face.title
        }
        for button in peekButtons {
            setTitle(button, self.face.peek, outlined: true)
        }
        for button in unpauseButtons {
            setTitle(button, self.face.unpause, outlined: false)
        }
        // The screen goes dark once the cover is seen to be on every display.
        checkSoon()
        input.start { [weak self] in self?.wake() }
        if locked { NSApp.presentationOptions = Self.kiosk }
        for dot in dots {
            breathe(dot)
        }
        // Taking the focus while the password prompt is up would send the typed password nowhere.
        if !keepFocus {
            NSApp.activate(ignoringOtherApps: true)
            windows.first?.makeKey()
        }
        minuteTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshElapsed() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
        guardTimer?.invalidate()
        let check = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCover() }
        }
        check.tolerance = 0.5
        RunLoop.main.add(check, forMode: .common)
        guardTimer = check
    }

    /// The window server lists a window as on screen only a run loop turn after it is ordered front,
    /// so a check right away would find every new cover missing.
    private func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkCover() }
    }

    /// The screen goes dark only while every display shows the cover, and not in the seconds after
    /// input. A dark screen with no cover on it would hide nothing and leave the user to find the
    /// brightness keys.
    private func dimIfCovered() {
        guard allOnScreen(windows) else {
            backlight?.restore()
            return
        }
        let quiet = Date().timeIntervalSince(lastInput)
        if quiet >= Self.wakeFor {
            backlight?.dim()
        } else if dimTimer == nil {
            scheduleDim(after: Self.wakeFor - quiet)
        }
    }

    /// Puts a cover that went missing back where the user is, and dims the screen once it is there.
    /// Notifications for a new display or desktop can come late or not at all, and a missing cover
    /// would leave the Mac unlocked. New windows get a second and a half to show before the next rebuild.
    private func checkCover() {
        guard up else { return }
        if !allOnScreen(windows) {
            backlight?.restore()
            if Date().timeIntervalSince(rebuiltAt) > 1.5 { reshow(rebuilding: true) }
        } else if !fitsScreens {
            reshow()
        } else if !prompting {
            dimIfCovered()
        }
    }

    func hide() {
        minuteTimer?.invalidate()
        minuteTimer = nil
        guardTimer?.invalidate()
        guardTimer = nil
        for dot in dots {
            dot.removeAllAnimations()
        }
        for window in windows {
            window.orderOut(nil)
        }
        up = false
        prompting = false
        input.stop()
        dimTimer?.invalidate()
        dimTimer = nil
        backlight?.restore()
        if locked { NSApp.presentationOptions = [] }
    }

    /// While the password prompt is up, the cover steps below it and the screen brightens to read it.
    func makeRoomForPrompt(_ prompting: Bool) {
        self.prompting = prompting
        for window in windows {
            window.level = prompting ? .normal : .screenSaver
        }
        if prompting { backlight?.restore() } else { dimIfCovered() }
    }

    /// Brightens at once; one timer, pushed back by later input, dims again after a quiet spell.
    /// Input is also the fallback for a desktop or display change a notification missed.
    private func wake() {
        guard up, !prompting else { return }
        lastInput = Date()
        backlight?.restore()
        checkCover()
    }

    private func scheduleDim(after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dimTimer = nil
                guard self.up, !self.prompting else { return }
                self.dimIfCovered()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer
    }

    /// A monitor being plugged in sends several of these, and the screen list can trail the last one;
    /// the guard timer catches what this misses.
    @objc private func screensChanged() {
        guard up else { return }
        reshow()
    }

    /// One window per screen, each covering its screen exactly.
    private var fitsScreens: Bool {
        let screens = NSScreen.screens
        return windows.count == screens.count && zip(windows, screens).allSatisfy { $0.frame.equalTo($1.frame) }
    }

    @objc private func spaceChanged() {
        guard up else { return }
        for window in windows {
            window.orderFrontRegardless()
        }
        checkSoon()
    }

    /// Shows the cover again, keeping the password prompt on top if it is up.
    /// `rebuilding` makes new windows, which open on the desktop now showing.
    private func reshow(rebuilding: Bool = false) {
        let wasPrompting = prompting
        rebuildNext = rebuilding
        keepFocus = wasPrompting
        show(since: since, locked: locked, face: face)
        keepFocus = false
        if wasPrompting { makeRoomForPrompt(true) }
    }

    @objc private func unpause() {
        onUnpause?()
    }

    @objc private func peek() {
        onPeek?()
    }

    private func refreshElapsed() {
        let text = "\(face.elapsed) \(formatDuration(Int64(Date().timeIntervalSince(since) * 1000)))"
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
        let rebuild = rebuildNext
        rebuildNext = false
        if !rebuild, fitsScreens { return }
        rebuiltAt = Date()
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        elapsedLabels = []
        notes = []
        titles = []
        peekButtons = []
        unpauseButtons = []
        dots = []
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
            window.backgroundColor = .black
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            // Without this an active Workholic gets no mouse moves at all, and moving the mouse could not brighten the screen.
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true

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

            let title = label(face.title, size: 30, white: 0.5, weight: .medium)
            title.frame = NSRect(x: 0, y: size.height / 2 + 16, width: size.width, height: 40)
            let note = label("", size: 15, white: 0.32, weight: .regular)
            note.frame = NSRect(x: 0, y: size.height / 2 - 14, width: size.width, height: 22)
            notes.append(note)
            let elapsed = label("", size: 14, white: 0.28, weight: .regular)
            elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            elapsed.frame = NSRect(x: 0, y: size.height / 2 - 40, width: size.width, height: 20)

            let peek = button(face.peek, action: #selector(peek), outlined: true)
            peek.frame = NSRect(x: size.width / 2 - 120, y: 104, width: 240, height: 36)
            let unpause = button(face.unpause, action: #selector(unpause), outlined: false)
            unpause.frame = NSRect(x: size.width / 2 - 120, y: 60, width: 240, height: 32)

            for view in [title, note, elapsed, peek, unpause] {
                content.addSubview(view)
            }
            window.contentView = content
            windows.append(window)
            elapsedLabels.append(elapsed)
            titles.append(title)
            peekButtons.append(peek)
            unpauseButtons.append(unpause)
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
        setTitle(button, title, outlined: outlined)
        return button
    }

    private func setTitle(_ button: NSButton, _ title: String, outlined: Bool) {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: outlined ? 0.7 : 0.45, alpha: 1),
                .font: NSFont.systemFont(ofSize: 15, weight: outlined ? .medium : .regular),
            ]
        )
    }
}
