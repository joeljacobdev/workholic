import AppKit
import ServiceManagement
import UserNotifications
import WorkholicCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var model: AppModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            model = AppModel(store: try LocalStore())
        } catch {
            NSLog("Workholic could not open its database: \(error)")
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityLabel("Workholic")
        showStatus(badge: nil, fraction: nil)
        UNUserNotificationCenter.current().delegate = self
        model.onChange = { [weak self] in self?.rebuildMenu() }
        registerAtLogin()
        model.start()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        for line in model.menuLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Dashboard…", #selector(openDashboard)))
        menu.addItem(modeItem("Breaks", #selector(toggleBreaks), on: model.breaksEnabled))
        menu.addItem(item("Break settings…", #selector(editBreaks)))
        if model.canTakeBreak {
            let take = NSMenuItem(title: "Take a break now", action: nil, keyEquivalent: "")
            let lengths = NSMenu()
            for minutes in [5, 10, 15, 30] {
                let length = item("\(minutes) minutes", #selector(takeBreak(_:)))
                length.tag = minutes
                lengths.addItem(length)
            }
            take.submenu = lengths
            menu.addItem(take)
        }
        if model.isPaused {
            menu.addItem(item("Unpause", #selector(unpause)))
        } else {
            menu.addItem(item("Pause (keep awake, not counted)", #selector(pause)))
        }
        if model.sessionActive {
            menu.addItem(item("Stop session", #selector(stopSession)))
        } else {
            menu.addItem(item("Start a 25 min session", #selector(startShortSession)))
            menu.addItem(item("Start a 50 min session", #selector(startLongSession)))
            if let rest = model.restOfTodayMs() {
                menu.addItem(item("Start a session for the rest of today (\(formatDuration(rest)))", #selector(startRestSession)))
            }
        }
        menu.addItem(.separator())
        menu.addItem(modeItem("Fixed mode", #selector(useFixedBudget), on: !model.usesTasks))
        menu.addItem(modeItem("Dynamic mode", #selector(useDynamicBudget), on: model.usesTasks))
        if model.usesTasks {
            let title = model.hasTodayPlan ? "Edit today’s tasks…" : "Plan today…"
            menu.addItem(item(title, #selector(planToday)))
        }
        if model.signedIn {
            if !model.usesTasks {
                menu.addItem(item("Set limit…", #selector(setLimit)))
            }
            menu.addItem(item("Log Out", #selector(logOut)))
        } else {
            menu.addItem(item("Log In…", #selector(logIn)))
        }
        menu.addItem(item("Quit", #selector(quit)))
        statusItem.menu = menu
        showStatus(badge: model.statusBadge, fraction: model.usageFraction)
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.acknowledgeBanner()
        showStatus(badge: nil, fraction: model.usageFraction)
    }

    private func showStatus(badge: String?, fraction: Double?) {
        guard let button = statusItem.button else { return }
        button.image = statusIcon(fraction: fraction)
        button.title = badge.map { " \($0)" } ?? ""
        if let fraction {
            button.toolTip = "Workholic · \(Int((fraction * 100).rounded()))% of today's budget"
        } else {
            button.toolTip = "Workholic"
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func modeItem(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    @objc private func logIn() { model.promptLogin() }
    @objc private func logOut() { model.logout() }
    @objc private func setLimit() { model.promptLimit() }
    @objc private func useFixedBudget() { model.useFixedBudget() }
    @objc private func useDynamicBudget() { model.useDynamicBudget() }
    @objc private func planToday() { model.editDayPlan() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openDashboard() { NSWorkspace.shared.open(ApiOrigin.baseURL) }

    @objc private func startShortSession() { model.startSession(budgetMs: SessionBudget.shortMs) }
    @objc private func startLongSession() { model.startSession(budgetMs: SessionBudget.longMs) }
    @objc private func startRestSession() {
        guard let rest = model.restOfTodayMs() else { return }
        model.startSession(budgetMs: rest)
    }
    @objc private func stopSession() { model.stopSession() }
    @objc private func editBreaks() { model.editBreaks() }
    @objc private func toggleBreaks() { model.toggleBreaks() }
    @objc private func pause() { model.pause() }
    @objc private func takeBreak(_ sender: NSMenuItem) { model.takeBreak(minutes: sender.tag) }
    @objc private func unpause() { model.unpause() }
}

/// The app icon's gauge as a menu bar template image: a faint ring, an arc for
/// today's share of the budget, and the center dot. Over budget, the ring closes.
/// With no budget the arc shows the app icon's three-quarter sweep.
@MainActor
func statusIcon(fraction: Double?) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        let center = NSPoint(x: 9, y: 9)
        let radius: CGFloat = 6.5
        let lineWidth: CGFloat = 2.2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()

        let sweep = min(max(fraction ?? 0.7, 0), 1)
        if sweep > 0.005 {
            let arc = NSBezierPath()
            // Clockwise from twelve o'clock, like the app icon.
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * sweep, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = sweep >= 1 ? .butt : .round
            NSColor.black.setStroke()
            arc.stroke()
        }

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 7.4, y: 7.4, width: 3.2, height: 3.2)).fill()
        return true
    }
    image.isTemplate = true
    return image
}

private func registerAtLogin() {
    let path = Bundle.main.bundlePath
    guard path.contains("/Applications/") else { return }
    guard SMAppService.mainApp.status == .notRegistered else { return }
    try? SMAppService.mainApp.register()
}

func appVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
