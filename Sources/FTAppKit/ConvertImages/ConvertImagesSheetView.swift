import AppKit
import FTFoundation

/// The Convert Images sheet: the format, its quality, the size and the metadata, with what the size does to the
/// pictures said under it. Nothing is made larger.
@MainActor
final class ConvertImagesSheetView: DialogPanelView {
    private(set) var sheet: ConvertImagesSheet
    /// Cancel, Escape and ⌘.
    var onCancel: () -> Void = {}
    /// Convert, with what was chosen.
    /// Convert was pressed: the settings to convert with, and those to remember for the next time.
    var onConvert: (ConvertImagesSettings, ConvertImagesSettings) -> Void = { _, _ in }

    let titleLabel: ThemedText
    let formatPopUp = ConvertImagesPopUp(label: "Format", identifier: "convertImages.format")
    let qualitySlider = NSSlider(value: 80, minValue: 0, maxValue: 100, target: nil, action: nil)
    let qualityValue = ThemedText(wrapping: false) { _ in NSAttributedString() }
    let sizePopUp = ConvertImagesPopUp(label: "Size", identifier: "convertImages.size")
    let widthField = BatchRenameTextField(
        label: "Width", identifier: "convertImages.width", number: true, limit: 5)
    let heightField = BatchRenameTextField(
        label: "Height", identifier: "convertImages.height", number: true, limit: 5)
    let unitPopUp = ConvertImagesPopUp(label: "Unit", identifier: "convertImages.unit")
    let proportionalCheck = BatchRenameCheckbox(title: "Scale proportionally")
    let customNote = ThemedText(wrapping: false) { _ in NSAttributedString() }
    let summaryLabel = ThemedText(wrapping: true) { _ in NSAttributedString() }
    let keepMetadataCheck = BatchRenameCheckbox(title: "Keep metadata")
    let removeLocationCheck = BatchRenameCheckbox(title: "Remove location")
    let footerLine = DialogFooterLine(thickness: BatchRenameSheetLayout.Footer.border)
    let cancelButton = SystemButton(title: "Cancel")
    let convertButton = SystemButton(title: "Convert")
    private(set) var warningRows: [(glyph: WarningSymbolView, text: ThemedText)] = []
    private(set) var noteLabels: [ThemedText] = []
    private var labels: [String: ThemedText] = [:]

    private enum Metrics {
        static let width: CGFloat = 480
        static let padding: CGFloat = 20
        static let labelWidth: CGFloat = 96
        static let gap: CGFloat = 8
        static let rowGap: CGFloat = 10
        static let fieldWidth: CGFloat = 76
        static let smallLine: CGFloat = 16
        static var control: CGFloat { CGFloat(BatchRenameSheetLayout.controlHeight) }
    }

    init(sheet: ConvertImagesSheet) {
        self.sheet = sheet
        titleLabel = ThemedText(
            sheet.title,
            style: batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textPrimary }, weight: .bold))
        super.init(cornerRadius: GlassSurface.sheetRadius)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityIdentifier("convertImages")
        build()
        applyTheme(theme)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Building

    private func label(_ text: String) -> ThemedText {
        if let made = labels[text] { return made }
        let made = ThemedText(
            text,
            style: batchRenameStyle(
                BatchRenameSheetLayout.Fonts.body, { $0.palette.textSecondary },
                lineHeight: BatchRenameSheetLayout.controlHeight, alignment: .right))
        made.setAccessibilityIdentifier("convertImages.label")
        addSubview(made)
        labels[text] = made
        return made
    }

    private func build() {
        titleLabel.setAccessibilityIdentifier("convertImages.title")
        qualitySlider.setAccessibilityIdentifier("convertImages.quality")
        qualitySlider.setAccessibilityLabel("Quality")
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged(_:))
        qualityValue.setAccessibilityIdentifier("convertImages.qualityValue")
        proportionalCheck.setAccessibilityIdentifier("convertImages.proportional")
        customNote.setAccessibilityIdentifier("convertImages.customNote")
        summaryLabel.setAccessibilityIdentifier("convertImages.summary")
        summaryLabel.setAccessibilityRole(.staticText)
        keepMetadataCheck.setAccessibilityIdentifier("convertImages.keepMetadata")
        removeLocationCheck.setAccessibilityIdentifier("convertImages.removeLocation")
        cancelButton.setAccessibilityIdentifier("convertImages.cancel")
        convertButton.setAccessibilityIdentifier("convertImages.convert")
        convertButton.isDefault = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        convertButton.target = self
        convertButton.action = #selector(convertPressed(_:))
        for view: NSView in [
            titleLabel, formatPopUp, qualitySlider, qualityValue, sizePopUp, widthField, heightField, unitPopUp,
            proportionalCheck, customNote, summaryLabel, keepMetadataCheck, removeLocationCheck, footerLine,
            cancelButton, convertButton,
        ] {
            addSubview(view)
        }
        for text in ["Format", "Quality", "Size", "Width", "Height", "Metadata"] { _ = label(text) }
        formatPopUp.onChoose = { [weak self] index in
            self?.change { sheet in
                guard sheet.formats.indices.contains(index) else { return }
                sheet.choose(format: sheet.formats[index])
            }
        }
        sizePopUp.onChoose = { [weak self] index in
            guard let choice = ConvertImagesSheet.sizeChoices[index] else { return }
            self?.change { $0.choose(size: choice) }
        }
        unitPopUp.onChoose = { [weak self] index in
            self?.change { $0.choose(unit: ImageSizeUnit.allCases[index]) }
        }
        widthField.onChange = { [weak self] text in
            guard let value = Int(text) else { return }
            self?.change { $0.type(width: value) }
        }
        heightField.onChange = { [weak self] text in
            guard let value = Int(text) else { return }
            self?.change { $0.type(height: value) }
        }
        widthField.onBlur = { [weak self] in self?.settleCustom() }
        heightField.onBlur = { [weak self] in self?.settleCustom() }
        proportionalCheck.onToggle = { [weak self] on in self?.change { $0.set(proportional: on) } }
        keepMetadataCheck.onToggle = { [weak self] on in self?.change { $0.set(keepMetadata: on) } }
        removeLocationCheck.onToggle = { [weak self] on in self?.change { $0.set(removeLocation: on) } }
    }

    private func change(_ edit: (inout ConvertImagesSheet) -> Void) {
        edit(&sheet)
        render()
    }

    /// What was read of the pictures, once it is.
    func read(_ infos: [ImageInfo?]) {
        change { $0.read(infos) }
    }

    /// A width or height left in a field is brought back to what is allowed.
    func settleCustom() {
        change { $0.settleCustom() }
    }

    @objc private func qualityChanged(_ sender: Any?) {
        change { $0.set(quality: qualitySlider.doubleValue / 100) }
    }

    @objc private func cancelPressed(_ sender: Any?) { onCancel() }

    @objc private func convertPressed(_ sender: Any?) { submit() }

    /// Convert, when it can: a value still being typed is settled first.
    func submit() {
        settleCustom()
        guard sheet.canConvert else { return }
        onConvert(sheet.settings, sheet.settingsToRemember)
    }

    // MARK: Showing

    private var showsQuality: Bool { sheet.settings.format.hasQuality }
    private var showsCustom: Bool { sheet.settings.sizeMode == .custom }

    func render() {
        let settings = sheet.settings
        formatPopUp.setItems(
            sheet.formats.map { .init(title: $0.title) },
            selected: sheet.formats.firstIndex(of: settings.format) ?? 0)
        qualitySlider.doubleValue = settings.quality * 100
        let quality = sheet.qualityText
        qualityValue.content = { theme in
            batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textSecondary }).string(quality, theme)
        }
        sizePopUp.setItems(
            ConvertImagesSheet.sizeChoices.map { choice in
                guard let choice else { return nil }
                let title = sheet.disabledNote(choice).map { "\(choice.title) (\($0))" } ?? choice.title
                return .init(title: title, enabled: sheet.isEnabled(choice))
            },
            selected: ConvertImagesSheet.sizeChoices.firstIndex(of: sheet.selectedSizeChoice) ?? 0)
        unitPopUp.setItems(
            [.init(title: "pixels"), .init(title: "percent")],
            selected: ImageSizeUnit.allCases.firstIndex(of: settings.customUnit) ?? 0)
        widthField.text = String(settings.customWidth)
        heightField.text = String(settings.customHeight)
        proportionalCheck.setChecked(settings.proportional)
        let note = sheet.customNote ?? ""
        customNote.content = { theme in
            batchRenameStyle(BatchRenameSheetLayout.Fonts.small, { $0.palette.textSecondary }).string(note, theme)
        }
        let summary = sheet.summary
        summaryLabel.content = { theme in
            batchRenameStyle(BatchRenameSheetLayout.Fonts.small, { $0.palette.textSecondary }).string(summary, theme)
        }
        keepMetadataCheck.setChecked(settings.keepMetadata)
        removeLocationCheck.setChecked(sheet.removesLocation)
        removeLocationCheck.isEnabled = settings.keepMetadata
        setWarnings(sheet.warnings)
        setNotes(sheet.notes)
        convertButton.isEnabled = sheet.canConvert
        for view: NSView in [qualitySlider, qualityValue, labels["Quality"]!] { view.isHidden = !showsQuality }
        for view: NSView in [
            widthField, heightField, unitPopUp, proportionalCheck, customNote, labels["Width"]!,
            labels["Height"]!,
        ] {
            view.isHidden = !showsCustom
        }
        customNote.isHidden = !showsCustom || sheet.customNote == nil
        needsLayout = true
        superview?.needsLayout = true
    }

    private func setWarnings(_ lines: [String]) {
        while warningRows.count > lines.count {
            let row = warningRows.removeLast()
            row.glyph.removeFromSuperview()
            row.text.removeFromSuperview()
        }
        while warningRows.count < lines.count {
            let glyph = WarningSymbolView(identifier: "convertImages.warningSign")
            let text = ThemedText(wrapping: true) { _ in NSAttributedString() }
            text.setAccessibilityIdentifier("convertImages.warning")
            addSubview(glyph)
            addSubview(text)
            warningRows.append((glyph, text))
        }
        for (row, line) in zip(warningRows, lines) {
            row.text.content = { theme in
                batchRenameStyle(BatchRenameSheetLayout.Fonts.small, { $0.palette.textPrimary }).string(line, theme)
            }
            row.text.applyTheme(theme)
        }
    }

    private func setNotes(_ lines: [String]) {
        while noteLabels.count > lines.count { noteLabels.removeLast().removeFromSuperview() }
        while noteLabels.count < lines.count {
            let text = ThemedText(wrapping: true) { _ in NSAttributedString() }
            text.setAccessibilityIdentifier("convertImages.note")
            addSubview(text)
            noteLabels.append(text)
        }
        for (label, line) in zip(noteLabels, lines) {
            label.content = { theme in
                batchRenameStyle(BatchRenameSheetLayout.Fonts.small, { $0.palette.textSecondary }).string(line, theme)
            }
            label.applyTheme(theme)
        }
    }

    /// What the sheet says under the size, for tests.
    var summaryText: String { summaryLabel.stringValue }
    var warningTexts: [String] { warningRows.map(\.text.stringValue) }
    var noteTexts: [String] { noteLabels.map(\.stringValue) }

    // MARK: Keys

    override var initialResponder: NSView? { formatPopUp }

    override var acceptsFirstResponder: Bool { true }

    func takeKeyboard() {
        window?.makeFirstResponder(formatPopUp)
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if KeyCode.isCancel(event) {
            onCancel()
            return true
        }
        if event.keyCode == KeyCode.tab, modifiers.isSubset(of: [.shift]) {
            cycleFocus(backward: modifiers.contains(.shift))
            return true
        }
        guard KeyCode.isReturn(event), modifiers.isSubset(of: [.shift]) else { return false }
        if let button = focusedControl as? SystemButton, button.isDescendant(of: self) {
            button.perform()
            return true
        }
        submit()
        return true
    }

    /// The control of the sheet that has the keyboard: a field's whole box, for its field editor or its text.
    override var focusedControl: NSView? {
        if let field = super.focusedControl as? BatchRenameEditField { return field.superview }
        return super.focusedControl
    }

    override func focusOrder() -> [NSView] {
        var chain: [NSView] = [formatPopUp]
        if showsQuality { chain.append(qualitySlider) }
        chain.append(sizePopUp)
        if showsCustom { chain += [widthField, heightField, unitPopUp, proportionalCheck] }
        chain.append(keepMetadataCheck)
        if removeLocationCheck.isEnabled { chain.append(removeLocationCheck) }
        chain.append(cancelButton)
        if convertButton.isEnabled { chain.append(convertButton) }
        return chain
    }

    override func moveKeyboard(to view: NSView) {
        if let field = view as? BatchRenameTextField {
            field.focus(caret: (field.text as NSString).length)
        } else {
            super.moveKeyboard(to: view)
        }
    }

    // MARK: Layout

    override func panelSize(in size: NSSize) -> NSSize {
        let width = min(Metrics.width, max(0, size.width - CGFloat(BatchRenameSheetLayout.viewportInset)))
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        return NSSize(width: width, height: arrange(width: width, apply: false))
    }

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, apply: true)
    }

    /// Lays the sheet out top to bottom at `width`, placing the views when `apply`; returns its height.
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let control = Metrics.control
        let left = Metrics.padding
        let controlsX = left + Metrics.labelWidth + Metrics.gap
        let controlsWidth = max(0, width - controlsX - Metrics.padding)
        func place(_ view: NSView, _ rect: NSRect) { if apply { view.frame = rect } }
        func labelled(_ text: String, y: CGFloat) {
            if let label = labels[text] {
                place(label, NSRect(x: left, y: y, width: Metrics.labelWidth, height: control))
            }
        }
        func textHeight(_ text: ThemedText, width: CGFloat) -> CGFloat {
            max(
                Metrics.smallLine,
                ceil(text.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height))
        }
        var y = Metrics.padding
        let titleHeight = batchRenameLine(BatchRenameSheetLayout.Fonts.body)
        place(titleLabel, NSRect(x: left, y: y, width: width - 2 * left, height: titleHeight))
        y += titleHeight + 14

        labelled("Format", y: y)
        place(formatPopUp, NSRect(x: controlsX, y: y, width: max(120, formatPopUp.preferredWidth), height: control))
        y += control + Metrics.rowGap
        if showsQuality {
            labelled("Quality", y: y)
            let valueWidth: CGFloat = 44
            place(
                qualitySlider,
                NSRect(x: controlsX, y: y, width: max(0, controlsWidth - valueWidth - 8), height: control))
            place(
                qualityValue,
                NSRect(x: controlsX + controlsWidth - valueWidth, y: y + 4, width: valueWidth, height: control - 4))
            y += control + Metrics.rowGap
        }
        labelled("Size", y: y)
        place(
            sizePopUp,
            NSRect(x: controlsX, y: y, width: min(controlsWidth, max(200, sizePopUp.preferredWidth)), height: control))
        y += control + Metrics.rowGap
        if showsCustom {
            labelled("Width", y: y)
            place(widthField, NSRect(x: controlsX, y: y, width: Metrics.fieldWidth, height: control))
            let heightLabelX = controlsX + Metrics.fieldWidth + 12
            if let heightLabel = labels["Height"] {
                let labelWidth = batchRenameTextWidth("Height", BatchRenameSheetLayout.Fonts.body)
                place(heightLabel, NSRect(x: heightLabelX, y: y, width: labelWidth, height: control))
                let fieldX = heightLabelX + labelWidth + Metrics.gap
                place(heightField, NSRect(x: fieldX, y: y, width: Metrics.fieldWidth, height: control))
                let unitX = fieldX + Metrics.fieldWidth + Metrics.gap
                place(unitPopUp, NSRect(x: unitX, y: y, width: max(90, unitPopUp.preferredWidth), height: control))
            }
            y += control + Metrics.rowGap
            place(proportionalCheck, NSRect(x: controlsX, y: y, width: controlsWidth, height: control))
            y += control
            if sheet.customNote != nil {
                place(customNote, NSRect(x: controlsX, y: y + 2, width: controlsWidth, height: Metrics.smallLine))
                y += Metrics.smallLine + 2
            }
            y += Metrics.rowGap
        }
        let summaryHeight = textHeight(summaryLabel, width: controlsWidth)
        place(summaryLabel, NSRect(x: controlsX, y: y, width: controlsWidth, height: summaryHeight))
        y += summaryHeight + 6
        for row in warningRows {
            let glyph: CGFloat = 14
            let textWidth = max(0, controlsWidth - glyph - 6)
            let height = textHeight(row.text, width: textWidth)
            place(row.glyph, NSRect(x: controlsX, y: y + 1, width: glyph, height: glyph))
            place(row.text, NSRect(x: controlsX + glyph + 6, y: y, width: textWidth, height: height))
            y += height + 4
        }
        y += Metrics.rowGap

        labelled("Metadata", y: y)
        place(keepMetadataCheck, NSRect(x: controlsX, y: y, width: controlsWidth, height: control))
        y += control + 2
        place(removeLocationCheck, NSRect(x: controlsX, y: y, width: controlsWidth, height: control))
        y += control + Metrics.rowGap
        for note in noteLabels {
            let height = textHeight(note, width: controlsWidth)
            place(note, NSRect(x: controlsX, y: y, width: controlsWidth, height: height))
            y += height + 4
        }

        let footer = BatchRenameSheetLayout.Footer.self
        y += 4
        place(footerLine, NSRect(x: 0, y: y, width: width, height: CGFloat(footer.height)))
        let buttonY = y + CGFloat(footer.border + footer.paddingTop)
        if apply {
            layoutButtonRow(
                [cancelButton, convertButton], right: width - CGFloat(footer.paddingHorizontal), y: buttonY,
                height: control, gap: CGFloat(footer.gap))
        }
        return y + CGFloat(footer.height)
    }
}

/// A pop-up of the sheet: the system's, in the sheet's font, with lines between choices and choices it doesn't offer
/// grayed.
@MainActor
final class ConvertImagesPopUp: NSPopUpButton {
    struct Item: Equatable {
        var title: String
        var enabled = true
    }

    /// Told the index of the choice taken, lines counted.
    var onChoose: (Int) -> Void = { _ in }
    private var items: [Item?] = []

    init(label: String, identifier: String) {
        super.init(frame: .zero, pullsDown: false)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        font = ThemeFonts.sans(BatchRenameSheetLayout.Fonts.body)
        target = self
        action = #selector(chose(_:))
        autoenablesItems = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The choices (nil a line) and the one chosen.
    func setItems(_ items: [Item?], selected: Int) {
        if items != self.items {
            self.items = items
            menu?.removeAllItems()
            for (index, item) in items.enumerated() {
                guard let item else {
                    menu?.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.tag = index
                menuItem.isEnabled = item.enabled
                menu?.addItem(menuItem)
            }
        }
        if indexOfSelectedItem != selected, itemArray.indices.contains(selected) { selectItem(at: selected) }
    }

    /// The choices' titles, lines left out, for tests.
    var titles: [String] { items.compactMap { $0?.title } }
    var enabledTitles: [String] { items.compactMap { $0?.enabled == true ? $0?.title : nil } }

    /// Chooses the item titled `title`, as a click does (tests).
    func choose(_ title: String) {
        guard let index = items.firstIndex(where: { $0?.title == title }) else { return }
        selectItem(at: index)
        onChoose(index)
    }

    var preferredWidth: CGFloat { ceil(cell?.cellSize.width ?? 0) }

    @objc private func chose(_ sender: Any?) {
        guard let tag = selectedItem?.tag else { return }
        onChoose(tag)
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool {
        focusRingType = NSApp.currentEvent?.type == .leftMouseDown ? .none : .default
        return super.becomeFirstResponder()
    }
}
