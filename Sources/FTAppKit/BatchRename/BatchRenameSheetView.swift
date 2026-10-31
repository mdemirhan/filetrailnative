// Port of BatchRenameSheet, ReplaceOptions, AddOptions, FormatOptions and CaseOptions of
// apps/desktop/src/renderer/components/BatchRenameSheet.tsx, as styles.css lays them out (6696-7170)
import AppKit
import FTFoundation
import FTOperations

/// The Rename sheet for several items: Finder's Replace Text, Add Text, Format and Change Case, with every item's new
/// name shown before anything is renamed, and names that can't be used held back or settled as the person chooses.
@MainActor
final class BatchRenameSheetView: NSView, DialogPanel, ThemeApplying {
    let model: BatchRenameSheetModel
    /// Cancel, Escape: the sheet closes (the presenter closes the model).
    var onCancel: () -> Void = {}
    /// Rename, with the request the plan settled.
    var onRename: (BatchRenameRequest) -> Void = { _ in }

    // Header
    let titleLabel: ThemedText
    let presetsPopUp = BatchRenamePopUp(label: "Presets", identifier: "batchRename.presets", pullsDown: true)
    let presetNameField = BatchRenameTextField(
        label: "Preset name", identifier: "batchRename.presetName", limit: BatchRenamePresetMenu.maxNameLength)
    let presetCancelButton = SystemButton(title: "Cancel")
    let presetSaveButton = SystemButton(title: "Save")
    // Modes
    let modeControl = BatchRenameModeControl()
    // Replace Text
    let findField = BatchRenameTextField(label: "Find", limit: BatchRenameTextRules.maxLength)
    let replaceField = BatchRenameTextField(label: "Replace with", limit: BatchRenameTextRules.maxLength)
    let findMessage = ThemedText(wrapping: true) { _ in NSAttributedString() }
    let regexHint: ThemedText
    let matchCaseCheck = BatchRenameCheckbox(title: "Match case")
    let regexCheck = BatchRenameCheckbox(title: "Regular expression")
    // Add Text
    let addTextField = BatchRenameTextField(label: "Text", limit: BatchRenameTextRules.maxLength)
    let addWherePopUp = BatchRenamePopUp(label: "Where")
    // Format
    let nameFormatPopUp = BatchRenamePopUp(label: "Name format")
    let formatWherePopUp = BatchRenamePopUp(label: "Where")
    let customNameField = BatchRenameTextField(label: "Custom format", limit: BatchRenameTextRules.maxLength)
    let keepNamesCheck = BatchRenameCheckbox(title: "Keep current names")
    let dateSourcePopUp = BatchRenamePopUp(label: "Date")
    let separatorPopUp = BatchRenamePopUp(label: "Separator")
    let dateFormatPopUp = BatchRenamePopUp(label: "Date format")
    let dateSeparatorPopUp = BatchRenamePopUp(label: "Date separator")
    let patternField = BatchRenameTextField(label: "Pattern", limit: BatchRenameTextRules.maxLength)
    let insertNote: ThemedText
    let tokenButtons = BatchRenameSheetText.tokens.map { BatchRenameTokenButton(token: $0) }
    let bracketsNote: ThemedText
    let exampleNote = ThemedText(wrapping: false) { _ in NSAttributedString() }
    let startField = BatchRenameTextField(
        label: "Start numbers at", number: true, limit: BatchRenameNumberDraft.maxDigits)
    let stepField = BatchRenameTextField(label: "Step", number: true, limit: BatchRenameNumberDraft.maxDigits)
    let digitsPopUp = BatchRenamePopUp(label: "Digits")
    // Change Case
    let casePopUp = BatchRenamePopUp(label: "Change to")
    // Every mode
    let applyToPopUp = BatchRenamePopUp(label: "Apply to")
    let namesOnlyNote: ThemedText
    let onConflictPopUp = BatchRenamePopUp(label: "If a name is taken")
    let advice = NSView()
    let adviceGlyph = BatchRenameGlyphView(.warning, identifier: "batchRename.warning")
    let adviceText: ThemedText
    // Preview and footer
    /// The header's box (`.batch-rename-header`), for the captures; it draws nothing.
    let headerBox = NSView()
    let preview = BatchRenamePreviewView()
    let footerLine = BatchRenameFooterLine()
    let summaryLabel = ThemedText(wrapping: false) { _ in NSAttributedString() }
    let cancelButton = SystemButton(title: "Cancel")
    let renameButton = SystemButton(title: "Rename")

    /// The labels before the controls, by their words.
    private(set) var labels: [String: ThemedText] = [:]
    /// Whether a preset name is being typed in the header.
    private(set) var savingPreset = false
    private(set) var presetMenu = BatchRenamePresetMenu(presets: [], currentName: nil)
    private var startDraft = BatchRenameNumberDraft(value: 1)
    private var stepDraft = BatchRenameNumberDraft(value: 1)
    private var shownCells: [BatchRenameGridCell] = []
    private var theme = AppearanceModel.shared.theme
    private var rendering = false

    init(model: BatchRenameSheetModel) {
        self.model = model
        let count = model.sheet?.targets.count ?? 0
        var titleStyle = batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textPrimary }, weight: .bold)
        titleStyle.background = { $0.palette.bgElevated }
        titleLabel = ThemedText(BatchRenameSheetText.title(count: count), style: titleStyle)
        let small = BatchRenameSheetLayout.Fonts.small
        regexHint = ThemedText(
            BatchRenameSheetText.regexHint, style: batchRenameStyle(small, { $0.palette.textSecondary }), wrapping: true
        )
        insertNote = ThemedText(
            BatchRenameSheetText.insertLabel, style: batchRenameStyle(small, { $0.palette.textSecondary }))
        bracketsNote = ThemedText(
            BatchRenameSheetText.bracketsNote, style: batchRenameStyle(small, { $0.palette.textSecondary }))
        namesOnlyNote = ThemedText(
            BatchRenameSheetText.namesOnlyNote,
            style: batchRenameStyle(
                small, { $0.palette.textSecondary }, lineHeight: BatchRenameSheetLayout.controlHeight))
        adviceText = ThemedText(
            BatchRenameSheetText.extensionAdvice, style: batchRenameStyle(small, { $0.palette.textSecondary }))
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityIdentifier("batchRename")
        wantsLayer = true
        build()
        model.onChange = { [weak self] in self?.render() }
        applyTheme(theme)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Building

    private func label(_ text: String) -> ThemedText {
        if let made = labels[text] { return made }
        let made = ThemedText(
            text,
            style: batchRenameStyle(
                BatchRenameSheetLayout.Fonts.body, { $0.palette.textSecondary },
                lineHeight: BatchRenameSheetLayout.controlHeight, alignment: .right))
        made.setAccessibilityIdentifier("batchRename.label")
        made.isHidden = true
        addSubview(made)
        labels[text] = made
        return made
    }

    private func build() {
        titleLabel.setAccessibilityIdentifier("batchRename.title")
        headerBox.setAccessibilityIdentifier("batchRename.header")
        footerLine.setAccessibilityIdentifier("batchRename.footer")
        presetCancelButton.setAccessibilityIdentifier("batchRename.presetCancel")
        presetSaveButton.setAccessibilityIdentifier("batchRename.presetSave")
        presetSaveButton.isDefault = true
        findMessage.setAccessibilityIdentifier("batchRename.message")
        regexHint.setAccessibilityIdentifier("batchRename.message")
        insertNote.setAccessibilityIdentifier("batchRename.optionNote")
        bracketsNote.setAccessibilityIdentifier("batchRename.optionNote")
        exampleNote.setAccessibilityIdentifier("batchRename.optionNote")
        namesOnlyNote.setAccessibilityIdentifier("batchRename.optionNote")
        advice.setAccessibilityIdentifier("batchRename.advice")
        adviceText.setAccessibilityIdentifier("batchRename.advice.text")
        summaryLabel.setAccessibilityIdentifier("batchRename.summary")
        summaryLabel.setAccessibilityRole(.staticText)
        cancelButton.setAccessibilityIdentifier("batchRename.cancel")
        renameButton.setAccessibilityIdentifier("batchRename.rename")
        renameButton.isDefault = true
        presetNameField.field.placeholderString = "Preset name"
        advice.addSubview(adviceGlyph)
        advice.addSubview(adviceText)
        let views: [NSView] =
            [
                headerBox, titleLabel, presetsPopUp, presetNameField, presetCancelButton, presetSaveButton, modeControl,
                findField,
                replaceField, findMessage, regexHint, matchCaseCheck, regexCheck, addTextField, addWherePopUp,
                nameFormatPopUp, formatWherePopUp, customNameField, keepNamesCheck, dateSourcePopUp, separatorPopUp,
                dateFormatPopUp, dateSeparatorPopUp, patternField, insertNote, bracketsNote, exampleNote, startField,
                stepField, digitsPopUp, casePopUp, applyToPopUp, namesOnlyNote, onConflictPopUp, advice, preview,
                footerLine, summaryLabel, cancelButton, renameButton,
            ] + tokenButtons
        for view in views { addSubview(view) }
        wire()
    }

    private func set(_ change: (inout BatchRenameSettings) -> Void) {
        var next = model.settings
        change(&next)
        model.setSettings(next)
    }

    private func wire() {
        presetsPopUp.onChoose = { [weak self] index in self?.choosePreset(index) }
        presetNameField.onChange = { [weak self] _ in self?.render() }
        presetCancelButton.target = self
        presetCancelButton.action = #selector(presetCancelPressed(_:))
        presetSaveButton.target = self
        presetSaveButton.action = #selector(presetSavePressed(_:))
        modeControl.onChoose = { [weak self] mode in self?.set { $0.mode = mode } }
        findField.onChange = { [weak self] text in self?.set { $0.find = text } }
        replaceField.onChange = { [weak self] text in self?.set { $0.replaceWith = text } }
        matchCaseCheck.onToggle = { [weak self] on in self?.set { $0.matchCase = on } }
        regexCheck.onToggle = { [weak self] on in self?.set { $0.useRegex = on } }
        addTextField.onChange = { [weak self] text in self?.set { $0.addText = text } }
        addWherePopUp.onChoose = { [weak self] index in
            self?.set { $0.addWhere = BatchRenameSheetText.whereChoices[index].value }
        }
        nameFormatPopUp.onChoose = { [weak self] index in
            self?.set { $0.nameFormat = BatchRenameSheetText.nameFormatChoices[index].value }
        }
        formatWherePopUp.onChoose = { [weak self] index in
            self?.set { $0.formatWhere = BatchRenameSheetText.whereChoices[index].value }
        }
        customNameField.onChange = { [weak self] text in self?.set { $0.customName = text } }
        keepNamesCheck.onToggle = { [weak self] on in self?.set { $0.keepNames = on } }
        dateSourcePopUp.onChoose = { [weak self] index in
            self?.set { $0.dateSource = BatchRenameSheetText.dateSourceChoices[index].value }
        }
        separatorPopUp.onChoose = { [weak self] index in
            self?.set { $0.separator = BatchRenameSheetText.separatorChoices[index].value }
        }
        dateFormatPopUp.onChoose = { [weak self] index in
            guard let self else { return }
            let choices = BatchRenameSheetText.dateFormatChoices(separator: self.model.settings.dateSeparator)
            self.set { $0.dateFormat = choices[index].value }
        }
        dateSeparatorPopUp.onChoose = { [weak self] index in
            self?.set { $0.dateSeparator = BatchRenameSheetText.dateSeparatorChoices[index].value }
        }
        patternField.onChange = { [weak self] text in self?.set { $0.customDatePattern = text } }
        for button in tokenButtons {
            button.target = self
            button.action = #selector(tokenPressed(_:))
        }
        startField.onChange = { [weak self] text in self?.typedNumber(text, step: false) }
        stepField.onChange = { [weak self] text in self?.typedNumber(text, step: true) }
        startField.onBlur = { [weak self] in
            guard let self else { return }
            self.startDraft.blurred(value: self.model.settings.startAt)
            self.render()
        }
        stepField.onBlur = { [weak self] in
            guard let self else { return }
            self.stepDraft.blurred(value: self.model.settings.step)
            self.render()
        }
        digitsPopUp.onChoose = { [weak self] index in
            self?.set { $0.digits = BatchRenameSheetText.digitsChoices[index].value }
        }
        casePopUp.onChoose = { [weak self] index in
            self?.set { $0.caseStyle = BatchRenameSheetText.caseChoices[index].value }
        }
        applyToPopUp.onChoose = { [weak self] index in
            self?.set { $0.applyTo = BatchRenameSheetText.applyToChoices[index].value }
        }
        onConflictPopUp.onChoose = { [weak self] index in
            self?.set { $0.onConflict = BatchRenameSheetText.onConflictChoices[index].value }
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        renameButton.target = self
        renameButton.action = #selector(renamePressed(_:))
    }

    // MARK: Numbers

    /// `NumberField`: the digits typed are kept as typed; the setting takes the nearest whole number allowed.
    func typedNumber(_ text: String, step: Bool) {
        if step {
            if let value = stepDraft.typed(text, least: 1) { set { $0.step = value } }
        } else {
            if let value = startDraft.typed(text, least: 0) { set { $0.startAt = value } }
        }
        render()
    }

    // MARK: Presets

    /// A choice of the Presets pull-down (its index among the items under the title).
    func choosePreset(_ index: Int) {
        let items = presetMenu.items
        guard items.indices.contains(index) else { return }
        switch presetMenu.choose(items[index]) {
        case .load(let preset):
            model.setSettings(preset.settings)
        case .startNaming(let name):
            savingPreset = true
            presetNameField.text = name
            render()
            presetNameField.focus(caret: (name as NSString).length)
        case .update(let name):
            model.savePreset(name)
        case .delete(let name):
            model.deletePreset(name)
        case .none:
            break
        }
        render()
    }

    /// Choosing an item of the pull-down by its words, as a person does (`pick`).
    func choosePreset(titled title: String) {
        guard let index = presetMenu.items.firstIndex(where: { $0.title == title && $0 != .separator }) else { return }
        choosePreset(index)
    }

    /// `savePreset`: the typed name trimmed (a blank one does nothing) is saved and becomes the current preset; the
    /// keyboard goes back to the pull-down.
    func savePreset() {
        guard let name = presetMenu.named(presetNameField.text) else { return }
        model.savePreset(name)
        stopSavingPreset()
    }

    /// Back from naming a preset, the keyboard goes to the Presets pull-down the name was asked from.
    func stopSavingPreset() {
        savingPreset = false
        render()
        window?.makeFirstResponder(presetsPopUp)
    }

    @objc private func presetCancelPressed(_ sender: Any?) { stopSavingPreset() }
    @objc private func presetSavePressed(_ sender: Any?) { savePreset() }

    // MARK: Tokens

    @objc private func tokenPressed(_ sender: Any?) {
        guard let button = sender as? BatchRenameTokenButton else { return }
        insertToken(button.token)
    }

    /// `insertToken`: the token goes where the pattern's selection is (its end if it was never edited), the keyboard
    /// back in the field with the caret after it.
    func insertToken(_ token: BatchRenameDateToken) {
        let inserted = BatchRenameTextRules.insert(
            token.rawValue, into: model.settings.customDatePattern, selection: patternField.selection)
        set { $0.customDatePattern = inserted.text }
        patternField.focus(caret: inserted.caret)
        patternField.lastSelection = inserted.caret..<inserted.caret
    }

    // MARK: Buttons

    @objc private func cancelPressed(_ sender: Any?) { onCancel() }

    @objc private func renamePressed(_ sender: Any?) { submit() }

    /// The form's submit (Return in a field, the default button): saves the preset while one is named, else renames
    /// when that is allowed.
    func submit() {
        if savingPreset {
            savePreset()
        } else if let request = model.request {
            onRename(request)
        }
    }

    // MARK: Keys

    var initialResponder: NSView? { firstField?.field ?? self }

    /// `useBatchRename.open` reads the preferences before the sheet comes, and in that gap no dialog suppresses the focus
    /// restore (`restoreExplorerPaneFocus`), which sets the content focused again: unlike under the other dialogs, the
    /// list keeps the accent (the original's capture of 240).
    var keepsPaneFocus: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    /// The mode's first field: Find, Text or Custom format (none for Change Case).
    var firstField: BatchRenameTextField? {
        switch model.settings.mode {
        case .replace: findField
        case .add: addTextField
        case .format: customNameField.isEnabled ? customNameField : nil
        case .changeCase: nil
        }
    }

    /// Opens with the keyboard in the mode's first field, else in the sheet.
    func takeKeyboard() {
        if let field = firstField {
            field.focus(caret: (field.text as NSString).length)
        } else {
            window?.makeFirstResponder(focusChain.first)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == KeyCode.escape, modifiers.isEmpty {
            if savingPreset { stopSavingPreset() } else { onCancel() }
            return true
        }
        if event.keyCode == KeyCode.tab, modifiers.isSubset(of: [.shift]) {
            cycleFocus(backward: modifiers.contains(.shift))
            return true
        }
        guard KeyCode.isReturn(event), modifiers.isSubset(of: [.shift]) else { return false }
        let responder = focusedControl
        if let button = responder as? TextControl, button.isDescendant(of: self) {
            button.perform()
            return true
        }
        if let button = responder as? SystemButton, button.isDescendant(of: self) {
            button.perform()
            return true
        }
        if responder is BatchRenameTextField || responder is BatchRenameCheckbox || responder is BatchRenameModeControl
        {
            submit()
            return true
        }
        return false
    }

    /// The control of the sheet that has the keyboard (a field, for its field editor).
    var focusedControl: NSView? {
        guard let window else { return nil }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            let delegate: AnyObject? = editor.delegate
            if let field = delegate as? BatchRenameEditField { return field.superview }
        }
        if let field = window.firstResponder as? BatchRenameEditField { return field.superview }
        return window.firstResponder as? NSView
    }

    /// What Tab goes through, in the order the sheet shows it: the header, the mode, the options, the list of new
    /// names and the footer's buttons.
    var focusChain: [NSView] {
        var chain: [NSView] = []
        if savingPreset {
            chain += [presetNameField, presetCancelButton]
            if presetSaveButton.isEnabled { chain.append(presetSaveButton) }
        } else {
            chain.append(presetsPopUp)
        }
        chain.append(modeControl)
        for cell in shownCells {
            guard let view = cell.view, !view.isHidden else { continue }
            if let field = view as? BatchRenameTextField {
                if field.isEnabled { chain.append(field) }
            } else if view is BatchRenamePopUp || view is BatchRenameCheckbox {
                chain.append(view)
            } else if view === patternBlock {
                chain.append(patternField)
                chain += tokenButtons
            } else if view === checksRow {
                chain += [matchCaseCheck, regexCheck]
            }
        }
        chain.append(preview.table)
        chain.append(cancelButton)
        if renameButton.isEnabled { chain.append(renameButton) }
        return chain
    }

    func cycleFocus(backward: Bool) {
        let chain = focusChain
        guard !chain.isEmpty else { return }
        let current = focusedControl
        let index = chain.firstIndex { $0 === current }
        let next: Int =
            if backward {
                index.map { $0 == 0 ? chain.count - 1 : $0 - 1 } ?? chain.count - 1
            } else {
                index.map { $0 == chain.count - 1 ? 0 : $0 + 1 } ?? 0
            }
        let target = chain[next]
        if let field = target as? BatchRenameTextField {
            field.focus()
            field.field.currentEditor()?.selectAll(nil)
        } else {
            window?.makeFirstResponder(target)
        }
    }

    // MARK: Showing

    /// The pattern field with its tokens, and the checkboxes of Replace Text: stand-ins for their grid cells.
    let patternBlock = NSView()
    let checksRow = NSView()

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let palette = theme.palette
        layer?.backgroundColor = NSColor(palette.bgElevated).cgColor
        layer?.cornerRadius = CGFloat(BatchRenameSheetLayout.radius)
        // --elevation-dialog: the 0.5 edge; DialogScrim draws the drops under the panel.
        if let edge = palette.elevationDialog.first(where: { $0.blur == 0 && $0.spread > 0 }) {
            layer?.borderWidth = CGFloat(edge.spread)
            layer?.borderColor = NSColor(edge.color).cgColor
        }
        for button in [presetCancelButton, presetSaveButton, cancelButton, renameButton] { button.applyTheme(theme) }
    }

    /// Shows the model: the title, presets, mode, options, preview, summary and what the buttons allow.
    func render() {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        let settings = model.settings
        let small = BatchRenameSheetLayout.Fonts.small
        presetMenu.presets = model.presets
        titleLabel.content = { [count = model.sheet?.targets.count ?? 0] theme in
            var style = batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textPrimary }, weight: .bold)
            style.background = { $0.palette.bgElevated }
            return style.string(BatchRenameSheetText.title(count: count), theme)
        }
        setAccessibilityLabel(titleLabel.stringValue)
        // Header
        presetsPopUp.isHidden = savingPreset
        presetsPopUp.setMenu(
            title: presetMenu.closedTitle(settings),
            items: presetMenu.items.map { $0 == .separator ? nil : $0.title })
        for view in [presetNameField, presetCancelButton, presetSaveButton] as [NSView] {
            view.isHidden = !savingPreset
        }
        presetSaveButton.title = presetMenu.saveTitle(presetNameField.text)
        presetSaveButton.isEnabled = BatchRenamePresetMenu.canSave(presetNameField.text)
        // Mode and options
        modeControl.select(settings.mode)
        findField.text = settings.find
        replaceField.text = settings.replaceWith
        let plan = model.plan
        let findError =
            settings.mode == .replace ? plan?.settingsError.map(BatchRenameSheetText.describeSettingsError) : nil
        findField.isInvalid = findError != nil
        findField.field.setAccessibilityHelp(findError)
        findMessage.content = { theme in
            batchRenameStyle(small, { $0.palette.dangerText }).string(findError ?? "", theme)
        }
        matchCaseCheck.setChecked(settings.matchCase)
        regexCheck.setChecked(settings.useRegex)
        addTextField.text = settings.addText
        addWherePopUp.setChoices(
            BatchRenameSheetText.whereChoices.map(\.title),
            selected: BatchRenameSheetText.whereChoices.firstIndex { $0.value == settings.addWhere } ?? 0)
        nameFormatPopUp.setChoices(
            BatchRenameSheetText.nameFormatChoices.map(\.title),
            selected: BatchRenameSheetText.nameFormatChoices.firstIndex { $0.value == settings.nameFormat } ?? 0)
        formatWherePopUp.setChoices(
            BatchRenameSheetText.whereChoices.map(\.title),
            selected: BatchRenameSheetText.whereChoices.firstIndex { $0.value == settings.formatWhere } ?? 0)
        customNameField.text = settings.customName
        customNameField.isEnabled = !settings.keepNames
        keepNamesCheck.setChecked(settings.keepNames)
        dateSourcePopUp.setChoices(
            BatchRenameSheetText.dateSourceChoices.map(\.title),
            selected: BatchRenameSheetText.dateSourceChoices.firstIndex { $0.value == settings.dateSource } ?? 0)
        separatorPopUp.setChoices(
            BatchRenameSheetText.separatorChoices.map(\.title),
            selected: BatchRenameSheetText.separatorChoices.firstIndex { $0.value == settings.separator } ?? 0)
        let dateFormats = BatchRenameSheetText.dateFormatChoices(separator: settings.dateSeparator)
        dateFormatPopUp.setChoices(
            dateFormats.map(\.title), selected: dateFormats.firstIndex { $0.value == settings.dateFormat } ?? 0)
        dateSeparatorPopUp.setChoices(
            BatchRenameSheetText.dateSeparatorChoices.map(\.title),
            selected: BatchRenameSheetText.dateSeparatorChoices.firstIndex { $0.value == settings.dateSeparator } ?? 0)
        patternField.text = settings.customDatePattern
        exampleNote.content = { theme in
            batchRenameStyle(small, { $0.palette.textSecondary }).string(BatchRenameSheetText.example(settings), theme)
        }
        let numbersShown = settings.mode == .format && settings.nameFormat != .date
        if !numbersShown {
            startDraft = BatchRenameNumberDraft(value: settings.startAt)
            stepDraft = BatchRenameNumberDraft(value: settings.step)
        }
        startField.text = startDraft.shown(value: settings.startAt)
        stepField.text = stepDraft.shown(value: settings.step)
        digitsPopUp.setChoices(
            BatchRenameSheetText.digitsChoices.map(\.title),
            selected: BatchRenameSheetText.digitsChoices.firstIndex { $0.value == settings.digits } ?? 0)
        casePopUp.setChoices(
            BatchRenameSheetText.caseChoices.map(\.title),
            selected: BatchRenameSheetText.caseChoices.firstIndex { $0.value == settings.caseStyle } ?? 0)
        applyToPopUp.setChoices(
            BatchRenameSheetText.applyToChoices.map(\.title),
            selected: BatchRenameSheetText.applyToChoices.firstIndex { $0.value == settings.applyTo } ?? 0)
        onConflictPopUp.setChoices(
            BatchRenameSheetText.onConflictChoices.map(\.title),
            selected: BatchRenameSheetText.onConflictChoices.firstIndex { $0.value == settings.onConflict } ?? 0)
        // Preview and footer
        if let sheet = model.sheet, let plan {
            preview.setRows(BatchRenamePreviewRow.rows(targets: sheet.targets, plan: plan))
            let summary = BatchRenameSheetText.summary(
                plan: plan, checking: model.checking, checkError: sheet.inspectError)
            summaryLabel.content = { theme in
                batchRenameStyle(
                    BatchRenameSheetLayout.Fonts.summary,
                    { summary.danger ? $0.palette.dangerText : $0.palette.textSecondary }
                ).string(summary.text, theme)
            }
            renameButton.title = BatchRenameSheetText.renameButton(
                renameCount: plan.renameCount, canRename: model.canRename)
        }
        preview.table.setAccessibilityValue(model.checking ? "busy" : nil)
        renameButton.isEnabled = model.canRename && !savingPreset
        needsLayout = true
        superview?.needsLayout = true
    }

    /// What the summary says.
    var summaryText: String { summaryLabel.stringValue }

    // MARK: Layout

    /// The grid rows of the mode's options and of the settings every mode has, as the sheet shows them now.
    func gridRows() -> (mode: [[BatchRenameGridCell]], common: [[BatchRenameGridCell]]) {
        let settings = model.settings
        let control = CGFloat(BatchRenameSheetLayout.controlHeight)
        func labelCell(_ text: String, column: Int, second: Bool = false) -> BatchRenameGridCell {
            BatchRenameGridCell(view: label(text), column: column, width: .label(second: second), height: control)
        }
        func controlCell(_ view: NSView, column: Int) -> BatchRenameGridCell {
            BatchRenameGridCell(view: view, column: column, height: control, alignStart: false)
        }
        func checkCell(_ check: BatchRenameCheckbox, column: Int) -> BatchRenameGridCell {
            BatchRenameGridCell(
                view: check, column: column, width: .fixed(check.preferredWidth),
                height: batchRenameLine(BatchRenameSheetLayout.Fonts.body), alignStart: false)
        }
        let columns = BatchRenameSheetLayout.Grid.columns(width: Double(optionsWidth))
        func spanWidth(from column: Int, span: Int) -> CGFloat {
            CGFloat(columns[column + span - 1].x + columns[column + span - 1].width - columns[column].x)
        }
        var mode: [[BatchRenameGridCell]] = []
        switch settings.mode {
        case .replace:
            mode.append([
                labelCell("Find", column: 0), controlCell(findField, column: 1),
                labelCell("Replace with", column: 2, second: true), controlCell(replaceField, column: 3),
            ])
            let findError = findField.isInvalid
            if findError || settings.useRegex {
                var row: [BatchRenameGridCell] = []
                let width = spanWidth(from: 1, span: 1)
                if findError {
                    row.append(
                        BatchRenameGridCell(
                            view: findMessage, column: 1, height: findMessage.height(forWidth: width),
                            marginTop: CGFloat(BatchRenameSheetLayout.Field.messageMarginTop)))
                }
                if settings.useRegex {
                    row.append(
                        BatchRenameGridCell(
                            view: regexHint, column: 3, height: regexHint.height(forWidth: width),
                            marginTop: CGFloat(BatchRenameSheetLayout.Field.messageMarginTop)))
                }
                mode.append(row)
            }
            mode.append([
                BatchRenameGridCell(
                    view: checksRow, column: 1, span: 3, height: batchRenameLine(BatchRenameSheetLayout.Fonts.body))
            ])
        case .add:
            mode.append([
                labelCell("Text", column: 0), controlCell(addTextField, column: 1),
                labelCell("Where", column: 2, second: true), controlCell(addWherePopUp, column: 3),
            ])
        case .format:
            mode.append([
                labelCell("Name format", column: 0), controlCell(nameFormatPopUp, column: 1),
                labelCell("Where", column: 2, second: true), controlCell(formatWherePopUp, column: 3),
            ])
            mode.append([
                labelCell("Custom format", column: 0), controlCell(customNameField, column: 1),
                checkCell(keepNamesCheck, column: 3),
            ])
            if settings.nameFormat == .date {
                let custom = settings.dateFormat == .custom
                mode.append([
                    labelCell("Date", column: 0), controlCell(dateSourcePopUp, column: 1),
                    labelCell("Separator", column: 2, second: true), controlCell(separatorPopUp, column: 3),
                ])
                var row = [labelCell("Date format", column: 0), controlCell(dateFormatPopUp, column: 1)]
                if !custom {
                    row += [
                        labelCell("Date separator", column: 2, second: true),
                        controlCell(dateSeparatorPopUp, column: 3),
                    ]
                }
                mode.append(row)
                if custom {
                    mode.append([
                        labelCell("Pattern", column: 0),
                        BatchRenameGridCell(
                            view: patternBlock, column: 1, span: 3,
                            height: patternHeight(width: spanWidth(from: 1, span: 3))),
                    ])
                    mode.append([
                        BatchRenameGridCell(
                            view: exampleNote, column: 1, span: 3,
                            height: batchRenameLine(BatchRenameSheetLayout.Fonts.small))
                    ])
                }
            } else {
                mode.append([
                    labelCell("Start numbers at", column: 0),
                    BatchRenameGridCell(
                        view: startField, column: 1, width: .fixed(CGFloat(BatchRenameSheetLayout.Field.numberWidth)),
                        height: control, alignStart: false),
                    labelCell("Step", column: 2, second: true),
                    BatchRenameGridCell(
                        view: stepField, column: 3, width: .fixed(CGFloat(BatchRenameSheetLayout.Field.numberWidth)),
                        height: control, alignStart: false),
                ])
                if settings.nameFormat == .counter {
                    mode.append([
                        labelCell("Digits", column: 0), controlCell(digitsPopUp, column: 1),
                        labelCell("Separator", column: 2, second: true), controlCell(separatorPopUp, column: 3),
                    ])
                } else {
                    mode.append([labelCell("Separator", column: 0), controlCell(separatorPopUp, column: 1)])
                }
            }
        case .changeCase:
            mode.append([labelCell("Change to", column: 0), controlCell(casePopUp, column: 1)])
        }
        var common: [[BatchRenameGridCell]] = []
        var first: [BatchRenameGridCell]
        if settings.mode == .format {
            first = [
                labelCell("Apply to", column: 0),
                BatchRenameGridCell(view: namesOnlyNote, column: 1, height: control),
            ]
        } else {
            first = [labelCell("Apply to", column: 0), controlCell(applyToPopUp, column: 1)]
        }
        first += [labelCell("If a name is taken", column: 2, second: true), controlCell(onConflictPopUp, column: 3)]
        common.append(first)
        if settings.mode != .format, settings.applyTo != .name {
            common.append([
                BatchRenameGridCell(
                    view: advice, column: 1, span: 3,
                    height: max(
                        CGFloat(BatchRenameSheetLayout.Advice.glyphSize),
                        batchRenameLine(BatchRenameSheetLayout.Fonts.small)), alignStart: false)
            ])
        }
        return (mode, common)
    }

    /// The pattern field, then the tokens' line(s).
    private func patternHeight(width: CGFloat) -> CGFloat {
        let layout = BatchRenameSheetLayout.Tokens.self
        return CGFloat(BatchRenameSheetLayout.controlHeight + layout.patternGap) + tokenLines(width: width).height
    }

    /// The tokens' items wrapped at `width`: each item's frame in the tokens' box.
    private func tokenLines(width: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        let layout = BatchRenameSheetLayout.Tokens.self
        let tokenHeight = CGFloat(layout.height)
        let noteLine = batchRenameLine(BatchRenameSheetLayout.Fonts.small)
        let items: [(width: CGFloat, height: CGFloat)] =
            [(insertNote.naturalWidth, noteLine)] + tokenButtons.map { ($0.preferredWidth, tokenHeight) }
            + [(bracketsNote.naturalWidth, noteLine)]
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, item) in items.enumerated() {
            let needed = (lines[lines.count - 1].isEmpty ? 0 : CGFloat(layout.gap)) + item.width
            if !lines[lines.count - 1].isEmpty, x + needed > width {
                lines.append([index])
                x = item.width
            } else {
                lines[lines.count - 1].append(index)
                x += needed
            }
        }
        var frames = Array(repeating: NSRect.zero, count: items.count)
        var y: CGFloat = 0
        for line in lines {
            let height = line.map { items[$0].height }.max() ?? 0
            var lineX: CGFloat = 0
            for index in line {
                let item = items[index]
                frames[index] = NSRect(
                    x: lineX, y: y + ((height - item.height) / 2).rounded(), width: item.width, height: item.height)
                lineX += item.width + CGFloat(layout.gap)
            }
            y += height + CGFloat(layout.gap)
        }
        return (frames, max(0, y - CGFloat(layout.gap)))
    }

    private var sheetWidth: CGFloat { bounds.width > 0 ? bounds.width : CGFloat(BatchRenameSheetLayout.width) }
    private var optionsWidth: CGFloat { sheetWidth - CGFloat(2 * BatchRenameSheetLayout.Options.paddingHorizontal) }

    private var headerHeight: CGFloat {
        let layout = BatchRenameSheetLayout.Header.self
        return CGFloat(layout.paddingTop + BatchRenameSheetLayout.controlHeight + layout.paddingBottom)
    }

    private var modesHeight: CGFloat {
        modeControl.preferredSize.height + CGFloat(BatchRenameSheetLayout.Modes.paddingBottom)
    }

    /// A grid's rows: each row's height and top, and the grid's height.
    private func measure(_ rows: [[BatchRenameGridCell]]) -> (tops: [CGFloat], heights: [CGFloat], height: CGFloat) {
        let gap = CGFloat(BatchRenameSheetLayout.Grid.gap)
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var y: CGFloat = 0
        for row in rows {
            let height = max(0, row.map { $0.height + $0.marginTop }.max() ?? 0)
            tops.append(y)
            heights.append(height)
            y += height + gap
        }
        return (tops, heights, max(0, y - gap))
    }

    private func optionsHeight(_ rows: (mode: [[BatchRenameGridCell]], common: [[BatchRenameGridCell]])) -> CGFloat {
        measure(rows.mode).height + CGFloat(BatchRenameSheetLayout.Options.gap) + measure(rows.common).height
            + CGFloat(BatchRenameSheetLayout.Options.paddingBottom)
    }

    private var previewWidth: CGFloat { sheetWidth - CGFloat(2 * BatchRenameSheetLayout.Preview.marginHorizontal) }

    /// Everything but the preview, at the sheet's width.
    private var fixedHeight: CGFloat {
        headerHeight + modesHeight + optionsHeight(gridRows()) + CGFloat(BatchRenameSheetLayout.Footer.height)
    }

    func panelSize(in size: NSSize) -> NSSize {
        let width = min(
            CGFloat(BatchRenameSheetLayout.width), max(0, size.width - CGFloat(BatchRenameSheetLayout.viewportInset)))
        let previous = frame.size
        if previous.width != width { setFrameSize(NSSize(width: width, height: previous.height)) }
        let natural = fixedHeight + preview.naturalHeight(width: previewWidth)
        let laid = BatchRenameSheetLayout.size(
            natural: Double(natural), windowWidth: Double(size.width), windowHeight: Double(size.height))
        return NSSize(width: CGFloat(laid.width), height: CGFloat(laid.height))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let header = BatchRenameSheetLayout.Header.self
        let control = CGFloat(BatchRenameSheetLayout.controlHeight)
        // Header: the title, then the Presets pull-down or the preset's name with Cancel and Save.
        headerBox.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        var right = width - CGFloat(header.paddingHorizontal)
        let headerY = CGFloat(header.paddingTop)
        if savingPreset {
            for button in [presetSaveButton, presetCancelButton] {
                let buttonWidth = button.preferredWidth
                right -= buttonWidth
                button.frame = NSRect(x: right, y: headerY, width: buttonWidth, height: control)
                right -= CGFloat(header.presetSaveGap)
            }
            let fieldWidth = CGFloat(header.presetFieldWidth)
            right -= fieldWidth
            presetNameField.frame = NSRect(x: right, y: headerY, width: fieldWidth, height: control)
        } else {
            let popUpWidth = max(CGFloat(header.presetsMinWidth), presetsPopUp.preferredWidth)
            right -= popUpWidth
            presetsPopUp.frame = NSRect(x: right, y: headerY, width: popUpWidth, height: control)
        }
        let titleLine = batchRenameLine(BatchRenameSheetLayout.Fonts.body)
        let titleX = CGFloat(header.paddingHorizontal)
        titleLabel.frame = NSRect(
            x: titleX, y: headerY + ((control - titleLine) / 2).rounded(),
            width: max(0, right - CGFloat(header.gap) - titleX), height: titleLine)
        // The mode control, centered.
        var y = headerHeight
        let modes = modeControl.preferredSize
        modeControl.frame = NSRect(
            x: (width - modes.width) / 2, y: y, width: modes.width, height: modes.height)
        y += modesHeight
        // The options: the mode's grid, then the one every mode has.
        let rows = gridRows()
        let shown = rows.mode.flatMap { $0 } + rows.common.flatMap { $0 }
        let shownViews = Set(shown.compactMap { $0.view.map(ObjectIdentifier.init) })
        for view in optionViews where !shownViews.contains(ObjectIdentifier(view)) { view.isHidden = true }
        for view in labels.values where !shownViews.contains(ObjectIdentifier(view)) { view.isHidden = true }
        shownCells = shown
        let left = CGFloat(BatchRenameSheetLayout.Options.paddingHorizontal)
        let modeHeight = place(rows.mode, x: left, y: y)
        y += modeHeight + CGFloat(BatchRenameSheetLayout.Options.gap)
        y += place(rows.common, x: left, y: y)
        y += CGFloat(BatchRenameSheetLayout.Options.paddingBottom)
        // The preview takes what is left above the footer.
        let footerHeight = CGFloat(BatchRenameSheetLayout.Footer.height)
        let previewHeight = max(0, min(preview.naturalHeight(width: previewWidth), bounds.height - footerHeight - y))
        preview.frame = NSRect(
            x: CGFloat(BatchRenameSheetLayout.Preview.marginHorizontal), y: y, width: previewWidth,
            height: previewHeight)
        y += previewHeight
        layoutFooter(y: y)
    }

    /// Lays a grid's cells out from (`x`, `y`); returns its height.
    private func place(_ rows: [[BatchRenameGridCell]], x: CGFloat, y: CGFloat) -> CGFloat {
        let columns = BatchRenameSheetLayout.Grid.columns(width: Double(optionsWidth))
        let measured = measure(rows)
        for (index, row) in rows.enumerated() {
            let top = y + measured.tops[index]
            let rowHeight = measured.heights[index]
            for cell in row {
                guard let view = cell.view else { continue }
                view.isHidden = false
                let first = columns[cell.column]
                let last = columns[cell.column + cell.span - 1]
                var cellX = x + CGFloat(first.x)
                var cellWidth = CGFloat(last.x + last.width - first.x)
                switch cell.width {
                case .fill: break
                case .fixed(let fixed): cellWidth = min(fixed, cellWidth)
                case .label(let second):
                    if second {
                        let margin = CGFloat(BatchRenameSheetLayout.Grid.secondLabelMargin)
                        cellX += margin
                        cellWidth -= margin
                    }
                }
                let cellY =
                    cell.alignStart
                    ? top + cell.marginTop
                    : top + ((rowHeight - cell.height - cell.marginTop) / 2).rounded()
                        + cell.marginTop
                view.frame = NSRect(x: cellX, y: cellY, width: cellWidth, height: cell.height)
            }
        }
        layoutChecks()
        layoutPattern()
        layoutAdvice()
        return measured.height
    }

    private func layoutChecks() {
        guard !checksRow.isHidden else {
            matchCaseCheck.isHidden = true
            regexCheck.isHidden = true
            return
        }
        let frame = checksRow.frame
        var x = frame.minX
        for check in [matchCaseCheck, regexCheck] {
            check.isHidden = false
            let width = check.preferredWidth
            check.frame = NSRect(x: x, y: frame.minY, width: width, height: frame.height)
            x += width + CGFloat(BatchRenameSheetLayout.Check.columnGap)
        }
    }

    private func layoutPattern() {
        let parts: [NSView] = [patternField, insertNote, bracketsNote] + tokenButtons
        guard !patternBlock.isHidden else {
            for view in parts { view.isHidden = true }
            return
        }
        for view in parts { view.isHidden = false }
        let frame = patternBlock.frame
        let control = CGFloat(BatchRenameSheetLayout.controlHeight)
        patternField.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: control)
        let top = frame.minY + control + CGFloat(BatchRenameSheetLayout.Tokens.patternGap)
        let lines = tokenLines(width: frame.width)
        let items: [NSView] = [insertNote] + tokenButtons + [bracketsNote]
        for (index, view) in items.enumerated() {
            view.frame = lines.frames[index].offsetBy(dx: frame.minX, dy: top)
        }
    }

    private func layoutAdvice() {
        guard !advice.isHidden else { return }
        let glyph = CGFloat(BatchRenameSheetLayout.Advice.glyphSize)
        let line = batchRenameLine(BatchRenameSheetLayout.Fonts.small)
        let height = advice.bounds.height
        adviceGlyph.frame = NSRect(x: 0, y: ((height - glyph) / 2).rounded(), width: glyph, height: glyph)
        adviceText.frame = NSRect(
            x: glyph + CGFloat(BatchRenameSheetLayout.Advice.gap), y: ((height - line) / 2).rounded(),
            width: adviceText.naturalWidth, height: line)
    }

    /// The views the grids may show; those a layout leaves out are hidden.
    private var optionViews: [NSView] {
        [
            findField, replaceField, findMessage, regexHint, checksRow, addTextField, addWherePopUp, nameFormatPopUp,
            formatWherePopUp, customNameField, keepNamesCheck, dateSourcePopUp, separatorPopUp, dateFormatPopUp,
            dateSeparatorPopUp, patternBlock, exampleNote, startField, stepField, digitsPopUp, casePopUp, applyToPopUp,
            namesOnlyNote, onConflictPopUp, advice,
        ]
    }

    private func layoutFooter(y: CGFloat) {
        let layout = BatchRenameSheetLayout.Footer.self
        let width = bounds.width
        footerLine.frame = NSRect(x: 0, y: y, width: width, height: CGFloat(layout.height))
        let control = CGFloat(BatchRenameSheetLayout.controlHeight)
        let buttonY = y + CGFloat(layout.border + layout.paddingTop)
        var right = width - CGFloat(layout.paddingHorizontal)
        for button in [renameButton, cancelButton] {
            let buttonWidth = button.preferredWidth
            right -= buttonWidth
            button.frame = NSRect(x: right, y: buttonY, width: buttonWidth, height: control)
            right -= CGFloat(layout.gap)
        }
        let line = batchRenameLine(BatchRenameSheetLayout.Fonts.summary)
        let left = CGFloat(layout.paddingHorizontal)
        summaryLabel.frame = NSRect(
            x: left, y: buttonY + ((control - line) / 2).rounded(), width: max(0, right - left), height: line)
    }
}

/// One cell of the options' grid: a view in a column (or several), as wide as they are or as it is, centered on its
/// row or at its top.
struct BatchRenameGridCell {
    enum Width {
        case fill
        case fixed(CGFloat)
        /// A label, right-aligned; the second of a row stands 12 apart from the first.
        case label(second: Bool)
    }

    var view: NSView?
    var column: Int
    var span = 1
    var width = Width.fill
    var height: CGFloat
    var alignStart = true
    var marginTop: CGFloat = 0
}

/// The footer's top line (`border-top: 1px solid var(--border-light)`).
@MainActor
final class BatchRenameFooterLine: NSView, ThemeApplying {
    private var theme = AppearanceModel.shared.theme
    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(theme.palette.borderLight).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(BatchRenameSheetLayout.Footer.border)).fill()
    }
}
