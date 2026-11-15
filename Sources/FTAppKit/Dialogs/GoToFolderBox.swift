import AppKit
import FTFoundation

/// What a Go To box is for: Go To itself, or a folder for items to go into (Move To, Extract To) with its title,
/// words and Choose….
struct GoToBoxOptions {
    var purpose = GoToPurpose.goTo
    /// Shown above the field; Go To has none.
    var title: String?
    var fieldLabel = "Folder name or path"
    var submitLabel = "Open"
    /// Choose…: the system's folder picker, from a path; nil when there is no such button.
    var browse: (@MainActor (String) async -> String?)?
    /// The folder shown when the box opened: where Choose… starts with no path typed, and what "./" and "../" start
    /// from.
    var currentPath = ""
    /// What the field holds when the box opens, all of it selected, so typing replaces it.
    var initialText = ""
    var homePath = FileManager.default.homeDirectoryForCurrentUser.path

    static func goTo(currentPath: String) -> GoToBoxOptions { GoToBoxOptions(currentPath: currentPath) }

    /// A box for choosing where items go: it opens on the folder shown, as "~/…/Folder/", so the folders inside it
    /// are listed and Return sends the items there.
    static func chooseFolder(
        title: String, submitLabel: String, currentPath: String,
        browse: @escaping @MainActor (String) async -> String?
    ) -> GoToBoxOptions {
        var options = GoToBoxOptions(
            purpose: .chooseFolder, title: title, fieldLabel: "Destination folder", submitLabel: submitLabel,
            browse: browse, currentPath: currentPath)
        if !currentPath.isEmpty {
            let shown = Places.abbreviate(currentPath, homePath: options.homePath)
            options.initialText = shown.hasSuffix("/") ? shown : shown + "/"
        }
        return options
    }

    static func moveTo(
        _ paths: [String], currentPath: String, browse: @escaping @MainActor (String) async -> String?
    ) -> GoToBoxOptions {
        chooseFolder(
            title: title("Move", paths, items: "Items"), submitLabel: "Move", currentPath: currentPath, browse: browse)
    }

    static func extractTo(
        _ paths: [String], currentPath: String, browse: @escaping @MainActor (String) async -> String?
    ) -> GoToBoxOptions {
        chooseFolder(
            title: title("Extract", paths, items: "Archives"), submitLabel: "Extract", currentPath: currentPath,
            browse: browse)
    }

    /// "Move “Report.pdf” To", "Move 3 Items To".
    static func title(_ verb: String, _ paths: [String], items: String) -> String {
        if paths.count == 1 { return "\(verb) \u{201C}\(NodePath.basename(paths[0]))\u{201D} To" }
        return "\(verb) \(paths.count) \(items) To"
    }
}

/// The Go To box (⌘K, ⇧⌘G), and the Move To and Extract To boxes: a panel dropped below the toolbar with a field, the
/// folders that match and the footer's buttons.
@MainActor
final class GoToFolderBox: DialogPanelView, NSTextFieldDelegate {
    static let placeholder = "Folder name, or a path starting with / or ~"
    /// Where the pointer last was over a box's list, by window: kept across opens, and let go of with the window.
    private static let lastPointers = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()

    #if DEBUG
        /// How many windows a pointer is remembered for (tests).
        static var rememberedPointerCount: Int { lastPointers.keyEnumerator().allObjects.count }
    #endif

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
    let footer = DialogFooterLine(thickness: DialogLayout.GoTo.footerBorder)
    let browseButton: SystemButton?
    let cancelButton = SystemButton(title: "Cancel")
    let submitButton: SystemButton
    private(set) var rowViews: [GoToRowView] = []
    private var browsing = false
    private weak var pointerWindow: NSWindow?

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
        places: [Place], options: GoToBoxOptions, timers: any TimerScheduling,
        requestCompletions: @escaping @MainActor (String) async -> [GoToCompletion]?
    ) {
        self.options = options
        state = GoToBoxState(
            places: places, purpose: options.purpose, canForgetPlaces: true, homePath: options.homePath,
            text: options.initialText)
        requests = PathCompletionRequests(timers: timers, request: requestCompletions)
        shell = GoToFieldShell(label: options.fieldLabel)
        if let title = options.title {
            let label = NSTextField(labelWithString: title)
            label.font = Self.titleFont
            label.lineBreakMode = .byTruncatingMiddle
            label.setAccessibilityIdentifier("goToFolder.title")
            titleLabel = label
        } else {
            titleLabel = nil
        }
        browseButton = options.browse == nil ? nil : SystemButton(title: "Choose…")
        submitButton = SystemButton(title: options.submitLabel)
        super.init(cornerRadius: GlassSurface.sheetRadius)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(options.title ?? "Go To")
        setAccessibilityIdentifier("goToFolder")
        if let titleLabel { addSubview(titleLabel) }
        addSubview(shell)
        shell.field.delegate = self
        shell.field.stringValue = state.text
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

    var field: GoToField { shell.field }

    // MARK: Opening

    /// The box is up over `window`, the field focused: Go To starts empty with the caret in the field; a box choosing
    /// a folder starts on the folder shown, selected, and asks for the folders inside it after the pause.
    func opened(in window: NSWindow) {
        pointerWindow = window
        state.lastPointer = Self.lastPointers.object(forKey: window)?.pointValue
        requests.setOpen(true)
        if state.isPathMode { requests.requestNow(state.text) }
        focusField()
        if !options.initialText.isEmpty, let editor = field.currentEditor() as? NSTextView {
            let length = (field.stringValue as NSString).length
            editor.selectedRange = NSRange(location: 0, length: length)
            // A long path shows its end, the folder's name, rather than its start.
            editor.scrollRangeToVisible(NSRange(location: length, length: 0))
        }
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

    /// The typed folder doesn't exist: the footer's button makes it first, and `notice` says so under the field.
    func offerToCreate(notice: String, for submitted: String) {
        state.offerToCreate(notice: notice, for: submitted)
        render()
    }

    /// The places read again: the rows follow at once.
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

    override var initialResponder: NSView? { field }

    override func handleKey(_ event: NSEvent) -> Bool {
        if KeyCode.isCancel(event) {
            // A folder shown in the field gives way to what was typed first; a second Escape closes the box.
            if state.escape() {
                render()
            } else {
                onClose()
            }
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

    /// A double click: the items go into the folder. Go To went there on the first click.
    func rowDoubleClicked(_ index: Int) {
        guard options.purpose == .chooseFolder else { return }
        apply(state.doubleClick(index))
    }

    func pointerMoved(over index: Int, at point: CGPoint) {
        state.pointerMoved(over: index, at: point)
        if let pointerWindow { Self.lastPointers.setObject(NSValue(point: point), forKey: pointerWindow) }
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

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        titleLabel?.textColor = NSColor(theme.palette.textPrimary)
        styleLabels()
        shell.applyTheme(theme)
        footer.applyTheme(theme)
        for button in [cancelButton, submitButton] + [browseButton].compactMap({ $0 }) { button.applyTheme(theme) }
        for row in rowViews { row.applyTheme(theme) }
    }

    /// Shows the state: the ✕, the error, the label and hint, the rows or the empty text, and what the buttons allow.
    func render() {
        // The field follows the state when a row is shown in it or let go of; while typing they already agree.
        if field.stringValue != state.text { setField(state.text) }
        shell.clearButton.isHidden = !state.showsClear
        let notice = state.createsFolder ? state.folderToCreate?.notice : nil
        errorLabel.stringValue = state.error ?? notice ?? ""
        errorLabel.isHidden = state.error == nil && notice == nil
        submitButton.title = state.createsFolder ? "Create and \(options.submitLabel)" : options.submitLabel
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

    /// The labels' text in their colors.
    private func styleLabels() {
        let palette = theme.palette
        let labels: [(NSTextField, RGBA)] = [
            (errorLabel, state.error == nil ? palette.textSecondary : palette.dangerText),
            (listLabel, palette.textSecondary), (hintLabel, palette.textSecondary),
            (emptyLabel, palette.textSecondary),
        ]
        for (label, color) in labels {
            label.textColor = NSColor(color)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = label.alignment
            paragraph.lineBreakMode = label.lineBreakMode
            label.attributedStringValue = NSAttributedString(
                string: label.stringValue,
                attributes: [
                    .font: label.font ?? Self.hintFont, .foregroundColor: NSColor(color), .paragraphStyle: paragraph,
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

    override func panelSize(in size: NSSize) -> NSSize {
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
            // A label's cell draws its text 2 in, so its frame starts 2 early; the line takes the font's rounded 15,
            // the
            // frame its own.
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
        // The labels' cells draw their text 2 in from their frames: the frames reach 2 past where the text goes.
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
        layoutButtonRow(
            [cancelButton, submitButton], right: footer.bounds.width - CGFloat(layout.footerHorizontal), y: y,
            height: height, gap: CGFloat(layout.footerGap))
        if let browseButton {
            browseButton.frame = NSRect(
                x: CGFloat(layout.footerHorizontal), y: y, width: browseButton.preferredWidth, height: height)
        }
    }
}
