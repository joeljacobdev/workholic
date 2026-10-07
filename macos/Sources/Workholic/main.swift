import AppKit
import ServiceManagement
import WorkholicCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        NSApp.mainMenu = mainMenu()
        model.onChange = { [weak self] in self?.rebuildMenu() }
        LoginItem.registerOnFirstLaunch()
        model.start()
        rebuildMenu()
    }

    /// Clicking the app in Finder or the Dock while it runs opens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.openWindow(tab: "today") }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    /// Two or three lines of state, then Dashboard, Breaks, Settings, and the account.
    /// Everything else lives in the app window, which is the same page as the web app.
    private func rebuildMenu() {
        let menu = NSMenu()
        for line in model.menuLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item("Dashboard…", #selector(openDashboard)))
        let breaks = NSMenuItem(title: "Breaks", action: nil, keyEquivalent: "")
        breaks.submenu = breaksMenu()
        menu.addItem(breaks)
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        if model.signedIn {
            menu.addItem(item("Log Out", #selector(logOut)))
        } else {
            menu.addItem(item("Log In…", #selector(logIn)))
        }
        menu.addItem(item("Quit Workholic", #selector(quit), key: "q"))
        statusItem.menu = menu
        showStatus(badge: model.statusBadge, fraction: model.usageFraction)
    }

    private func breaksMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(modeItem("Breaks on", #selector(toggleBreaks), on: model.breaksEnabled))
        let take = NSMenuItem(title: "Take a break now", action: nil, keyEquivalent: "")
        let lengths = NSMenu()
        for minutes in [5, 10, 15, 30] {
            let length = item("\(minutes) minutes", #selector(takeBreak(_:)))
            length.tag = minutes
            length.isEnabled = model.canTakeBreak
            lengths.addItem(length)
        }
        lengths.autoenablesItems = false
        take.submenu = lengths
        menu.addItem(take)
        if model.isPaused {
            menu.addItem(item("Unpause", #selector(unpause)))
        } else {
            menu.addItem(item("Pause (keep awake, not counted)", #selector(pause)))
        }
        if !model.signedIn {
            // Logged out there is no account page, so breaks are edited here.
            menu.addItem(.separator())
            menu.addItem(item("Break settings…", #selector(editBreaks)))
        }
        return menu
    }

    /// Without a main menu, copy, paste, and close do nothing in the app's windows.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(item("Settings…", #selector(openSettings), key: ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Workholic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Quit Workholic", #selector(quit), key: "q"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for (title, submenu) in [("Workholic", app), ("Edit", edit), ("Window", window)] {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            main.addItem(holder)
        }
        return main
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

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
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
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openDashboard() { model.openWindow(tab: "today") }
    @objc private func openSettings() { model.openWindow(tab: "settings") }
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

/// Open at login, switched from Settings. The first launch from an Applications folder turns it on
/// once; after that only the switch changes it, so turning it off stays off.
@MainActor
enum LoginItem {
    private static let chosenKey = "loginItemChosen"

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but macOS wants the user to allow it in System Settings › Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(true, forKey: chosenKey)
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Workholic could not change open at login: \(error)")
        }
        if on && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static func registerOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: chosenKey) else { return }
        guard Bundle.main.bundlePath.contains("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: chosenKey)
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
    }
}

func appVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
