import AppKit

/// Edits how often a pause appears, and the words and length of each pause.
@MainActor
final class BreakEditor: NSObject, NSWindowDelegate {
    var onSave: ((BreakPlan) -> Void)?
    private var window: NSWindow?
    private var everyField: NSTextField?
    private var enabledBox: NSButton?
    private var rows: [Row] = []
    private var list: NSStackView?
    private var ids: [UUID] = []

    func show(plan: BreakPlan) {
        if window == nil { build() }
        guard let everyField, let enabledBox, let window else { return }
        enabledBox.state = plan.enabled ? .on : .off
        everyField.stringValue = String(plan.everyMinutes)
        ids = plan.items.map(\.id)
        fill(plan.items)
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
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Break settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 470))

        let enabled = NSButton(checkboxWithTitle: "Show breaks", target: nil, action: nil)
        enabled.frame = NSRect(x: 18, y: 436, width: 200, height: 22)
        let syncNote = NSTextField(labelWithString: "Synced with your account while you are logged in.")
        syncNote.frame = NSRect(x: 20, y: 412, width: 520, height: 18)
        syncNote.textColor = .secondaryLabelColor
        content.addSubview(enabled)
        content.addSubview(syncNote)

        let everyLabel = NSTextField(labelWithString: "Remind me every")
        everyLabel.frame = NSRect(x: 20, y: 378, width: 120, height: 22)
        let every = NSTextField(string: "15")
        every.frame = NSRect(x: 142, y: 376, width: 48, height: 24)
        let minutesLabel = NSTextField(labelWithString: "minutes of looking")
        minutesLabel.frame = NSRect(x: 196, y: 378, width: 160, height: 22)
        let note = NSTextField(wrappingLabelWithString: "Each pause is one sentence, so the screen does not become another task. A rest ends early if the display turns off.")
        note.frame = NSRect(x: 20, y: 328, width: 520, height: 44)
        note.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 64, width: 520, height: 252))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 500, height: 252))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.documentView = stack

        let add = NSButton(title: "Add a pause", target: self, action: #selector(addRow))
        add.frame = NSRect(x: 20, y: 18, width: 120, height: 32)
        add.bezelStyle = .rounded
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.frame = NSRect(x: 460, y: 18, width: 80, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        content.addSubview(everyLabel)
        content.addSubview(every)
        content.addSubview(minutesLabel)
        content.addSubview(note)
        content.addSubview(scroll)
        content.addSubview(add)
        content.addSubview(save)
        window.contentView = content
        self.window = window
        self.everyField = every
        self.enabledBox = enabled
        self.list = stack
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
        list.layoutSubtreeIfNeeded()
        var height: CGFloat = 8
        for view in list.arrangedSubviews {
            height += view.fittingSize.height + list.spacing
        }
        list.frame = NSRect(x: 0, y: 0, width: 500, height: max(40, height))
    }

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
        onSave?(BreakPlan(enabled: enabledBox?.state == .on, everyMinutes: every, items: items, cursor: 0))
        window?.close()
    }

    private struct Row {
        var message: NSTextField
        var minutes: NSTextField
        var rest: NSButton
        var remove: NSButton
    }
}
