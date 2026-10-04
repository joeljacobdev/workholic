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
        statusItem.button?.title = "Workholic"
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
        statusItem.button?.title = model.statusTitle
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.acknowledgeBanner()
        statusItem.button?.title = "Workholic"
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
