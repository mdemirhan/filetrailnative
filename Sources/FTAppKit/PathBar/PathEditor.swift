import AppKit
import FTFileSystem
import FTFoundation

/// The suggestions over the editor: Go To's folder rows on a menu's material, as wide as the rows need.
final class PathSuggestionsView: NSView, GoToRowOwner {
    private let material = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let document = InfoFlippedView()
    private(set) var rows: [GoToRowView] = []
    /// Around the rows, as a menu has.
    static let padding = 5.0
    static let minWidth = 280.0
    static let maxWidth = 520.0
    static var rowHeight: Double { DesignTokens.controlHeights.regular }
    static var radius: Double { DesignTokens.radii.menu }
    var onHover: (Int) -> Void = { _ in }
    var onChoose: (Int) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("pathEditor.suggestions")
        setAccessibilityLabel("Path suggestions")
        material.material = .menu
        material.blendingMode = .withinWindow
        material.state = .active
        material.maskImage = Self.mask(radius: Self.radius)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        addSubview(material)
        material.addSubview(scroll)
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The material's rounded shape, stretched to any size.
    private static func mask(radius: Double) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// A folder's row: its name, and the folder it is in with the home folder as "~".
    static func row(_ suggestion: PathSuggestionRow, homePath: String) -> GoToRow {
        let shown = Places.abbreviate(suggestion.path, homePath: homePath)
        return GoToRow(
            path: suggestion.path, name: suggestion.name,
            detail: Places.describeLocation(name: suggestion.name, displayPath: shown), nameRanges: [],
            isFavorite: false, canForget: false)
    }

    func show(_ suggestions: [PathSuggestionRow], highlighted: Int, homePath: String) {
        for row in rows { row.removeFromSuperview() }
        let theme = infoTheme
        rows = suggestions.enumerated().map { index, suggestion in
            let row = GoToRowView(
                index: index, row: Self.row(suggestion, homePath: homePath), theme: theme,
                identifier: "pathEditor.suggestion")
            row.owner = self
            document.addSubview(row)
            return row
        }
        setHighlighted(highlighted)
        needsLayout = true
    }

    func setHighlighted(_ index: Int) {
        for row in rows { row.isSelected = row.index == index }
        if rows.indices.contains(index) { document.scrollToVisible(rows[index].frame) }
    }

    func height(maxHeight: Double) -> Double {
        min(maxHeight, 2 * Self.padding + Double(rows.count) * Self.rowHeight)
    }

    /// As wide as the widest row, from 280 to 520.
    func fittingWidth() -> Double {
        let widest = rows.map { Double($0.fittingWidth) }.max() ?? 0
        return min(Self.maxWidth, max(Self.minWidth, widest + 2 * Self.padding))
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        scroll.frame = bounds
        var y = Self.padding
        for row in rows {
            row.frame = NSRect(
                x: Self.padding, y: y, width: max(0, scroll.bounds.width - 2 * Self.padding), height: Self.rowHeight)
            y += Self.rowHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: y + Self.padding)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }

    /// A menu's edge and shadow, the edge drawn over the material.
    func applyLook() {
        let theme = infoTheme
        MenuSurface.apply(to: layer, theme: theme, borderWidth: 0.5)
        layer?.cornerRadius = Self.radius
        for row in rows { row.applyTheme(theme) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    // MARK: The rows

    func pointerMoved(over index: Int, at point: CGPoint) { onHover(index) }
    func rowClicked(_ index: Int) { onChoose(index) }
    /// The first click chose the folder and closed the list.
    func rowDoubleClicked(_ index: Int) {}
}

/// The text field of the editor: the path bar's 11 pt text, on the field fill and edge the editor draws.
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
    private var debounce: TimerToken?
    /// What waits out the debounce; tests move it by hand.
    var timers: any TimerScheduling = TaskTimerScheduler()
    /// The suggestion list has the "focus" (Tab from the field): ↑↓ move through it.
    private var listFocused = false
    private var editing = false
    /// The keyboard leaves the field with the row that had it: the editor stays.
    private var keyboardLeavesWithRow = false

    var onSubmit: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// The suggestions for a typed path (`~` already expanded).
    var requestSuggestions: @MainActor (String) async -> [PathSuggestionRow] = { _ in [] }
    var homePath = DiskPath.home.string

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = PathSegmentView.font
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
        putCaretAtEnd(of: path)
        scheduleRequest(path)
        applyColors()
        needsDisplay = true
    }

    /// The caret after the last character, and that end on screen: a path longer than the field showed its start,
    /// with the folder being typed out of sight.
    private func putCaretAtEnd(of text: String) {
        guard let editor = field.currentEditor() else { return }
        let end = NSRange(location: text.utf16.count, length: 0)
        editor.selectedRange = end
        editor.scrollRangeToVisible(end)
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
        debounce = timers.schedule(after: InfoMetrics.suggestionDebounce) { [weak self] in self?.request(input) }
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
        suggestionsView.show(state.suggestions, highlighted: state.highlighted, homePath: homePath)
        // Above the field: its bottom 4 pt over the field, its left edge the field's, as wide as the rows need but
        // never wider than the field; at most 360 tall.
        let rect = convert(shellRect, to: host)
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let maxHeight = min(InfoMetrics.suggestionsMaxHeight, host.bounds.height - 180)
        let height = suggestionsView.height(maxHeight: maxHeight)
        let width = min(suggestionsView.fittingWidth(), rect.width)
        let y = top - InfoMetrics.suggestionsGap - height
        suggestionsView.frame = NSRect(
            x: rect.minX, y: host.isFlipped ? y : host.bounds.height - y - height, width: width, height: height)
        if suggestionsView.superview !== host { host.addSubview(suggestionsView) }
        suggestionsView.needsLayout = true
    }

    private func hideSuggestions() {
        suggestionsView.removeFromSuperview()
    }

    var suggestionsAreShown: Bool { suggestionsView.superview != nil }

    /// Where the suggestions show in the window's content view, while they show.
    var suggestionsFrame: NSRect? { suggestionsAreShown ? suggestionsView.frame : nil }

    /// The editor moved in the window (Swap Panes): the suggestions open above it where it is now.
    func editorMoved() {
        if suggestionsAreShown { showSuggestions() }
    }

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

    /// A click never took the keyboard from the field. Return was on the row, which has the focus and goes with the
    /// list: the field isn't given it back, so the editor stays open with no keyboard until the field is clicked.
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
        putCaretAtEnd(of: state.draft)
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

    /// The field's height: a small control's, 2 short of a segment, so its focus ring clears the bar's edges.
    static let fieldHeight = 18.0

    /// The field's shape: across the editor, in the middle of the bar. The editor is the bar's height, so the focus
    /// ring around it stays inside the bar.
    var shellRect: NSRect {
        let height = Self.fieldHeight
        return NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }

    override func layout() {
        super.layout()
        let font = field.font ?? PathSegmentView.font
        let height = lineBox(font)
        let shell = shellRect
        // The text starts where a segment's did; a field's cell draws its text 2 in from its frame.
        let inset = InfoMetrics.segmentPaddingInline - 2
        field.frame = NSRect(
            x: shell.minX + inset, y: shell.minY + (shell.height - height) / 2,
            width: max(0, shell.width - 2 * inset), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        let radius = DesignTokens.radii.control
        let shell = shellRect
        NSColor(theme.palette.fieldBg).setFill()
        NSBezierPath(roundedRect: shell, xRadius: radius, yRadius: radius).fill()
        // The field's edge (the theme's `fieldEdge`), focused or not: an inset hairline.
        for layer in theme.palette.fieldEdge where layer.blur == 0 && layer.spread > 0 {
            NSColor(layer.color).setStroke()
            let inset = layer.spread / 2
            let edge = NSBezierPath(
                roundedRect: shell.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
            edge.lineWidth = layer.spread
            edge.stroke()
        }
        updateFocusRing(theme)
    }

    /// The focus ring: 3 pt outside the field, in a layer since it reaches past the field's shape.
    private func updateFocusRing(_ theme: Theme) {
        let focused = field.currentEditor() != nil && window?.firstResponder === field.currentEditor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = CGFloat(DesignTokens.focusRingWidth)
        focusRing.isHidden = !focused
        focusRing.frame = shellRect.insetBy(dx: -width, dy: -width)
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
