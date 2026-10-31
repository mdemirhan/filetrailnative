// Port of the path editor of apps/desktop/src/renderer/components/ContentPane.tsx (:680-755), components/PathSuggestionDropdown.tsx and
// hooks/usePathSuggestions.ts, with .pathbar-input and .pathbar-suggestions (styles.css:2184-2265, 4417)
import AppKit
import FTFoundation

/// One row of the suggestions: the folder's name over (beside) its full path.
final class PathSuggestionRowView: NSView, TextStyleSource {
    var styleTextField: NSTextField? { name }
    let name = TextBoxField(labelWithString: "")
    let path = TextBoxField(labelWithString: "")
    var isActive = false { didSet { applyColors() } }
    private var isHovered = false { didSet { applyColors() } }
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}

    static let padding = (vertical: 6.0, horizontal: 10.0)
    static let gap = 14.0
    static let pathMinWidth = 160.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: 500)
        path.font = ThemeFonts.mono(DesignTokens.typeScale.mono)
        path.lineBreakMode = .byTruncatingTail
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityIdentifier("pathEditor.suggestion.name")
        path.setAccessibilityIdentifier("pathEditor.suggestion.path")
        addSubview(name)
        addSubview(path)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("pathEditor.suggestion")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    static func height() -> Double {
        let font = ThemeFonts.mono(DesignTokens.typeScale.mono)
        let nameFont = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: 500)
        let line = max(lineBox(font), lineBox(nameFont))
        return 2 * padding.vertical + line
    }

    func configure(_ row: PathSuggestionRow) {
        name.stringValue = row.name
        path.stringValue = row.path
        toolTip = row.path
        setAccessibilityLabel(row.name)
        applyColors()
    }

    func applyColors() {
        let theme = infoTheme
        let on = isActive
        name.textColor = NSColor(on ? theme.accent.onSolid : theme.palette.textPrimary)
        path.textColor = NSColor(on ? theme.accent.onSolid : theme.palette.textSecondary)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // grid-template-columns: minmax(0, 1fr) minmax(160px, 1.3fr); gap 14.
        let inner = max(0, bounds.width - 2 * Self.padding.horizontal - Self.gap)
        let pathWidth = max(Self.pathMinWidth, inner * 1.3 / 2.3)
        let nameWidth = max(0, inner - pathWidth)
        let nameHeight = lineBox(name.font)
        let pathHeight = lineBox(path.font)
        name.frame = NSRect(
            x: Self.padding.horizontal, y: (bounds.height - nameHeight) / 2, width: nameWidth, height: nameHeight)
        path.frame = NSRect(
            x: Self.padding.horizontal + nameWidth + Self.gap, y: (bounds.height - pathHeight) / 2, width: pathWidth,
            height: pathHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        if isActive {
            NSColor(theme.accent.solidButton).setFill()
        } else if isHovered {
            NSColor(theme.palette.bgHover).setFill()
        } else {
            return
        }
        NSBezierPath(roundedRect: bounds, xRadius: DesignTokens.radii.control, yRadius: DesignTokens.radii.control)
            .fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
            ))
    }

    // A row under a pointer that has not moved is not hovered, as in a browser (mouseenter follows a move).
    override func mouseMoved(with event: NSEvent) {
        guard !isHovered else { return }
        isHovered = true
        onHover()
    }

    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}

/// The dropdown over the editor: up to 12 rows in a bordered panel.
final class PathSuggestionsView: NSView {
    private let scroll = NSScrollView()
    private let document = InfoFlippedView()
    private(set) var rows: [PathSuggestionRowView] = []
    static let padding = 4.0
    var onHover: (Int) -> Void = { _ in }
    var onChoose: (Int) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("pathEditor.suggestions")
        setAccessibilityLabel("Path suggestions")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(_ suggestions: [PathSuggestionRow], highlighted: Int) {
        for row in rows { row.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = PathSuggestionRowView()
            row.configure(suggestion)
            row.onHover = { [weak self] in self?.onHover(index) }
            row.onClick = { [weak self] in self?.onChoose(index) }
            document.addSubview(row)
            return row
        }
        setHighlighted(highlighted)
        needsLayout = true
    }

    func setHighlighted(_ index: Int) {
        for (offset, row) in rows.enumerated() { row.isActive = offset == index }
        if rows.indices.contains(index) { document.scrollToVisible(rows[index].frame) }
    }

    func height(maxHeight: Double) -> Double {
        min(maxHeight, 2 * Self.padding + 2 + Double(rows.count) * PathSuggestionRowView.height())
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        let rowHeight = PathSuggestionRowView.height()
        var y = Self.padding
        for row in rows {
            row.frame = NSRect(
                x: Self.padding, y: y, width: max(0, scroll.bounds.width - 2 * Self.padding), height: rowHeight)
            y += rowHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: y + Self.padding)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLook()
    }

    func applyLook() {
        let palette = infoTheme.palette
        layer?.backgroundColor = ChromeColors.color(palette.dropdownBg).cgColor
        layer?.borderColor = ChromeColors.color(palette.border).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = DesignTokens.radii.menu
        layer?.masksToBounds = false
        // `--shadow-lg`. This view is flipped: a shadow's positive y is down, as in CSS.
        if let shadow = palette.shadowLg.first {
            layer?.shadowColor = NSColor(shadow.color.withAlpha(1)).cgColor
            layer?.shadowOpacity = Float(shadow.color.alpha)
            layer?.shadowRadius = CGFloat(shadow.blur / 2)
            layer?.shadowOffset = CGSize(width: shadow.x, height: shadow.y)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
        for row in rows { row.applyColors() }
    }
}

/// The text field of the editor: padding 0 10, the field fill and edge, 13 pt text.
final class PathEditorField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

/// The inline path editor that replaces the segments: a field, and its suggestions opening upward.
@MainActor
final class PathEditorView: NSView, NSTextFieldDelegate, TextStyleSource {
    var styleTextField: NSTextField? { field }
    let field = PathEditorField()
    private let suggestionsView = PathSuggestionsView()
    private let focusRing = CALayer()
    private(set) var state = PathSuggestionState(draft: "")
    private var currentPath = ""
    private var requestToken = 0
    private var debounce: DispatchWorkItem?
    /// The suggestion list has the "focus" (Tab from the field): ↑↓ move through it.
    private var listFocused = false
    private var editing = false
    /// The keyboard leaves the field with the row that had it: the editor stays.
    private var keyboardLeavesWithRow = false

    var onSubmit: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// The suggestions for a typed path (`~` already expanded).
    var requestSuggestions: @MainActor (String) async -> [PathSuggestionRow] = { _ in [] }
    var homePath = NSHomeDirectory()

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = ChromeColors.font(size: DesignTokens.typeScale.body)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityIdentifier("pathBar.editor.field")
        field.setAccessibilityLabel("Current folder path")
        addSubview(field)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(focusRing)
        setAccessibilityIdentifier("pathBar.editor")
        suggestionsView.onHover = { [weak self] index in self?.previewFromList(index) }
        suggestionsView.onChoose = { [weak self] index in self?.acceptRow(index, fromKeyboard: false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Opening and closing

    func open(currentPath path: String) {
        currentPath = path
        editing = true
        state = PathSuggestionState(draft: path)
        listFocused = false
        field.stringValue = path
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: path.utf16.count, length: 0)
        scheduleRequest(path)
        applyColors()
        needsDisplay = true
    }

    func close() {
        guard editing else { return }
        editing = false
        debounce?.cancel()
        requestToken += 1
        hideSuggestions()
        state = PathSuggestionState(draft: currentPath)
    }

    // MARK: Suggestions

    private func scheduleRequest(_ input: String) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.request(input) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.suggestionDebounce, execute: work)
    }

    private func request(_ input: String) {
        requestToken += 1
        let token = requestToken
        let expanded = PathText2.expandHome(input.trimmingCharacters(in: .whitespacesAndNewlines), homePath: homePath)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let rows = await self.requestSuggestions(expanded)
            guard self.editing, self.requestToken == token, self.state.draft == input else { return }
            self.state.receive(rows)
            self.listFocused = false
            self.showSuggestions()
            self.field.stringValue = self.state.displayed
        }
    }

    private func showSuggestions() {
        guard let host = window?.contentView, !state.suggestions.isEmpty else {
            hideSuggestions()
            return
        }
        suggestionsView.show(state.suggestions, highlighted: state.highlighted)
        // Above the editor: its bottom 4 pt over the field, the field's width; at most 360 tall.
        let rect = convert(bounds, to: host)
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let maxHeight = min(InfoMetrics.suggestionsMaxHeight, host.bounds.height - 180)
        let height = suggestionsView.height(maxHeight: maxHeight)
        let y = top - InfoMetrics.suggestionsGap - height
        suggestionsView.frame = NSRect(
            x: rect.minX, y: host.isFlipped ? y : host.bounds.height - y - height, width: rect.width, height: height)
        if suggestionsView.superview !== host { host.addSubview(suggestionsView) }
        suggestionsView.needsLayout = true
    }

    private func hideSuggestions() {
        suggestionsView.removeFromSuperview()
    }

    var suggestionsAreShown: Bool { suggestionsView.superview != nil }

    private func clearSuggestions() {
        state.clear()
        hideSuggestions()
        field.stringValue = state.displayed
        listFocused = false
    }

    private func preview(_ index: Int) {
        state.previewSuggestion(index)
        suggestionsView.setHighlighted(state.highlighted)
        field.stringValue = state.displayed
        if let range = state.previewSelection { field.currentEditor()?.selectedRange = range }
    }

    private func previewFromList(_ index: Int) {
        guard state.highlighted != index else { return }
        state.previewSuggestion(index)
        suggestionsView.setHighlighted(index)
        field.stringValue = state.displayed
    }

    /// `acceptSuggestion`. A click never took the keyboard from the field. Return was on the row, in the original a
    /// button that has the focus and goes with the list: the field isn't given it back (no `refocusInputOnAccept`), so
    /// the editor stays open with no keyboard until the field is clicked.
    private func acceptRow(_ index: Int, fromKeyboard: Bool) {
        guard state.suggestions.indices.contains(index) else { return }
        let row = state.suggestions[index]
        state.accept(row)
        hideSuggestions()
        if fromKeyboard {
            keyboardLeavesWithRow = true
            window?.makeFirstResponder(nil)
            keyboardLeavesWithRow = false
        }
        field.stringValue = state.draft
        field.currentEditor()?.selectedRange = NSRange(location: state.draft.utf16.count, length: 0)
        listFocused = false
        needsDisplay = true
        scheduleRequest(state.draft)
    }

    // MARK: Field events

    func controlTextDidChange(_ notification: Notification) {
        guard editing else { return }
        let value = field.stringValue
        state.setDraft(value)
        hideSuggestions()
        listFocused = false
        scheduleRequest(value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard editing, !keyboardLeavesWithRow else { return }
        // The editor goes with the field's focus (a click on a suggestion does not take it).
        let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSTextMovement.return.rawValue { return }
        finish()
    }

    private func finish() {
        guard editing else { return }
        close()
        onClose()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let suggestions = state.suggestions
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if listFocused {
                clearSuggestions()
                return true
            }
            if !suggestions.isEmpty || state.preview != nil {
                clearSuggestions()
                return true
            }
            finish()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !suggestions.isEmpty else { return false }
            let down = selector == #selector(NSResponder.moveDown(_:))
            if listFocused {
                let next =
                    state.highlighted < 0
                    ? 0
                    : (down
                        ? (state.highlighted + 1) % suggestions.count
                        : (state.highlighted - 1 + suggestions.count) % suggestions.count)
                preview(next)
                return true
            }
            if let next = state.nextIndex(down: down) { preview(next) }
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            if listFocused {
                listFocused = false
                return true
            }
            guard !suggestions.isEmpty else { return false }
            listFocused = true
            preview(selector == #selector(NSResponder.insertBacktab(_:)) ? suggestions.count - 1 : 0)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if listFocused, state.suggestions.indices.contains(state.highlighted) {
                acceptRow(state.highlighted, fromKeyboard: true)
                return true
            }
            submit()
            return true
        default:
            return false
        }
    }

    private func submit() {
        guard let target = state.submission else { return }
        close()
        onSubmit(target)
    }

    // MARK: Look

    func applyColors() {
        field.textColor = NSColor(infoTheme.palette.textPrimary)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let font = field.font ?? .systemFont(ofSize: 13)
        let height = lineBox(font)
        // A field keeps 2 pt before its text: the text starts at the padding, 10.
        let inset = 10.0 - 2
        field.frame = NSRect(
            x: inset, y: (bounds.height - height) / 2, width: max(0, bounds.width - 2 * inset), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        let radius = DesignTokens.radii.control
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(theme.palette.fieldBg).setFill()
        shape.fill()
        // `--field-edge`, focused or not: an inset hairline.
        for layer in theme.palette.fieldEdge where layer.blur == 0 {
            NSColor(layer.color).setStroke()
            let inset = layer.spread / 2
            let edge = NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
            edge.lineWidth = layer.spread
            edge.stroke()
        }
        updateFocusRing(theme)
    }

    /// `--focus-ring`: 3 pt outside the field, in a layer since it reaches past the view.
    private func updateFocusRing(_ theme: Theme) {
        let focused = field.currentEditor() != nil && window?.firstResponder === field.currentEditor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = CGFloat(DesignTokens.focusRingWidth)
        focusRing.isHidden = !focused
        focusRing.frame = bounds.insetBy(dx: -width, dy: -width)
        focusRing.borderWidth = width
        focusRing.cornerRadius = DesignTokens.radii.control + width
        focusRing.borderColor = NSColor(theme.accent.solid.withAlpha(0.5)).cgColor
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}
