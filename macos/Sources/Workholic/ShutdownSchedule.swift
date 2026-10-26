import AppKit
import Foundation
import WorkholicCore

/// The daily scheduled shutdown comes from the account's day plan, kept by `PlanStore`.
enum ShutdownSchedule {
    /// Scripts the schedule may name. They live only on this Mac, with any credentials they need.
    static var commandsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tech.joeljacob.workholic", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
    }
}

enum ShutdownCommandResult: Sendable {
    case printed(String)
    case failed(String)
}

/// Runs the named script from the commands folder through a login shell, so PATH matches Terminal's.
/// The path goes in as `$0`, never as shell text. It gets no input and only standard output is read.
/// Past the time limit it is stopped and counts as failed.
func runShutdownCommand(_ name: String, timeout: TimeInterval = 30) async -> ShutdownCommandResult {
    guard isScriptName(name) else { return .failed("\"\(name)\" is not a script name") }
    let folder = ShutdownSchedule.commandsFolder
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let script = folder.appendingPathComponent(name).path
    guard FileManager.default.isExecutableFile(atPath: script) else {
        return .failed("\"\(name)\" is missing or not executable in the commands folder")
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "exec \"$0\"", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failed("could not start"))
                return
            }
            let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stop.cancel()
            if process.terminationReason == .uncaughtSignal {
                continuation.resume(returning: .failed("timed out or was stopped"))
            } else if process.terminationStatus != 0 {
                continuation.resume(returning: .failed("exited with \(process.terminationStatus)"))
            } else {
                continuation.resume(returning: .printed(String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// A small window over everything, covers included: the Mac shuts down when the count reaches zero
/// unless Cancel is pressed. Esc and Return both cancel, so a stray key never shuts down early.
@MainActor
final class ShutdownWarning: NSObject {
    var onCancel: (() -> Void)?
    var onShutDown: (() -> Void)?
    private var panel: NSPanel?
    private var timer: Timer?
    private var remaining = 0
    private let countLabel = NSTextField(labelWithString: "")

    var isVisible: Bool { panel != nil }

    func show(seconds: Int, reason: String) {
        guard panel == nil else { return }
        remaining = seconds
        let panel = WarningPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scheduled shutdown"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.cancelPressed() }

        countLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "\(reason) Unsaved work in open apps can stop it.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\r"
        let now = NSButton(title: "Shut Down Now", target: self, action: #selector(shutDownPressed))
        let buttons = NSStackView(views: [now, cancel])
        let stack = NSStackView(views: [countLabel, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detail.widthAnchor.constraint(equalToConstant: 340),
        ])
        panel.contentView = content
        panel.center()
        self.panel = panel
        render()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.second() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func cancelPressed() {
        close()
        onCancel?()
    }

    @objc private func shutDownPressed() {
        close()
        onShutDown?()
    }

    private func second() {
        remaining -= 1
        if remaining <= 0 {
            shutDownPressed()
        } else {
            render()
        }
    }

    private func render() {
        countLabel.stringValue = "This Mac shuts down in \(remaining) s"
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A panel with no close button still gets Esc as `cancelOperation`.
private final class WarningPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
