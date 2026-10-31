// Port of apps/desktop/src/renderer/components/GoToFolderDialog.tsx (with hooks/usePathSuggestions.ts) and the
// .go-to-folder-* rules of apps/desktop/src/renderer/styles.css (3437-3666)
import AppKit
import FTFoundation

/// What a Go To box is for: Go To itself, or Move To with its title, words and Choose….
struct GoToBoxOptions {
    /// Shown above the field; Go To has none.
    var title: String?
    var fieldLabel = "Folder name or path"
    var submitLabel = "Open"
    var selectFirstPlace = true
    /// Choose…: the system's folder picker, from a path; nil when there is no such button.
    var browse: (@MainActor (String) async -> String?)?
    /// The folder shown when the box opened, where Choose… starts with no path typed.
    var currentPath = ""

    static let goTo = GoToBoxOptions()

    static func moveTo(currentPath: String, browse: @escaping @MainActor (String) async -> String?) -> GoToBoxOptions {
        GoToBoxOptions(
            title: "Move To", fieldLabel: "Destination folder", submitLabel: "Move", selectFirstPlace: false,
            browse: browse, currentPath: currentPath)
    }
}

/// The Go To box (⌘K, ⇧⌘G) and the Move To box: a panel dropped below the toolbar with a field, the folders that match
/// and the footer's buttons.
@MainActor
final class GoToFolderBox: NSView, DialogPanel, ThemeApplying, NSTextFieldDelegate {
    static let placeholder = "Folder name, or a path starting with / or ~"
    /// Where the pointer last was over a box's list, by window: kept across opens, as the original's ref is.
    private static var lastPointers: [ObjectIdentifier: CGPoint] = [:]

    let options: GoToBoxOptions
    private(set) var state: GoToBoxState
    let requests: PathCompletionRequests
    let titleLabel: NSTextField?
    let shell: GoToFieldShell
    let errorLabel = PlainLabel(wrappingLabelWithString: "")
    let listLabel = PlainLabel(labelWithString: "")
    let hintLabel = PlainLabel(labelWithString: "")
    let emptyLabel = PlainLabel(wrappingLabelWithString: "")
    let scroll = NSScrollView()
    private let listContent = FlippedView()
    let footer = GoToFooterView()
    let browseButton: SystemButton?
    let cancelButton = SystemButton(title: "Cancel")
    let submitButton: SystemButton
    private(set) var rowViews: [GoToRowView] = []
    private var theme = AppearanceModel.shared.theme
    private var browsing = false
    private var pointerKey: ObjectIdentifier?

    /// Told the folder to go to (or move into).
    var onSubmit: (String) -> Void = { _ in }
    /// Escape, ⌘., Cancel and a press on the scrim.
    var onClose: () -> Void = {}
    /// ⌘⌫ on an opened folder.
    var onForget: (String) -> Void = { _ in }

    private static let labelFont = ThemeFonts.sans(DesignTokens.typeScale.small, .semibold)
    private static let hintFont = ThemeFonts.sans(DesignTokens.typeScale.small)
    private static let errorFont = ThemeFonts.sans(DesignTokens.typeScale.small)
    private static let emptyFont = ThemeFonts.sans(DesignTokens.typeScale.callout)
    private static let titleFont = ThemeFonts.sans(DesignTokens.typeScale.body, .bold)

    init(
        places: [Place], options: GoToBoxOptions, canForget: Bool = true, timers: any TimerScheduling,
        requestCompletions: @escaping @MainActor (String) async -> [GoToCompletion]?
    ) {
        self.options = options
        state = GoToBoxState(places: places, selectFirstPlace: options.selectFirstPlace, canForgetPlaces: canForget)
        requests = PathCompletionRequests(timers: timers, request: requestCompletions)
        shell = GoToFieldShell(label: options.fieldLabel)
        if let title = options.title {
            let label = NSTextField(labelWithString: title)
            label.font = Self.titleFont
            label.setAccessibilityIdentifier("goToFolder.title")
            titleLabel = label
        } else {
            titleLabel = nil
        }
        browseButton = options.browse == nil ? nil : SystemButton(title: "Choose…")
        submitButton = SystemButton(title: options.submitLabel)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(options.title ?? "Go To")
        setAccessibilityIdentifier("goToFolder")
        wantsLayer = true
        if let titleLabel { addSubview(titleLabel) }
        addSubview(shell)
        shell.field.delegate = self
        shell.clearButton.target = self
        shell.clearButton.action = #selector(clearPressed(_:))
        errorLabel.font = Self.errorFont
        errorLabel.setAccessibilityIdentifier("goToFolder.error")
        errorLabel.isHidden = true
        addSubview(errorLabel)
        listLabel.font = Self.labelFont
        listLabel.setAccessibilityIdentifier("goToFolder.label")
        hintLabel.font = Self.hintFont
        hintLabel.alignment = .right
        hintLabel.setAccessibilityIdentifier("goToFolder.hint")
        addSubview(listLabel)
        addSubview(hintLabel)
        emptyLabel.font = Self.emptyFont
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("goToFolder.empty")
        addSubview(emptyLabel)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = listContent
        scroll.setAccessibilityIdentifier("goToFolder.list")
        addSubview(scroll)
        footer.setAccessibilityIdentifier("goToFolder.footer")
        addSubview(footer)
        if let browseButton {
            browseButton.target = self
            browseButton.action = #selector(browsePressed(_:))
            browseButton.setAccessibilityIdentifier("goToFolder.browse")
            footer.addSubview(browseButton)
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.setAccessibilityIdentifier("goToFolder.cancel")
        submitButton.isDefault = true
        submitButton.target = self
        submitButton.action = #selector(submitPressed(_:))
        submitButton.setAccessibilityIdentifier("goToFolder.submit")
        footer.addSubview(cancelButton)
        footer.addSubview(submitButton)
        requests.onAnswer = { [weak self] completions in
            self?.state.setCompletions(completions)
            self?.render()
        }
        applyTheme(theme)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var field: GoToField { shell.field }

    // MARK: Opening

    /// The box is up over `window`: it starts empty, the field focused with the caret at its end, and the empty field's
    /// request waits for the pause.
    func opened(in window: NSWindow) {
        pointerKey = ObjectIdentifier(window)
        state.lastPointer = Self.lastPointers[ObjectIdentifier(window)]
        requests.setOpen(true)
        focusField()
    }

    func closed() {
        requests.setOpen(false)
    }

    func setSubmitting(_ submitting: Bool) {
        state.submitting = submitting
        render()
    }

    func setError(_ error: String?) {
        state.error = error
        render()
    }

    /// The places read again: the rows follow at once (B-DLG-038).
    func setPlaces(_ places: [Place]) {
        state.setPlaces(places)
        render()
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        textChanged(field.stringValue)
    }

    /// What is typed changed: a path asks for completions after the pause, a name ranks the places at once.
    func textChanged(_ value: String) {
        let effect = state.setText(value)
        if case .requestCompletions(let text) = effect {
            requests.setValue(text, requests: true)
        } else {
            requests.setValue(value, requests: false)
        }
        render()
    }

    /// Puts `value` into the field, the caret at its end.
    private func setField(_ value: String) {
        field.stringValue = value
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (value as NSString).length, length: 0)
        }
    }

    private func focusField() {
        guard let window else { return }
        if !shell.holdsKeyboard { window.makeFirstResponder(field) }
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        shell.needsDisplay = true
    }

    private func apply(_ effect: GoToEffect) {
        switch effect {
        case .none: break
        case .requestCompletions(let text):
            setField(text)
            requests.setValue(text, requests: true)
            focusField()
        case .submit(let path):
            onSubmit(path)
        case .forget(let path):
            state.forgetPlace(path)
            onForget(path)
        }
        render()
    }

    // MARK: Keys

    var initialResponder: NSView? { field }

    func handleKey(_ event: NSEvent) -> Bool {
        if KeyCode.isCancel(event) {
            onClose()
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if shell.holdsKeyboard {
            switch event.keyCode {
            case KeyCode.down where modifiers.isEmpty:
                moveSelection(1)
                return true
            case KeyCode.up where modifiers.isEmpty:
                moveSelection(-1)
                return true
            case KeyCode.tab where modifiers.isEmpty:
                guard let effect = state.tab() else { return false }
                apply(effect)
                return true
            case KeyCode.delete where modifiers == .command:
                guard let effect = state.forgetKey() else { return false }
                apply(effect)
                return true
            case KeyCode.returnKey, KeyCode.keypadEnter:
                guard modifiers.isEmpty else { return false }
                apply(state.pressReturn())
                return true
            default:
                return false
            }
        }
        guard KeyCode.isReturn(event) || event.charactersIgnoringModifiers == " " else { return false }
        if let row = window?.firstResponder as? GoToRowView, row.isDescendant(of: self) {
            rowClicked(row.index)
            return true
        }
        if let button = window?.firstResponder as? SystemButton, button.isDescendant(of: self) {
            button.perform()
            return true
        }
        if window?.firstResponder === shell.clearButton {
            shell.clearButton.perform()
            return true
        }
        return false
    }

    func moveSelection(_ step: Int) {
        state.moveSelection(step)
        render()
        scrollSelectionIntoView()
    }

    private func scrollSelectionIntoView() {
        guard rowViews.indices.contains(state.selectedIndex) else { return }
        rowViews[state.selectedIndex].scrollToVisible(rowViews[state.selectedIndex].bounds)
    }

    // MARK: Mouse

    func rowClicked(_ index: Int) {
        apply(state.click(index))
    }

    func pointerMoved(over index: Int, at point: CGPoint) {
        state.pointerMoved(over: index, at: point)
        if let pointerKey { Self.lastPointers[pointerKey] = point }
        render()
    }

    @objc private func clearPressed(_ sender: Any?) {
        state.clear()
        setField("")
        requests.setValue("", requests: false)
        render()
        focusField()
    }

    @objc private func cancelPressed(_ sender: Any?) { onClose() }

    @objc private func submitPressed(_ sender: Any?) {
        guard let value = state.submitValue else { return }
        onSubmit(value)
    }

    @objc private func browsePressed(_ sender: Any?) {
        guard let browse = options.browse, !browsing else { return }
        browsing = true
        render()
        let start = state.isPathMode && state.hasQuery ? state.trimmedText : options.currentPath
        Task { @MainActor [weak self] in
            let picked = await browse(start)
            guard let self else { return }
            self.browsing = false
            if let picked, !picked.isEmpty {
                _ = self.state.setText(picked)
                self.setField(picked)
                self.requests.setValue(picked, requests: true)
                self.focusField()
            }
            self.render()
        }
    }

    // MARK: Showing

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let palette = theme.palette
        layer?.backgroundColor = NSColor(palette.bgElevated).cgColor
        layer?.cornerRadius = CGFloat(DesignTokens.radii.dialog)
        // --elevation-dialog: the 0.5 edge; DialogScrim draws the drops under the panel.
        if let edge = palette.elevationDialog.first(where: { $0.blur == 0 && $0.spread > 0 }) {
            layer?.borderWidth = CGFloat(edge.spread)
            layer?.borderColor = NSColor(edge.color).cgColor
        }
        titleLabel?.textColor = NSColor(palette.textPrimary)
        styleLabels()
        shell.applyTheme(theme)
        footer.applyTheme(theme)
        for button in [cancelButton, submitButton] + [browseButton].compactMap({ $0 }) { button.applyTheme(theme) }
        for row in rowViews { row.applyTheme(theme) }
    }

    /// Shows the state: the ✕, the error, the label and hint, the rows or the empty text, and what the buttons allow.
    func render() {
        shell.clearButton.isHidden = !state.showsClear
        errorLabel.stringValue = state.error ?? ""
        errorLabel.isHidden = state.error == nil
        let rows = state.rows
        listLabel.stringValue = state.label
        hintLabel.stringValue = state.hint ?? ""
        emptyLabel.stringValue = state.emptyText
        styleLabels()
        listLabel.isHidden = rows.isEmpty
        hintLabel.isHidden = rows.isEmpty || state.hint == nil
        scroll.isHidden = rows.isEmpty
        emptyLabel.isHidden = !rows.isEmpty
        if rowViews.map(\.row) != rows {
            for view in rowViews { view.removeFromSuperview() }
            rowViews = rows.enumerated().map { index, row in
                let view = GoToRowView(index: index, row: row, theme: theme)
                view.box = self
                listContent.addSubview(view)
                return view
            }
        }
        for view in rowViews { view.isSelected = view.index == state.selectedIndex }
        cancelButton.isEnabled = !state.submitting
        submitButton.isEnabled = state.canSubmit
        browseButton?.isEnabled = !state.submitting && !browsing
        shell.needsLayout = true
        shell.needsDisplay = true
        needsLayout = true
        superview?.needsLayout = true
    }

    /// The labels' text in their colors. A translucent color (the secondary text's) is drawn flattened onto the
    /// panel, as AppKit draws a translucent text color darker than CSS does; the field's own color stays the one meant.
    private func styleLabels() {
        let palette = theme.palette
        let labels: [(NSTextField, RGBA)] = [
            (errorLabel, palette.dangerText), (listLabel, palette.textSecondary), (hintLabel, palette.textSecondary),
            (emptyLabel, palette.textSecondary),
        ]
        for (label, color) in labels {
            label.textColor = NSColor(color)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = label.alignment
            paragraph.lineBreakMode = label.lineBreakMode
            let shown = color.alpha < 1 ? color.flattened(over: palette.bgElevated) : color
            label.attributedStringValue = NSAttributedString(
                string: label.stringValue,
                attributes: [
                    .font: label.font ?? Self.hintFont, .foregroundColor: NSColor(shown), .paragraphStyle: paragraph,
                ])
        }
    }

    // MARK: Layout

    private var rowHeight: CGFloat { CGFloat(DesignTokens.controlHeights.large) }

    private func line(_ font: NSFont) -> CGFloat { GoToRowView.lineHeight(font) }

    /// Everything but the list's rows, at `width`.
    private func fixedHeight(width: CGFloat) -> CGFloat {
        let layout = DialogLayout.GoTo.self
        var height = CGFloat(layout.paddingTop)
        if titleLabel != nil {
            height += CGFloat(layout.titleTop + layout.titleBottom) + ThemeFonts.normalLineHeight(Self.titleFont)
        }
        height += CGFloat(DesignTokens.controlHeights.large)
        if !errorLabel.isHidden {
            height += CGFloat(layout.errorTop) + errorHeight(width: width)
        }
        height += CGFloat(layout.sectionTop + layout.sectionBottom)
        if state.rows.isEmpty {
            height += CGFloat(layout.emptyTop + layout.emptyBottom) + emptyHeight(width: width)
        } else {
            height += line(Self.labelFont) + CGFloat(layout.labelBottom)
        }
        height += CGFloat(layout.footerBorder + layout.footerTop + layout.footerBottom)
        height += CGFloat(DesignTokens.controlHeights.regular)
        return height
    }

    private func errorHeight(width: CGFloat) -> CGFloat {
        let inner = width - 2 * CGFloat(DialogLayout.GoTo.inputSectionHorizontal + DialogLayout.GoTo.errorHorizontal)
        return ceil(errorLabel.sizeThatFits(NSSize(width: max(1, inner), height: .greatestFiniteMagnitude)).height)
    }

    private func emptyHeight(width: CGFloat) -> CGFloat {
        let layout = DialogLayout.GoTo.self
        let inner = width - 2 * CGFloat(layout.sectionHorizontal + layout.emptyHorizontal)
        return ceil(emptyLabel.sizeThatFits(NSSize(width: max(1, inner), height: .greatestFiniteMagnitude)).height)
    }

    func panelSize(in size: NSSize) -> NSSize {
        let layout = DialogLayout.GoTo.self
        let width = min(CGFloat(layout.width), max(0, size.width - CGFloat(layout.viewportInset)))
        let maxHeight = max(0, size.height - CGFloat(layout.heightInset))
        let visibleRows = min(state.rows.count, layout.visibleRows)
        let height = fixedHeight(width: width) + CGFloat(visibleRows) * rowHeight
        return NSSize(width: width, height: min(height, maxHeight))
    }

    override func layout() {
        super.layout()
        let layout = DialogLayout.GoTo.self
        let width = bounds.width
        var y = CGFloat(layout.paddingTop)
        if let titleLabel {
            y += CGFloat(layout.titleTop)
            // A label's cell draws its text 2 in, so its frame starts 2 early; the line takes CSS's 15, the frame its own.
            let inset = GoToRowView.cellInset
            titleLabel.frame = NSRect(
                x: CGFloat(layout.titleHorizontal) - inset, y: y,
                width: max(0, width - 2 * CGFloat(layout.titleHorizontal)) + 2 * inset, height: line(Self.titleFont))
            y += ThemeFonts.normalLineHeight(Self.titleFont) + CGFloat(layout.titleBottom)
        }
        let section = CGFloat(layout.inputSectionHorizontal)
        let fieldHeight = CGFloat(DesignTokens.controlHeights.large)
        shell.frame = NSRect(x: section, y: y, width: max(0, width - 2 * section), height: fieldHeight)
        y += fieldHeight
        if !errorLabel.isHidden {
            y += CGFloat(layout.errorTop)
            let inset = section + CGFloat(layout.errorHorizontal)
            let height = errorHeight(width: width)
            errorLabel.frame = NSRect(x: inset, y: y, width: max(0, width - 2 * inset), height: height)
            y += height
        }
        // The footer sits at the bottom; the list takes what is left between.
        let footerHeight =
            CGFloat(layout.footerBorder + layout.footerTop + layout.footerBottom)
            + CGFloat(DesignTokens.controlHeights.regular)
        footer.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: width, height: footerHeight)
        layoutFooter()
        y += CGFloat(layout.sectionTop)
        let sectionX = CGFloat(layout.sectionHorizontal)
        let sectionWidth = max(0, width - 2 * sectionX)
        if state.rows.isEmpty {
            y += CGFloat(layout.emptyTop)
            let inset = sectionX + CGFloat(layout.emptyHorizontal)
            emptyLabel.frame = NSRect(
                x: inset, y: y, width: max(0, width - 2 * inset), height: emptyHeight(width: width))
            return
        }
        let labelHeight = line(Self.labelFont)
        let labelX = sectionX + CGFloat(layout.labelHorizontal)
        let labelWidth = max(0, sectionWidth - 2 * CGFloat(layout.labelHorizontal))
        // The labels' cells draw their text 2 in from their frames: the frames reach 2 past the original's text boxes.
        let inset = GoToRowView.cellInset
        // The intrinsic width is the text's alone: the cell's insets come on top of it.
        let hintWidth = hintLabel.isHidden ? 0 : ceil(hintLabel.intrinsicContentSize.width)
        hintLabel.frame = NSRect(
            x: labelX + labelWidth - hintWidth - inset, y: y, width: hintWidth + 2 * inset, height: labelHeight)
        let gap = hintLabel.isHidden ? 0 : CGFloat(layout.labelGap)
        listLabel.frame = NSRect(
            x: labelX - inset, y: y, width: max(0, labelWidth - hintWidth - gap) + 2 * inset, height: labelHeight)
        y += labelHeight + CGFloat(layout.labelBottom)
        let listBottom = bounds.height - footerHeight - CGFloat(layout.sectionBottom)
        let listHeight = max(0, min(CGFloat(layout.visibleRows) * rowHeight, listBottom - y))
        scroll.frame = NSRect(x: sectionX, y: y, width: sectionWidth, height: listHeight)
        let contentWidth = scroll.contentSize.width
        listContent.frame = NSRect(x: 0, y: 0, width: contentWidth, height: CGFloat(rowViews.count) * rowHeight)
        for view in rowViews {
            view.frame = NSRect(x: 0, y: CGFloat(view.index) * rowHeight, width: contentWidth, height: rowHeight)
        }
    }

    private func layoutFooter() {
        let layout = DialogLayout.GoTo.self
        let height = CGFloat(DesignTokens.controlHeights.regular)
        let y = CGFloat(layout.footerBorder + layout.footerTop)
        var right = footer.bounds.width - CGFloat(layout.footerHorizontal)
        for button in [submitButton, cancelButton] {
            let width = button.preferredWidth
            right -= width
            button.frame = NSRect(x: right, y: y, width: width, height: height)
            right -= CGFloat(layout.footerGap)
        }
        if let browseButton {
            browseButton.frame = NSRect(
                x: CGFloat(layout.footerHorizontal), y: y, width: browseButton.preferredWidth, height: height)
        }
    }
}

/// The footer's top line (`border-top: 1px solid var(--border-light)`).
@MainActor
final class GoToFooterView: NSView, ThemeApplying {
    private var theme = AppearanceModel.shared.theme
    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(theme.palette.borderLight).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(DialogLayout.GoTo.footerBorder)).fill()
    }
}
