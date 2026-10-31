// Port of apps/desktop/src/renderer/components/ShortcutSettings.tsx, drawn as styles.css:6049-6215 draws it
import AppKit
import FTFoundation

/// A key of a command in Settings › Shortcuts, which is also its recorder: a click starts recording, and while it records
/// every key but a plain Tab is its answer, before the menu or the window sees it (`performKeyEquivalent`). A place
/// with no key shows a dashed "+" while the pointer is on its row.
final class ShortcutSlotView: TextControl {
    let slot: ShortcutSlot
    let commandLabel: String
    private(set) var shortcut: String?
    private(set) var isRecording = false
    /// The pointer is on the row: an empty place shows.
    var rowHovered = false { didSet { needsDisplay = true } }
    /// `:focus-visible`: the last thing that reached this key was the keyboard, not a press.
    private(set) var focusIsVisible = false { didSet { needsDisplay = true } }
    /// `:focus-within`: the keyboard is on this key. The window names its new first responder only after these calls
    /// return, so this is what the remove badge goes by when the focus moves.
    private(set) var holdsKeyboard = false
    /// Told that the keyboard came or went.
    var onKeyboardChange: () -> Void = {}
    /// Told what to do; set by the tab.
    weak var owner: ShortcutSettingsView?

    private static var font: NSFont { ThemeFonts.sans(DesignTokens.typeScale.callout) }

    init(slot: ShortcutSlot, commandLabel: String, theme: Theme) {
        self.slot = slot
        self.commandLabel = commandLabel
        super.init(text: "", theme: theme)
        font = Self.font
        alignment = .center
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("settings.shortcuts.key")
        target = self
        action = #selector(clicked(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    func configure(shortcut: String?, recording: Bool) {
        self.shortcut = shortcut
        isRecording = recording
        stringValue = recording ? "Press keys…" : shortcut.map(ShortcutLabels.format) ?? "+"
        let place = slot.index == 0 ? "shortcut" : "alternate shortcut"
        setAccessibilityLabel(
            recording
                ? "Press the \(place) for \(commandLabel)"
                : shortcut.map { "\(commandLabel), \(place): \(ShortcutLabels.format($0)). Change" }
                    ?? "Add \(slot.index == 0 ? "a" : "an alternate") shortcut for \(commandLabel)")
        applyColors()
        needsDisplay = true
    }

    var isEmpty: Bool { shortcut == nil }

    var preferredWidth: CGFloat {
        max(
            SettingsMetrics.slotMinWidth,
            SettingsGlyph.textWidth(stringValue, Self.font) + 2 * SettingsMetrics.slotPadding
                + 2 * SettingsMetrics.slotBorder)
    }

    private func applyColors() {
        let palette = theme.palette
        textColor = NSColor(isEmpty && !isRecording ? palette.textTertiary : palette.textPrimary)
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyColors()
    }

    /// An empty place shows only for the row under the pointer, when the keyboard reaches it, or while recording.
    var isShown: Bool {
        !isEmpty || isRecording || rowHovered || (focusIsVisible && window?.firstResponder === self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isShown else { return }
        super.draw(dirtyRect)
    }

    override func drawChrome() {
        let palette = theme.palette
        let radius = SettingsMetrics.slotRadius
        let inset = SettingsMetrics.slotBorder / 2
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
        shape.lineWidth = SettingsMetrics.slotBorder
        if isRecording {
            NSColor(theme.accent.softBg).setFill()
            shape.fill()
            NSColor(theme.accent.solid).setStroke()
            shape.stroke()
        } else if isEmpty {
            // `button.shortcut-slot-key:hover` outweighs `.shortcut-slot-key.empty`'s clear background.
            if isHovering {
                NSColor(palette.textPrimary.withAlpha(palette.textPrimary.alpha * SettingsMetrics.slotHoverPercent))
                    .setFill()
                NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            }
            NSColor(palette.border).setStroke()
            shape.setLineDash(SettingsMetrics.slotDash, count: SettingsMetrics.slotDash.count, phase: 0)
            shape.stroke()
        } else {
            let fill =
                isHovering
                ? palette.textPrimary.withAlpha(palette.textPrimary.alpha * SettingsMetrics.slotHoverPercent)
                : palette.settingsKeycap
            NSColor(fill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        if window?.firstResponder === self, !isRecording, focusIsVisible {
            SettingsGlyph.focusRing(around: bounds, radius: radius, theme: theme)
        }
    }

    @objc private func clicked(_ sender: Any?) {
        window?.makeFirstResponder(self)
        owner?.slotClicked(self)
    }

    override func mouseDown(with event: NSEvent) {
        focusIsVisible = false
        if track() { perform() }
    }

    override func becomeFirstResponder() -> Bool {
        if NSApp.currentEvent?.type == .keyDown { focusIsVisible = true }
        holdsKeyboard = true
        needsDisplay = true
        onKeyboardChange()
        return true
    }

    override func resignFirstResponder() -> Bool {
        focusIsVisible = false
        holdsKeyboard = false
        needsDisplay = true
        onKeyboardChange()
        // Leaving the key, as Tab or a click elsewhere does, stops recording.
        if isRecording { owner?.slotLeft(self) }
        return true
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return record(event)
    }

    /// `:focus-visible` follows a key only without ⌘, ⌃ or ⌥: a click and then ⌘D draws no ring (265), a plain N before
    /// it does (a09).
    private func keyReached(_ event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty { focusIsVisible = true }
    }

    override func keyDown(with event: NSEvent) {
        keyReached(event)
        if isRecording {
            if !record(event) { super.keyDown(with: event) }
            return
        }
        // ⌫ on a key removes it without recording first.
        if shortcut != nil, event.keyCode == 51 || event.keyCode == 117 {
            owner?.removeKey(slot)
            return
        }
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            perform()
            return
        }
        super.keyDown(with: event)
    }

    /// A key while recording: false only for a plain Tab, which leaves the key as in any control.
    func record(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 48, modifiers.isEmpty { return false }
        // Everything else is the answer, and must not reach the menu or close the window.
        if event.isARepeat { return true }
        keyReached(event)
        let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event))
        owner?.recorderPressed(slot, pressed)
        return true
    }
}

/// A command's row: its label (and hint), Restore Default when it differs from the default, its keys, and the note
/// under it.
final class ShortcutRowView: ThemedView {
    let command: ShortcutCommandDefinition
    let labelText: ThemedText
    let hintText: ThemedText?
    private(set) var slots: [ShortcutSlotView] = []
    private(set) var fixedKeys: [ShortcutFixedKey] = []
    private(set) var clearButtons: [ClearButton] = []
    let restoreButton: SystemButton
    private(set) var noteText: ThemedText?
    private(set) var reassignButton: SystemButton?
    private(set) var cancelButton: SystemButton?
    private(set) var note: ShortcutRowNote?
    var drawsTopLine = true { didSet { needsDisplay = true } }
    private var customized = false
    private weak var owner: ShortcutSettingsView?
    private var trackingArea: NSTrackingArea?
    private var hovered = false {
        didSet {
            for slot in slots { slot.rowHovered = hovered }
            syncClearButtons()
        }
    }

    init(command: ShortcutCommandDefinition, hint: String?, owner: ShortcutSettingsView, theme: Theme) {
        self.command = command
        self.owner = owner
        let label = ShortcutSettingsText.withoutEllipsis(command.label)
        labelText = ThemedText(
            label,
            style: SettingsStyle.style(DesignTokens.typeScale.body) {
                command.fixed ? $0.palette.textTertiary : $0.palette.textPrimary
            })
        hintText = hint.map { ThemedText($0, style: ShortcutSettingsView.hintStyle, wrapping: true) }
        restoreButton = SystemButton.small("Restore Default", theme: theme)
        super.init(theme: theme)
        labelText.setAccessibilityIdentifier("settings.shortcuts.label")
        hintText?.setAccessibilityIdentifier("settings.shortcuts.hint")
        restoreButton.setAccessibilityLabel("Restore Default for \(label)")
        restoreButton.target = self
        restoreButton.action = #selector(restorePressed(_:))
        showRestoreButton(false)
        setAccessibilityIdentifier("settings.shortcuts.row")
        addSubview(labelText)
        if let hintText { addSubview(hintText) }
        addSubview(restoreButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var label: String { ShortcutSettingsText.withoutEllipsis(command.label) }

    /// Only a customized row has the button (ShortcutSettings.tsx:326), and hidden it is no stop for Tab.
    private func showRestoreButton(_ shows: Bool) {
        restoreButton.isHidden = !shows
        restoreButton.refusesFirstResponder = !shows
    }

    /// The keys, the place recorded and the note as they are now. The key views are kept where they can be, so the one
    /// recording keeps the keyboard.
    func update(model: ShortcutSettingsModel) {
        let shortcuts = model.shortcuts(command.id)
        if command.fixed {
            for key in fixedKeys { key.removeFromSuperview() }
            fixedKeys = shortcuts.map { ShortcutFixedKey(shortcut: $0, theme: theme) }
            for key in fixedKeys { addSubview(key) }
            setNote(nil)
            return
        }
        customized = model.isCustomized(command.id)
        showRestoreButton(customized)
        let count = model.slotCount(command.id)
        while slots.count > count { slots.removeLast().removeFromSuperview() }
        while slots.count < count {
            let slot = ShortcutSlotView(
                slot: ShortcutSlot(id: command.id, index: slots.count), commandLabel: label, theme: theme)
            slot.owner = owner
            slot.rowHovered = hovered
            slot.onKeyboardChange = { [weak self] in self?.syncClearButtons() }
            slots.append(slot)
            addSubview(slot)
        }
        for clear in clearButtons { clear.removeFromSuperview() }
        clearButtons = []
        for (index, slot) in slots.enumerated() {
            let recording = model.recording == slot.slot
            slot.configure(shortcut: shortcuts.indices.contains(index) ? shortcuts[index] : nil, recording: recording)
            let clear = ClearButton(theme: theme)
            clear.setAccessibilityLabel(
                "Remove \(slot.shortcut.map(ShortcutLabels.format) ?? "") from \(label)")
            clear.setAccessibilityIdentifier("settings.shortcuts.clear")
            clear.toolTip = nil
            clear.target = self
            clear.action = #selector(clearPressed(_:))
            clear.tag = index
            clearButtons.append(clear)
            addSubview(clear)
        }
        syncClearButtons()
        setNote(model.note?.commandID == command.id ? model.note : nil)
    }

    private func syncClearButtons() {
        for (index, clear) in clearButtons.enumerated() {
            let slot = slots[index]
            clear.isHidden = slot.shortcut == nil || slot.isRecording || !(hovered || slot.holdsKeyboard)
        }
    }

    private func setNote(_ next: ShortcutRowNote?) {
        guard next != note || (next == nil && noteText != nil) else { return }
        note = next
        noteText?.removeFromSuperview()
        reassignButton?.removeFromSuperview()
        cancelButton?.removeFromSuperview()
        noteText = nil
        reassignButton = nil
        cancelButton = nil
        guard let next else { return }
        var style = ShortcutSettingsView.noteStyle(
            refused: { if case .refused = next { return true } else { return false } }())
        style.alignment = .right
        let text = ThemedText(next.text, style: style, wrapping: true)
        text.setAccessibilityIdentifier("settings.shortcuts.note")
        addSubview(text)
        noteText = text
        if case .conflict = next {
            let reassign = SystemButton.small("Reassign", theme: theme)
            reassign.isDefault = true
            reassign.target = self
            reassign.action = #selector(reassignPressed(_:))
            let cancel = SystemButton.small("Cancel", theme: theme)
            cancel.target = self
            cancel.action = #selector(cancelPressed(_:))
            addSubview(reassign)
            addSubview(cancel)
            reassignButton = reassign
            cancelButton = cancel
        }
    }

    @objc private func restorePressed(_ sender: Any?) { owner?.resetCommand(command.id) }
    @objc private func reassignPressed(_ sender: Any?) {
        if case .conflict(let id, let index, let shortcut, _) = note {
            owner?.reassign(ShortcutSlot(id: id, index: index), shortcut)
        }
    }
    @objc private func cancelPressed(_ sender: Any?) { owner?.dismissNote() }
    @objc private func clearPressed(_ sender: ClearButton) {
        guard slots.indices.contains(sender.tag) else { return }
        owner?.removeKey(slots[sender.tag].slot)
    }

    // MARK: Layout

    func arrange(width: CGFloat) -> CGFloat {
        let border: CGFloat = drawsTopLine ? SettingsMetrics.separatorWidth : 0
        let padding = SettingsMetrics.shortcutRowPadding
        // The keys at the right: Restore Default, then the places.
        var keysWidth: CGFloat = 0
        var parts: [(NSView, CGFloat, CGFloat)] = []
        if !restoreButton.isHidden {
            parts.append((restoreButton, restoreButton.smallWidth, CGFloat(DesignTokens.controlHeights.small)))
        }
        for slot in slots { parts.append((slot, slot.preferredWidth, SettingsMetrics.slotHeight)) }
        for key in fixedKeys { parts.append((key, key.preferredWidth, SettingsMetrics.slotHeight)) }
        keysWidth =
            parts.reduce(0) { $0 + $1.1 } + CGFloat(max(0, parts.count - 1)) * SettingsMetrics.slotGap
        let textWidth = max(0, width - keysWidth - SettingsMetrics.shortcutLineGap)
        let labelHeight = labelText.height(forWidth: textWidth)
        let hintHeight = hintText?.height(forWidth: textWidth) ?? 0
        let keysHeight = parts.map(\.2).max() ?? 0
        let lineHeight = max(SettingsMetrics.shortcutLineMinHeight, labelHeight + hintHeight, keysHeight)
        let top = border + padding
        let textTop = top + ((lineHeight - labelHeight - hintHeight) / 2).rounded()
        labelText.frame = NSRect(x: 0, y: textTop, width: min(textWidth, labelText.naturalWidth), height: labelHeight)
        hintText?.frame = NSRect(x: 0, y: textTop + labelHeight, width: textWidth, height: hintHeight)
        var x = width - keysWidth
        for (view, partWidth, partHeight) in parts {
            view.frame = NSRect(
                x: x, y: top + ((lineHeight - partHeight) / 2).rounded(), width: partWidth, height: partHeight)
            x += partWidth + SettingsMetrics.slotGap
        }
        for (index, clear) in clearButtons.enumerated() {
            let slot = slots[index].frame
            let size = CGFloat(ClearButton.size)
            clear.frame = NSRect(
                x: slot.maxX + SettingsMetrics.slotClearOffset - size, y: slot.minY - SettingsMetrics.slotClearOffset,
                width: size, height: size)
        }
        var height = top + lineHeight
        if let noteText {
            height += SettingsMetrics.noteMarginTop
            var actionsWidth: CGFloat = 0
            let buttons = [reassignButton, cancelButton].compactMap { $0 }
            if !buttons.isEmpty {
                actionsWidth =
                    buttons.reduce(0) { $0 + $1.smallWidth } + CGFloat(buttons.count - 1)
                    * SettingsMetrics.noteButtonGap
            }
            let textRoom = width - (actionsWidth > 0 ? actionsWidth + SettingsMetrics.noteGap : 0)
            let textWidth = min(textRoom, noteText.naturalWidth)
            let textHeight = noteText.height(forWidth: textWidth)
            let buttonHeight = CGFloat(DesignTokens.controlHeights.small)
            let rowHeight = max(textHeight, buttons.isEmpty ? 0 : buttonHeight)
            var x = width - actionsWidth
            for button in buttons {
                button.frame = NSRect(
                    x: x, y: height + ((rowHeight - buttonHeight) / 2).rounded(), width: button.smallWidth,
                    height: buttonHeight)
                x += button.smallWidth + SettingsMetrics.noteButtonGap
            }
            let textRight = width - (actionsWidth > 0 ? actionsWidth + SettingsMetrics.noteGap : 0)
            // Centred on the buttons as flex centres it, unrounded (15.4 on 22 is 3.3 down).
            noteText.frame = NSRect(
                x: textRight - textWidth, y: height + (rowHeight - textHeight) / 2, width: textWidth,
                height: textHeight)
            height += rowHeight
        }
        return height + padding
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsTopLine else { return }
        NSColor(theme.palette.settingsSeparator).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: SettingsMetrics.separatorWidth).fill()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// A key of a Standard command: written, with no button (`.shortcut-slot-key.fixed`).
final class ShortcutFixedKey: TextControl {
    private static var font: NSFont { ThemeFonts.sans(DesignTokens.typeScale.callout) }

    init(shortcut: String, theme: Theme) {
        super.init(text: ShortcutLabels.format(shortcut), theme: theme)
        font = Self.font
        alignment = .center
        textColor = NSColor(theme.palette.textTertiary)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(stringValue)
        setAccessibilityIdentifier("settings.shortcuts.fixedKey")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredWidth: CGFloat {
        max(
            SettingsMetrics.slotMinWidth,
            SettingsGlyph.textWidth(stringValue, Self.font) + 2 * SettingsMetrics.slotPadding
                + 2 * SettingsMetrics.slotBorder)
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        textColor = NSColor(theme.palette.textTertiary)
    }
}

/// A group of commands: its title over a card of rows; the Standard group starts with its note.
final class ShortcutGroupView: ThemedView, SettingsBlock {
    let group: ShortcutGroup
    let titleText: ThemedText
    let card = ThemedView()
    let edge = SettingsCardEdge()
    let groupNote: ThemedText?
    private(set) var rows: [ShortcutRowView] = []

    init(group: ShortcutGroup, rows: [ShortcutRowView], theme: Theme) {
        self.group = group
        self.rows = rows
        titleText = ThemedText(ShortcutSettingsText.groupTitle(group), style: SettingsStyle.sectionTitle)
        groupNote =
            group == .standard
            ? ThemedText(ShortcutSettingsText.standardGroupNote, style: ShortcutSettingsView.hintStyle, wrapping: true)
            : nil
        super.init(theme: theme)
        card.fill = { $0.palette.settingsCardBg }
        card.cornerRadius = SettingsMetrics.cardRadius
        card.wantsLayer = true
        card.layer?.cornerRadius = SettingsMetrics.cardRadius
        card.layer?.masksToBounds = false
        titleText.setAccessibilityIdentifier("settings.sectionTitle")
        groupNote?.setAccessibilityIdentifier("settings.shortcuts.groupNote")
        setAccessibilityIdentifier("settings.group")
        addSubview(titleText)
        addSubview(card)
        if let groupNote { card.addSubview(groupNote) }
        for row in rows { card.addSubview(row) }
        card.addSubview(edge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func arrange(width: CGFloat) -> CGFloat {
        let side = SettingsMetrics.sectionHeaderPaddingSide
        let titleHeight = titleText.height(forWidth: width - 2 * side)
        let header = max(
            SettingsMetrics.sectionHeaderMinHeight, titleHeight + SettingsMetrics.sectionHeaderPaddingBottom)
        titleText.frame = NSRect(
            x: side, y: ((header - SettingsMetrics.sectionHeaderPaddingBottom - titleHeight) / 2).rounded(),
            width: titleText.naturalWidth, height: titleHeight)
        let inner = width - 2 * SettingsMetrics.cardPadding
        var y: CGFloat = 0
        if let groupNote {
            y += SettingsMetrics.groupNoteMargin
            let height = groupNote.height(forWidth: inner)
            groupNote.frame = NSRect(x: SettingsMetrics.cardPadding, y: y, width: inner, height: height)
            y += height + SettingsMetrics.groupNoteMargin
        }
        for (index, row) in rows.enumerated() {
            // `.shortcut-row:first-child` has no line; after the group's note the first row isn't the first child.
            row.drawsTopLine = index > 0 || groupNote != nil
            let height = row.arrange(width: inner)
            row.frame = NSRect(x: SettingsMetrics.cardPadding, y: y, width: inner, height: height)
            y += height
        }
        card.frame = NSRect(x: 0, y: header, width: width, height: y)
        edge.frame = card.bounds
        return header + y
    }
}

/// Settings › Shortcuts: every command with its keys. Click a key and press the new one; Esc cancels and ⌫ removes the
/// key. Each change is saved as it is made.
final class ShortcutSettingsView: ThemedView, SettingsBlock {
    private(set) var model: ShortcutSettingsModel
    private(set) var returnKeyAction: ReturnKeyAction
    let searchField: ThemedSearchField
    private let intro: ThemedText
    private var empty: ThemedText?
    private(set) var groups: [ShortcutGroupView] = []
    let restoreAllButton: SystemButton
    /// Saves the overrides.
    var onChange: (ShortcutOverrides) -> Void = { _ in }
    /// The page's height changed (a note came or went, the search changed the rows).
    var onLayoutChange: () -> Void = {}
    private var shownCommands: [ShortcutCommandID] = []

    static var hintStyle: TextStyle {
        SettingsStyle.style(DesignTokens.typeScale.small, lineHeight: SettingsMetrics.noteLineHeight) {
            $0.palette.textSecondary
        }
    }

    static func noteStyle(refused: Bool) -> TextStyle {
        SettingsStyle.style(DesignTokens.typeScale.small, lineHeight: SettingsMetrics.noteLineHeight) {
            refused ? $0.palette.dangerText : $0.palette.textSecondary
        }
    }

    init(overrides: ShortcutOverrides, returnKeyAction: ReturnKeyAction, theme: Theme) {
        model = ShortcutSettingsModel(overrides: overrides)
        self.returnKeyAction = returnKeyAction
        searchField = ThemedSearchField(placeholder: ShortcutSettingsText.searchPlaceholder, theme: theme)
        intro = ThemedText(
            ShortcutSettingsText.intro,
            style: SettingsStyle.style(DesignTokens.typeScale.small) { $0.palette.textSecondary }, wrapping: true)
        restoreAllButton = SystemButton(title: "Restore Defaults", theme: theme)
        super.init(theme: theme)
        searchField.setAccessibilityIdentifier("settings.shortcuts.search")
        searchField.input.setAccessibilityLabel("Search shortcuts")
        searchField.onChange = { [weak self] text in self?.search(text) }
        intro.setAccessibilityIdentifier("settings.shortcuts.intro")
        restoreAllButton.setAccessibilityLabel("Restore Default Shortcuts")
        restoreAllButton.target = self
        restoreAllButton.action = #selector(restoreAllPressed(_:))
        setAccessibilityIdentifier("settings.shortcuts")
        addSubview(intro)
        addSubview(restoreAllButton)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Rows

    private func rebuild() {
        for group in groups { group.removeFromSuperview() }
        empty?.removeFromSuperview()
        empty = nil
        let found = model.groups
        groups = found.map { entry in
            let rows = entry.commands.map { command in
                ShortcutRowView(
                    command: command,
                    hint: ShortcutSettingsText.hint(command.id, returnKeyAction: returnKeyAction), owner: self,
                    theme: theme)
            }
            return ShortcutGroupView(group: entry.group, rows: rows, theme: theme)
        }
        shownCommands = found.flatMap { $0.commands.map(\.id) }
        if found.isEmpty {
            let text = ThemedText(
                ShortcutSettingsText.noMatch(model.query),
                style: SettingsStyle.style(DesignTokens.typeScale.callout) { $0.palette.textSecondary }, wrapping: true)
            text.setAccessibilityIdentifier("settings.shortcuts.empty")
            addSubview(text)
            empty = text
        }
        for group in groups { addSubview(group) }
        refreshRows()
    }

    /// Every row shows the model as it is now.
    private func refreshRows() {
        for group in groups { for row in group.rows { row.update(model: model) } }
        restoreAllButton.isEnabled = model.anyCustomized
        if let slot = model.recording, let view = slotView(slot), window?.firstResponder !== view {
            window?.makeFirstResponder(view)
        }
        onLayoutChange()
    }

    /// The model changed: the rows follow; a search by keys may show other rows now.
    private func modelChanged() {
        let ids = model.groups.flatMap { $0.commands.map(\.id) }
        if ids != shownCommands { rebuild() } else { refreshRows() }
    }

    var rows: [ShortcutRowView] { groups.flatMap(\.rows) }

    func row(_ id: ShortcutCommandID) -> ShortcutRowView? { rows.first { $0.command.id == id } }

    func slotView(_ slot: ShortcutSlot) -> ShortcutSlotView? {
        row(slot.id)?.slots.first { $0.slot == slot }
    }

    /// The keys or the Return key setting changed elsewhere.
    func update(overrides: ShortcutOverrides, returnKeyAction: ReturnKeyAction) {
        let hintsChanged = returnKeyAction != self.returnKeyAction
        self.returnKeyAction = returnKeyAction
        let next = ShortcutCommands.resolve(overrides).bindings
        guard next != model.bindings || hintsChanged else { return }
        model.setOverrides(overrides)
        if hintsChanged { rebuild() } else { modelChanged() }
    }

    // MARK: What the rows ask

    private func save(_ overrides: ShortcutOverrides?) {
        modelChanged()
        if let overrides { onChange(overrides) }
    }

    func slotClicked(_ slot: ShortcutSlotView) {
        model.record(slot.isRecording ? nil : slot.slot)
        modelChanged()
    }

    func slotLeft(_ slot: ShortcutSlotView) {
        guard model.recording == slot.slot else { return }
        model.record(nil)
        modelChanged()
    }

    func recorderPressed(_ slot: ShortcutSlot, _ pressed: String?) {
        switch model.recorderAction(pressed, slot: slot) {
        case nil: return
        case .cancel:
            model.record(nil)
            save(nil)
        case .remove: save(model.remove(slot))
        case .press(let shortcut): save(model.press(slot, shortcut))
        }
    }

    func removeKey(_ slot: ShortcutSlot) { save(model.remove(slot)) }

    func resetCommand(_ id: ShortcutCommandID) { save(model.reset(id)) }

    func reassign(_ slot: ShortcutSlot, _ shortcut: String) { save(model.give(slot, shortcut)) }

    func dismissNote() {
        model.note = nil
        save(nil)
    }

    @objc private func restoreAllPressed(_ sender: Any?) { save(model.resetAll()) }

    // MARK: Search

    private func search(_ text: String) {
        model.query = text
        rebuild()
    }

    /// Types into the search field, as typing does.
    func setQuery(_ text: String) {
        searchField.text = text
        search(text)
    }

    // MARK: Layout

    func arrange(width: CGFloat) -> CGFloat {
        let side = SettingsMetrics.introMarginSide
        let introHeight = intro.height(forWidth: width - 2 * side)
        intro.frame = NSRect(x: side, y: 0, width: width - 2 * side, height: introHeight)
        var y = introHeight + SettingsMetrics.introMarginBottom
        if let empty {
            let height = empty.height(forWidth: width - 2 * side)
            empty.frame = NSRect(x: side, y: y, width: width - 2 * side, height: height)
            y += height + SettingsMetrics.introMarginBottom
        }
        for group in groups {
            let height = group.arrange(width: width)
            group.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + SettingsMetrics.sectionGap
        }
        // The footer's 10 above collapses into the 20 under the last group (or the 12 under the text).
        let size = restoreAllButton.intrinsicContentSize
        restoreAllButton.frame = NSRect(x: width - size.width, y: y, width: size.width, height: size.height)
        return y + size.height
    }
}
