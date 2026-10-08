import AppKit
import WebKit

/// The app's own window: the web dashboard and settings, signed in with this Mac's session.
/// One page serves the browser, the phone, and the Mac, so the three cannot drift apart.
/// The page shows a "This Mac" panel only here, and talks back through the `workholic` handler.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    /// What the page asked the Mac to do.
    enum Request {
        case openAtLogin(Bool)
        case budgetMode(dynamic: Bool)
        case planToday
        case logOut
        /// The page saved something the Mac reads, such as breaks or the limit.
        case saved
        /// Unpausing asks for this Mac's password.
        case pauseLocks(Bool)
    }

    var onRequest: ((Request) -> Void)?
    private var window: NSWindow?
    private var webView: WKWebView?
    /// The session the page was loaded with. A new login rebuilds the page.
    private var loadedToken: String?

    var isVisible: Bool { window?.isVisible ?? false }

    /// `tab` is the page's hash route: "today", "history", or "settings".
    func show(tab: String, token: String, state: [String: Any]) {
        if window == nil || loadedToken != token { build(token: token, state: state, tab: tab) }
        else { navigate(to: tab) }
        update(state: state)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Pushes this Mac's settings into the page's "This Mac" panel.
    func update(state: [String: Any]) {
        guard let webView, let json = Self.json(state) else { return }
        webView.evaluateJavaScript("window.workholicMac && window.workholicMac.update(\(json))")
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "workholic")
        webView = nil
        window = nil
        loadedToken = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func build(token: String, state: [String: Any], tab: String) {
        window?.close()
        let content = WKUserContentController()
        // The page keeps its session in localStorage. Seed it before any page script runs.
        let seed = """
        try { localStorage.setItem("workholic.session", \(Self.json(token) ?? "\"\"")); } catch (e) {}
        window.workholicMacState = \(Self.json(state) ?? "{}");
        """
        content.addUserScript(WKUserScript(source: seed, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(self, name: "workholic")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.websiteDataStore = .nonPersistent()

        let frame = NSRect(x: 0, y: 0, width: 1040, height: 760)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workholic"
        window.minSize = NSSize(width: 420, height: 480)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrameAutosaveName("WorkholicMain")
        if !window.setFrameUsingName("WorkholicMain") { window.center() }

        self.window = window
        self.webView = webView
        loadedToken = token
        webView.load(URLRequest(url: Self.url(tab: tab)))
    }

    private func navigate(to tab: String) {
        guard let webView, let json = Self.json(tab) else { return }
        webView.evaluateJavaScript("location.hash = \(json)")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let value = body["value"]
        let request: Request
        switch action {
        case "openAtLogin": request = .openAtLogin(value as? Bool ?? false)
        case "budgetMode": request = .budgetMode(dynamic: value as? String == "dynamic")
        case "planToday": request = .planToday
        case "logOut": request = .logOut
        case "saved": request = .saved
        case "pauseLocks": request = .pauseLocks(value as? Bool ?? false)
        default: return
        }
        onRequest?(request)
    }

    /// Links off the dashboard open in the browser, not in this window.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, url.host != ApiOrigin.baseURL.host, url.scheme != "about" else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    private static func url(tab: String) -> URL {
        var components = URLComponents(url: ApiOrigin.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.fragment = tab
        return components.url!
    }

    private static func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
