import AppKit
import WorkholicCore

/// Edits every kind of pause: every few minutes, past the daily limit, and at set times.
/// Used while logged out; logged in, the Settings window edits the account's copy.
@MainActor
final class BreakEditor: NSObject, NSWindowDelegate {
    var onSave: ((BreakPlan) -> Void)?
    private var window: NSWindow?
    private var everyField: NSTextField?
    private var enabledBox: NSButton?
    private var recurringBox: NSButton?
    private var rows: [Row] = []
    private var list: NSStackView?
    private var ids: [UUID] = []
    private var overtime: RuleFields?
    private var overtimeEvery: NSTextField?
    private var timeRows: [TimeRow] = []
    private var timeList: NSStackView?
    private var timeAdd: NSButton?

    private static let tabSize = NSSize(width: 556, height: 400)

    func show(plan: BreakPlan) {
        if window == nil { build() }
        guard let everyField, let enabledBox, let window else { return }
        enabledBox.state = plan.enabled ? .on : .off
        recurringBox?.state = plan.recurringEnabled ? .on : .off
        everyField.stringValue = String(plan.everyMinutes)
        ids = plan.items.map(\.id)
        fill(plan.items)
        overtime?.set(enabled: plan.overtime.enabled, message: plan.overtime.message, minutes: plan.overtime.minutes, rest: plan.overtime.rest)
        overtimeEvery?.stringValue = String(plan.overtime.everyMinutes)
        fillTimes(plan.scheduled)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        rows = []
        list = nil
        everyField = nil
        enabledBox = nil
        recurringBox = nil
        overtime = nil
        overtimeEvery = nil
        timeRows = []
        timeList = nil
        timeAdd = nil
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Break settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 560))

        let enabled = NSButton(checkboxWithTitle: "Show breaks", target: nil, action: nil)
        enabled.frame = NSRect(x: 18, y: 526, width: 200, height: 22)
        let syncNote = NSTextField(labelWithString: "Synced with your account while you are logged in. Turning this off stops every kind below.")
        syncNote.frame = NSRect(x: 20, y: 502, width: 560, height: 18)
        syncNote.textColor = .secondaryLabelColor
        content.addSubview(enabled)
        content.addSubview(syncNote)

        let tabs = NSTabView(frame: NSRect(x: 12, y: 52, width: 576, height: 444))
        tabs.addTabViewItem(tab("Every few minutes", recurringTab()))
        tabs.addTabViewItem(tab("Past the limit", overtimeTab()))
        tabs.addTabViewItem(tab("At set times", scheduledTab()))
        content.addSubview(tabs)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.frame = NSRect(x: 500, y: 14, width: 80, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)

        window.contentView = content
        self.window = window
        self.enabledBox = enabled
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    // MARK: Every few minutes

    private func recurringTab() -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: Self.tabSize))
        let recurring = NSButton(checkboxWithTitle: "Show these pauses", target: nil, action: nil)
        recurring.frame = NSRect(x: 10, y: 366, width: 300, height: 22)

        let everyLabel = NSTextField(labelWithString: "Remind me every")
        everyLabel.frame = NSRect(x: 10, y: 334, width: 120, height: 22)
        let every = NSTextField(string: "15")
        every.frame = NSRect(x: 132, y: 332, width: 48, height: 24)
        let minutesLabel = NSTextField(labelWithString: "minutes of looking")
        minutesLabel.frame = NSRect(x: 186, y: 334, width: 160, height: 22)
        let note = NSTextField(wrappingLabelWithString: "Each pause is one sentence, so the screen does not become another task. A rest ends early if the display turns off.")
        note.frame = NSRect(x: 10, y: 286, width: 530, height: 40)
        note.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: NSRect(x: 10, y: 46, width: 536, height: 232))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 516, height: 232))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.documentView = stack

        let add = NSButton(title: "Add a pause", target: self, action: #selector(addRow))
        add.frame = NSRect(x: 10, y: 6, width: 120, height: 32)
        add.bezelStyle = .rounded

        for subview in [recurring, everyLabel, every, minutesLabel, note, scroll, add] {
            view.addSubview(subview)
        }
        self.recurringBox = recurring
        self.everyField = every
        self.list = stack
        return view
    }

    private func fill(_ items: [BreakItem]) {
        guard let list else { return }
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = []
        let source = items.isEmpty ? BreakPlan.standard.items : items
        ids = source.map(\.id)
        for item in source {
            append(item)
        }
    }

    private func append(_ item: BreakItem) {
        guard let list else { return }
        let message = NSTextField(string: item.message)
        message.placeholderString = "What this pause is for"
        message.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
        let minutes = NSTextField(string: String(item.minutes))
        minutes.frame = NSRect(x: 0, y: 0, width: 44, height: 24)
        let rest = NSButton(checkboxWithTitle: "Screen off ends it", target: nil, action: nil)
        rest.state = item.rest ? .on : .off
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeRow(_:)))
        remove.bezelStyle = .rounded
        remove.tag = rows.count
        let row = NSStackView(views: [message, minutes, rest, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        list.addArrangedSubview(row)
        rows.append(Row(message: message, minutes: minutes, rest: rest, remove: remove))
        renumber()
    }

    @objc private func addRow() {
        guard rows.count < 20 else {
            NSSound.beep()
            return
        }
        append(BreakItem(id: UUID(), message: "", minutes: 5, rest: false))
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard rows.count > 1, sender.tag < rows.count, let list else { return }
        let view = list.arrangedSubviews[sender.tag]
        list.removeArrangedSubview(view)
        view.removeFromSuperview()
        rows.remove(at: sender.tag)
        ids.remove(at: sender.tag)
        renumber()
    }

    private func renumber() {
        for (index, row) in rows.enumerated() {
            row.remove.tag = index
            row.remove.isEnabled = rows.count > 1
        }
        guard let list else { return }
        resize(list)
    }

    private func resize(_ list: NSStackView) {
        list.layoutSubtreeIfNeeded()
        var height: CGFloat = 8
        for view in list.arrangedSubviews {
            height += view.fittingSize.height + list.spacing
        }
        list.frame = NSRect(x: 0, y: 0, width: 516, height: max(40, height))
    }

    // MARK: Past the limit

    private func overtimeTab() -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: Self.tabSize))
        let fields = RuleFields(title: "Once today’s limit is reached, keep pausing", in: view, top: 366)
        let everyLabel = NSTextField(labelWithString: "Pause after every")
        everyLabel.frame = NSRect(x: 10, y: 222, width: 120, height: 22)
        let every = NSTextField(string: "25")
        every.frame = NSRect(x: 132, y: 220, width: 48, height: 24)
        let minutesLabel = NSTextField(labelWithString: "minutes past the limit")
        minutesLabel.frame = NSRect(x: 186, y: 222, width: 200, height: 22)
        let note = NSTextField(wrappingLabelWithString: "Past the limit, this replaces the every-few-minutes pause, so sessions get shorter. The first pause comes this many minutes after you cross it. Nothing changes before the limit.")
        note.frame = NSRect(x: 10, y: 166, width: 530, height: 40)
        note.textColor = .secondaryLabelColor
        for subview in [everyLabel, every, minutesLabel, note] {
            view.addSubview(subview)
        }
        overtime = fields
        overtimeEvery = every
        return view
    }

    // MARK: At set times

    private func scheduledTab() -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: Self.tabSize))
        let note = NSTextField(wrappingLabelWithString: "Each one covers the screen from its time for its length, once a day. “5 more minutes” puts it off; a dark screen does not end it.")
        note.frame = NSRect(x: 10, y: 346, width: 530, height: 40)
        note.textColor = .secondaryLabelColor
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 46, width: 536, height: 292))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 516, height: 292))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.documentView = stack
        let add = NSButton(title: "Add a time", target: self, action: #selector(addTime))
        add.frame = NSRect(x: 10, y: 6, width: 120, height: 32)
        add.bezelStyle = .rounded
        for subview in [note, scroll, add] {
            view.addSubview(subview)
        }
        timeList = stack
        timeAdd = add
        return view
    }

    private func fillTimes(_ items: [ScheduledItem]) {
        guard let timeList else { return }
        for view in timeList.arrangedSubviews {
            timeList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        timeRows = []
        for item in items {
            appendTime(item)
        }
        renumberTimes()
    }

    private func appendTime(_ item: ScheduledItem) {
        guard let timeList else { return }
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Self.date(fromClock: item.at)
        let message = NSTextField(string: item.message)
        message.placeholderString = "What this pause is for"
        message.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        let minutes = NSTextField(string: String(item.minutes))
        minutes.frame = NSRect(x: 0, y: 0, width: 44, height: 24)
        let minutesLabel = NSTextField(labelWithString: "min")
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeTime(_:)))
        remove.bezelStyle = .rounded
        let row = NSStackView(views: [picker, message, minutes, minutesLabel, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        timeList.addArrangedSubview(row)
        timeRows.append(TimeRow(id: item.id, picker: picker, message: message, minutes: minutes, remove: remove))
    }

    @objc private func addTime() {
        guard timeRows.count < 10 else {
            NSSound.beep()
            return
        }
        appendTime(ScheduledItem(id: UUID().uuidString.lowercased(), at: "13:00", message: "Lunch. Away from the screen.", minutes: 45))
        renumberTimes()
    }

    @objc private func removeTime(_ sender: NSButton) {
        guard sender.tag < timeRows.count, let timeList else { return }
        let view = timeList.arrangedSubviews[sender.tag]
        timeList.removeArrangedSubview(view)
        view.removeFromSuperview()
        timeRows.remove(at: sender.tag)
        renumberTimes()
    }

    private func renumberTimes() {
        for (index, row) in timeRows.enumerated() {
            row.remove.tag = index
        }
        timeAdd?.isEnabled = timeRows.count < 10
        if let timeList { resize(timeList) }
    }

    private static func date(fromClock text: String) -> Date {
        let minute = clockMinute(text) ?? 13 * 60
        let midnight = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .minute, value: minute, to: midnight) ?? midnight
    }

    private static func clock(from date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: Save

    @objc private func save() {
        let every = Int(everyField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        guard every >= 1, every <= 240 else {
            NSSound.beep()
            return
        }
        var items: [BreakItem] = []
        for (index, row) in rows.enumerated() {
            let message = row.message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let minutes = Int(row.minutes.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            guard !message.isEmpty, message.count <= 200, minutes >= 1, minutes <= 180 else {
                NSSound.beep()
                return
            }
            let id = index < ids.count ? ids[index] : UUID()
            items.append(BreakItem(id: id, message: message, minutes: minutes, rest: row.rest.state == .on))
        }
        guard !items.isEmpty else { return }
        guard let overtimeFields = overtime?.read() else {
            NSSound.beep()
            return
        }
        let overtimeEveryMinutes = Int(overtimeEvery?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        guard overtimeEveryMinutes >= 1, overtimeEveryMinutes <= 240 else {
            NSSound.beep()
            return
        }
        var scheduled: [ScheduledItem] = []
        for row in timeRows {
            let message = row.message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let minutes = Int(row.minutes.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            guard !message.isEmpty, message.count <= 200, minutes >= 1, minutes <= 180 else {
                NSSound.beep()
                return
            }
            scheduled.append(ScheduledItem(id: row.id, at: Self.clock(from: row.picker.dateValue), message: message, minutes: minutes))
        }
        onSave?(BreakPlan(
            enabled: enabledBox?.state == .on,
            everyMinutes: every,
            items: items,
            cursor: 0,
            recurringEnabled: recurringBox?.state != .off,
            overtime: OvertimeRule(
                enabled: overtimeFields.enabled,
                everyMinutes: overtimeEveryMinutes,
                message: overtimeFields.message,
                minutes: overtimeFields.minutes,
                rest: overtimeFields.rest
            ),
            scheduled: scheduled
        ))
        window?.close()
    }

    private struct Row {
        var message: NSTextField
        var minutes: NSTextField
        var rest: NSButton
        var remove: NSButton
    }

    private struct TimeRow {
        var id: String
        var picker: NSDatePicker
        var message: NSTextField
        var minutes: NSTextField
        var remove: NSButton
    }
}

/// The on switch, sentence, length, and rest box of the overtime pause.
@MainActor
private final class RuleFields {
    private let enabled: NSButton
    private let message: NSTextField
    private let minutes: NSTextField
    private let rest: NSButton

    init(title: String, in view: NSView, top: CGFloat) {
        enabled = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        enabled.frame = NSRect(x: 10, y: top, width: 530, height: 22)
        let messageLabel = NSTextField(labelWithString: "Message")
        messageLabel.frame = NSRect(x: 10, y: top - 38, width: 80, height: 22)
        message = NSTextField(string: "")
        message.placeholderString = "What this pause is for"
        message.frame = NSRect(x: 96, y: top - 40, width: 440, height: 24)
        let lengthLabel = NSTextField(labelWithString: "Length")
        lengthLabel.frame = NSRect(x: 10, y: top - 74, width: 80, height: 22)
        minutes = NSTextField(string: "5")
        minutes.frame = NSRect(x: 96, y: top - 76, width: 48, height: 24)
        let minutesLabel = NSTextField(labelWithString: "minutes")
        minutesLabel.frame = NSRect(x: 150, y: top - 74, width: 80, height: 22)
        rest = NSButton(checkboxWithTitle: "Screen off ends it", target: nil, action: nil)
        rest.frame = NSRect(x: 96, y: top - 108, width: 300, height: 22)
        for subview in [enabled, messageLabel, message, lengthLabel, minutes, minutesLabel, rest] {
            view.addSubview(subview)
        }
    }

    func set(enabled on: Bool, message text: String, minutes length: Int, rest isRest: Bool) {
        enabled.state = on ? .on : .off
        message.stringValue = text
        minutes.stringValue = String(length)
        rest.state = isRest ? .on : .off
    }

    /// Nil when the sentence or the length is out of range.
    func read() -> (enabled: Bool, message: String, minutes: Int, rest: Bool)? {
        let text = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = Int(minutes.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        guard !text.isEmpty, text.count <= 200, length >= 1, length <= 180 else { return nil }
        return (enabled: enabled.state == .on, message: text, minutes: length, rest: rest.state == .on)
    }
}
