import AppKit
import WorkholicCore

/// Asks for today's tasks and a rough time for each. The total is only this civil day's ceiling.
@MainActor
final class DayPlanEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onSave: ((DayBudget) -> Void)?
    private var window: NSWindow?
    private var rows: [Row] = []
    private var list: NSStackView?
    private var totalLabel: NSTextField?
    private var day = ""

    var isVisible: Bool { window?.isVisible ?? false }

    func show(day: String, tasks: [DayTask]) {
        self.day = day
        if window == nil { build() }
        fill(tasks)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        rows = []
        list = nil
        totalLabel = nil
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshTotal()
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Today"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))

        let note = NSTextField(wrappingLabelWithString: "Name what you plan to look at today, and a rough time for each. The total is today’s ceiling. Tomorrow starts empty. A task that runs past the day is finished, and it is not carried over.")
        note.frame = NSRect(x: 20, y: 368, width: 520, height: 56)
        note.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 96, width: 520, height: 260))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 500, height: 292))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.documentView = stack

        let total = NSTextField(labelWithString: "Today: add a task and a rough time.")
        total.frame = NSRect(x: 20, y: 64, width: 520, height: 22)

        let add = NSButton(title: "Add a task", target: self, action: #selector(addRow))
        add.frame = NSRect(x: 20, y: 18, width: 120, height: 32)
        add.bezelStyle = .rounded
        let save = NSButton(title: "Set today", target: self, action: #selector(save))
        save.frame = NSRect(x: 448, y: 18, width: 92, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        content.addSubview(note)
        content.addSubview(scroll)
        content.addSubview(total)
        content.addSubview(add)
        content.addSubview(save)
        window.contentView = content
        self.window = window
        self.list = stack
        self.totalLabel = total
    }

    private func fill(_ tasks: [DayTask]) {
        guard let list else { return }
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = []
        let source = tasks.isEmpty ? [DayTask(name: "", budgetMs: 0)] : tasks
        for task in source {
            append(task)
        }
        refreshTotal()
    }

    private func append(_ task: DayTask) {
        guard let list else { return }
        let name = NSTextField(string: task.name)
        name.placeholderString = "What this time is for"
        name.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        name.delegate = self
        let hours = NSTextField(string: task.budgetMs > 0 ? hoursText(task.budgetMs) : "")
        hours.placeholderString = "1.5"
        hours.frame = NSRect(x: 0, y: 0, width: 56, height: 24)
        hours.delegate = self
        let unit = NSTextField(labelWithString: "hours")
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeRow(_:)))
        remove.bezelStyle = .rounded
        remove.tag = rows.count
        let row = NSStackView(views: [name, hours, unit, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        list.addArrangedSubview(row)
        rows.append(Row(name: name, hours: hours, remove: remove))
        renumber()
    }

    @objc private func addRow() {
        append(DayTask(name: "", budgetMs: 0))
        refreshTotal()
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard rows.count > 1, sender.tag < rows.count, let list else { return }
        let view = list.arrangedSubviews[sender.tag]
        list.removeArrangedSubview(view)
        view.removeFromSuperview()
        rows.remove(at: sender.tag)
        renumber()
        refreshTotal()
    }

    private func renumber() {
        for (index, row) in rows.enumerated() {
            row.remove.tag = index
            row.remove.isEnabled = rows.count > 1
        }
        guard let list else { return }
        list.layoutSubtreeIfNeeded()
        var height: CGFloat = 8
        for view in list.arrangedSubviews {
            height += view.fittingSize.height + list.spacing
        }
        list.frame = NSRect(x: 0, y: 0, width: 500, height: max(40, height))
    }

    private func refreshTotal() {
        let tasks = draftedTasks()
        let raw = tasks.reduce(Int64(0)) { $0 + $1.budgetMs }
        if raw > DayBudgetRule.capMs {
            totalLabel?.stringValue = "Today stops at 24 hours."
            return
        }
        if tasks.isEmpty {
            totalLabel?.stringValue = "Today: add a task and a rough time."
            return
        }
        totalLabel?.stringValue = "Today: \(formatDuration(dayBudgetMs(tasks)))"
    }

    @objc private func save() {
        for row in rows {
            let name = row.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                refuse("Name each task.")
                return
            }
            guard let hours = parseHours(row.hours.stringValue) else {
                refuse("Enter a rough time in hours, such as 1.5.")
                return
            }
            let ms = Int64((hours * 3_600_000).rounded())
            if ms > DayBudgetRule.capMs {
                refuse("A task stops at the end of the day. Use 24 hours or less.")
                return
            }
            if ms < 60_000 {
                refuse("Use at least a minute for each task.")
                return
            }
        }
        let tasks = draftedTasks()
        guard !tasks.isEmpty else {
            refuse("Add at least one task.")
            return
        }
        let raw = tasks.reduce(Int64(0)) { $0 + $1.budgetMs }
        guard raw == dayBudgetMs(tasks) else {
            refuse("Today stops at 24 hours. The extra is not kept for tomorrow.")
            return
        }
        onSave?(DayBudget(day: day, tasks: tasks))
        window?.close()
    }

    private func draftedTasks() -> [DayTask] {
        var tasks: [DayTask] = []
        for row in rows {
            let name = row.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let hours = parseHours(row.hours.stringValue) else { continue }
            let ms = Int64((hours * 3_600_000).rounded())
            guard ms >= 60_000 else { continue }
            tasks.append(DayTask(name: name, budgetMs: ms))
        }
        return tasks
    }

    private func refuse(_ message: String) {
        totalLabel?.stringValue = message
        NSSound.beep()
    }

    private func parseHours(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private func hoursText(_ ms: Int64) -> String {
        let hours = Double(ms) / 3_600_000
        let hundredths = (hours * 100).rounded() / 100
        if hundredths == hundredths.rounded() { return String(Int(hundredths)) }
        if (hundredths * 10).rounded() / 10 == hundredths {
            return String(format: "%.1f", hundredths)
        }
        return String(format: "%.2f", hundredths)
    }

    private struct Row {
        var name: NSTextField
        var hours: NSTextField
        var remove: NSButton
    }
}
