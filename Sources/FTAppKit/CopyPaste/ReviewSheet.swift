// Port of apps/desktop/src/renderer/components/CopyPasteReviewDialog.tsx (the sheet, AllConflictsButtons and
// ReviewRowItem) with the .copy-paste-sheet-bar and .copy-paste-sheet-row rules of styles.css
import AppKit
import FTFoundation
import FTOperations

/// The review's state (`copyPasteDialogState` of type `review` with the dialog's own): the choices for all conflicts
/// and per item, what is shown, and whether it is starting.
@MainActor
final class ReviewSheetModel {
    let report: CopyPasteAnalysisReport
    let review: ReviewReport
    let action: CopyLikeAction
    private(set) var policy: CopyPastePolicy
    private(set) var overrides: ReviewOverrides = [:]
    var showNewItems = false { didSet { refresh() } }
    var showAllRows = false { didSet { refresh() } }
    /// The rows' dates are written relative to when the sheet opened.
    let now: Double
    private(set) var summary = ReviewSummary()
    private(set) var rows: [ReviewRow] = []
    private(set) var text: ReviewSheetText
    private(set) var allConflicts: AllConflictsChoice?
    var onChange: () -> Void = {}

    init(report: CopyPasteAnalysisReport, action: CopyLikeAction, policy: CopyPastePolicy, now: Double) {
        self.report = report
        review = ReviewReport(report)
        self.action = action
        self.policy = policy
        self.now = now
        let summary = CopyPasteReview.summarize(review, policy: policy, overrides: [:])
        text = ReviewSheetText(review, action: action, summary: summary)
        refresh()
    }

    var verb: String { CopyPasteReview.actionVerb(action, mode: review.mode) }
    var hasConflicts: Bool { summary.conflictTopLevelCount > 0 }
    /// The rows drawn: the first 300 until "Show all".
    var visibleRows: ArraySlice<ReviewRow> {
        showAllRows ? rows[...] : rows.prefix(CopyPasteSheetLayout.initialRowLimit)
    }
    var hiddenRowCount: Int { rows.count - visibleRows.count }

    /// "For all conflicts": the policy, and no choice per item.
    func choose(_ choice: AllConflictsChoice) {
        policy = CopyPasteReview.policy(for: choice)
        overrides = [:]
        refresh()
    }

    /// A row's choice (`setChoice`).
    func choose(_ choice: CopyPasteChoice, for node: ReviewNode) {
        overrides = CopyPasteReview.overrides(setting: choice, for: node, policy: policy, overrides: overrides)
        refresh()
    }

    private func refresh() {
        summary = CopyPasteReview.summarize(review, policy: policy, overrides: overrides)
        rows = CopyPasteReview.rows(
            review, policy: policy, overrides: overrides, showNewItems: showNewItems || !hasConflicts, now: now)
        text = ReviewSheetText(review, action: action, summary: summary)
        allConflicts = CopyPasteReview.currentAllConflictsChoice(review, policy, overrides)
        onChange()
    }

    /// The overrides the paste is started with.
    var nodeOverrides: [CopyPasteNodeOverride] {
        overrides.sorted { $0.key < $1.key }.map { CopyPasteNodeOverride(nodeId: $0.key, action: $0.value) }
    }
}

/// The review sheet (`CopyPasteReviewDialog`): the items that already exist at the destination (or a very large
/// operation), each with what will happen to it. Nothing is replaced unless Replace is picked, and the start button
/// says so when it is.
@MainActor
final class CopyPasteReviewSheet: CopyPasteSheetView {
    let model: ReviewSheetModel
    let bar: ReviewBarView?
    let cancelButton = SystemButton(title: "Cancel")
    let primaryButton = SystemButton(title: "")
    private var rowViews: [String: ReviewRowView] = [:]
    private var shownRows: [ReviewRowView] = []
    private let moreLink = SheetLink(title: "")
    /// Closes it, nothing started.
    var onClose: () -> Void = {}
    /// Starts with the choices on screen.
    var onStart: () -> Void = {}
    /// Whether it is starting: the start button is busy (disabled) until the start failed.
    var starting = false {
        didSet {
            primaryButton.isEnabled = !starting
            primaryButton.setAccessibilityValue(starting ? "busy" : nil)
        }
    }

    init(model: ReviewSheetModel) {
        self.model = model
        bar = model.hasConflicts ? ReviewBarView(model: model) : nil
        super.init(identifier: "reviewSheet")
        if let bar {
            addSubview(bar)
            bar.onChoose = { [weak self] in self?.model.choose($0) }
            bar.onToggleNewItems = { [weak self] in
                guard let self else { return }
                self.model.showNewItems.toggle()
            }
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.setAccessibilityIdentifier("reviewSheet.cancel")
        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed(_:))
        primaryButton.setAccessibilityIdentifier("reviewSheet.primary")
        buttons = [cancelButton, primaryButton]
        moreLink.target = self
        moreLink.action = #selector(showAllPressed(_:))
        moreLink.setAccessibilityIdentifier("reviewSheet.showAll")
        list.addSubview(moreLink)
        model.onChange = { [weak self] in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Draws what the model says now.
    func update() {
        let text = model.text
        setTitle(text.title, message: text.message)
        primaryButton.title = text.primaryLabel
        primaryButton.isDefault = !text.replacing
        primaryButton.isDestructive = text.replacing
        note.set(text.note, warning: text.noteIsWarning)
        bar?.update()
        var next: [String: ReviewRowView] = [:]
        shownRows = model.visibleRows.map { row in
            let view = rowViews[row.id] ?? ReviewRowView()
            if view.superview !== list { list.addSubview(view) }
            view.configure(row, addsLabel: text.addsLabel) { [weak self] choice in
                self?.model.choose(choice, for: row.node)
            }
            next[row.id] = view
            return view
        }
        for (id, view) in rowViews where next[id] == nil { view.removeFromSuperview() }
        rowViews = next
        moreLink.title = ReviewSheetText.showAll(model.rows.count)
        moreLink.isHidden = model.hiddenRowCount == 0
        showsList = !model.rows.isEmpty
        contentChanged()
        applyTheme(theme, throughSubviews: true)
    }

    var rowViewsShown: [ReviewRowView] { shownRows }

    // MARK: Layout

    override func barHeight(forWidth width: CGFloat) -> CGFloat {
        bar?.height(forWidth: width) ?? 0
    }

    override func layoutBar(in rect: NSRect) {
        bar?.frame = rect
    }

    override func layoutRows(width: CGFloat) -> CGFloat {
        var y = listInsets.top
        var separators: [CGFloat] = []
        var tintedSeparators: [CGFloat] = []
        // `.copy-paste-sheet-row + .copy-paste-sheet-row`: each row after the first starts with its 1 pt line.
        let line = CGFloat(CopyPasteSheetLayout.border)
        for (index, view) in shownRows.enumerated() {
            if index > 0 {
                separators.append(y)
                // The line is the row's top border: a row marked Replace has its tint under it too.
                if view.isReplacing { tintedSeparators.append(y) }
                y += line
            }
            let height = view.height(forWidth: width)
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        if !moreLink.isHidden {
            if !shownRows.isEmpty {
                separators.append(y)
                y += line
            }
            let layout = CopyPasteSheetLayout.self
            let size = moreLink.preferredSize
            moreLink.frame = NSRect(
                x: CGFloat(layout.rowHorizontal), y: y + CGFloat(layout.rowVertical), width: size.width,
                height: size.height)
            y += size.height + 2 * CGFloat(layout.rowVertical)
        }
        list.separators = separators
        list.tintedSeparators = tintedSeparators
        return y - listInsets.top
    }

    // MARK: Keys

    override func focusOrder() -> [NSView] {
        var order: [NSView] = []
        if let bar { order += bar.focusOrder() }
        order += shownRows.compactMap { $0.popUp.isHidden ? nil : $0.popUp }
        if !moreLink.isHidden { order.append(moreLink) }
        return order + buttons.filter(\.isEnabled)
    }

    override var initialResponder: NSView? { primaryButton.isEnabled ? primaryButton : cancelButton }

    override func handleKey(_ event: NSEvent) -> Bool {
        if KeyCode.isCancel(event) {
            onClose()
            return true
        }
        if super.handleKey(event) { return true }
        guard KeyCode.isReturn(event), event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        let responder = window?.firstResponder
        // Other controls (menus, Cancel, links) handle Return themselves.
        if responder !== primaryButton {
            if let button = responder as? SystemButton {
                button.perform()
                return true
            }
            if let link = responder as? SheetLink {
                link.perform()
                return true
            }
            if responder is NSPopUpButton || responder is AllConflictsControl { return true }
        }
        // Return starts the operation, unless it replaces something: that takes a click (or Space) on the red
        // button, so it never happens by reflex.
        if !model.text.replacing, primaryButton.isEnabled { onStart() }
        return true
    }

    @objc private func cancelPressed(_ sender: Any?) { onClose() }
    @objc private func primaryPressed(_ sender: Any?) { onStart() }
    @objc private func showAllPressed(_ sender: Any?) { model.showAllRows = true }
}

/// "For all conflicts:", its buttons, the new items' link and the hint (`.copy-paste-sheet-bar`).
@MainActor
final class ReviewBarView: NSView, ThemeApplying {
    let label: ThemedText
    let control: AllConflictsControl
    let link = SheetLink(title: "")
    let hint: ThemedText
    private let model: ReviewSheetModel
    private var theme = AppearanceModel.shared.theme
    var onChoose: (AllConflictsChoice) -> Void = { _ in }
    var onToggleNewItems: () -> Void = {}
    private let hintStyle: TextStyle

    init(model: ReviewSheetModel) {
        self.model = model
        var labelStyle = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.body, .medium), color: { $0.palette.textPrimary })
        labelStyle.background = { $0.palette.bgElevated }
        label = ThemedText(ReviewSheetText.allConflictsLabel, style: labelStyle)
        control = AllConflictsControl(
            choices: CopyPasteReview.allConflictsChoices(model.review), value: model.allConflicts)
        var hintStyle = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.callout), color: { $0.palette.textSecondary })
        hintStyle.background = { $0.palette.bgElevated }
        self.hintStyle = hintStyle
        hint = ThemedText("", style: hintStyle, wrapping: true)
        super.init(frame: .zero)
        setAccessibilityIdentifier("reviewSheet.bar")
        hint.setAccessibilityIdentifier("reviewSheet.hint")
        link.setAccessibilityIdentifier("reviewSheet.newItems")
        addSubview(label)
        addSubview(control)
        addSubview(link)
        addSubview(hint)
        control.onChange = { [weak self] in self?.onChoose($0) }
        link.target = self
        link.action = #selector(linkPressed(_:))
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func update() {
        control.value = model.allConflicts
        let hintText = CopyPasteReview.describe(model.allConflicts, model.review)
        let style = hintStyle
        hint.content = { style.string(hintText, $0) }
        if let show = model.text.showNewItemsLabel {
            link.isHidden = false
            link.title = model.showNewItems ? ReviewSheetText.hideNewItems : show
            link.setAccessibilityExpanded(model.showNewItems)
        } else {
            link.isHidden = true
        }
        needsLayout = true
    }

    func focusOrder() -> [NSView] {
        [control.tabStop].compactMap { $0 } + (link.isHidden ? [] : [link])
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    private var firstLineHeight: CGFloat {
        max(control.preferredSize.height, ceil(label.height(forWidth: 10_000)), link.preferredSize.height)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let layout = CopyPasteSheetLayout.self
        let inner = max(0, width - 2 * CGFloat(layout.barHorizontal))
        return 2 * CGFloat(layout.border) + 2 * CGFloat(layout.barVertical) + firstLineHeight
            + CGFloat(layout.barRowGap) + hint.normalLineBoxHeight(forWidth: inner)
    }

    override func layout() {
        super.layout()
        let layout = CopyPasteSheetLayout.self
        let inner = max(0, bounds.width - 2 * CGFloat(layout.barHorizontal))
        let top = CGFloat(layout.border + layout.barVertical)
        let line = firstLineHeight
        var x = CGFloat(layout.barHorizontal)
        let labelWidth = label.naturalWidth
        let labelHeight = ceil(label.height(forWidth: 10_000))
        label.frame = NSRect(x: x, y: top + (line - labelHeight) / 2, width: labelWidth, height: labelHeight)
        x += labelWidth + CGFloat(layout.barColumnGap)
        let size = control.preferredSize
        control.frame = NSRect(x: x, y: top + (line - size.height) / 2, width: size.width, height: size.height)
        let linkSize = link.preferredSize
        link.frame = NSRect(
            x: CGFloat(layout.barHorizontal) + inner - linkSize.width, y: top + (line - linkSize.height) / 2,
            width: linkSize.width, height: linkSize.height)
        let hintHeight = ceil(hint.height(forWidth: inner))
        hint.frame = NSRect(
            x: CGFloat(layout.barHorizontal), y: top + line + CGFloat(layout.barRowGap), width: inner,
            height: hintHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        // color-mix(in srgb, var(--neutral-ink) 2.5%, transparent) over the sheet.
        NSColor(palette.neutralInk.withAlpha(CopyPasteSheetLayout.barInkAlpha)).setFill()
        bounds.fill(using: .sourceOver)
        NSColor(palette.borderLight).setFill()
        let line = CGFloat(CopyPasteSheetLayout.border)
        NSRect(x: 0, y: 0, width: bounds.width, height: line).fill(using: .sourceOver)
        NSRect(x: 0, y: bounds.height - line, width: bounds.width, height: line).fill(using: .sourceOver)
    }

    @objc private func linkPressed(_ sender: Any?) { onToggleNewItems() }
}

/// One item of the review (`ReviewRowItem`): its glyph, name ("→ new name" when kept next to the existing one),
/// where it is when nested deeper than the indent, what will happen to it, and its choice (or "Adds").
@MainActor
final class ReviewRowView: NSView, ThemeApplying {
    let glyph = SheetGlyphView(.file)
    let nameLabel = ThemedText { _ in NSAttributedString() }
    let pathLabel = ThemedText { _ in NSAttributedString() }
    let detailLabel: ThemedText
    let popUp = ReviewChoicePopUp()
    let addsLabel = ThemedText { _ in NSAttributedString() }
    private(set) var row: ReviewRow?
    private var onChoice: (CopyPasteChoice) -> Void = { _ in }
    private var theme = AppearanceModel.shared.theme
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)
    private static let nameFont = ThemeFonts.sans(DesignTokens.typeScale.body, .medium)

    init() {
        detailLabel = ThemedText(wrapping: true) { _ in NSAttributedString() }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("reviewSheet.row")
        nameLabel.lineBreakMode = .byTruncatingTail
        pathLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityIdentifier("reviewSheet.row.name")
        detailLabel.setAccessibilityIdentifier("reviewSheet.row.detail")
        pathLabel.setAccessibilityIdentifier("reviewSheet.row.path")
        addsLabel.setAccessibilityIdentifier("reviewSheet.row.adds")
        for view in [glyph, nameLabel, pathLabel, detailLabel, popUp, addsLabel] as [NSView] { addSubview(view) }
        popUp.target = self
        popUp.action = #selector(choicePicked(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(_ row: ReviewRow, addsLabel adds: String, onChoice: @escaping (CopyPasteChoice) -> Void) {
        self.row = row
        self.onChoice = onChoice
        glyph.shape = row.kind == .folder ? .folder : .file
        let name = row.name
        let rename = row.keepBothName
        nameLabel.content = { theme in
            singleLineText(
                [(name, Self.nameFont, theme.palette.textPrimary)]
                    + (rename.map { [(" \u{2192} \($0)", Self.font, theme.palette.textSecondary)] } ?? []),
                background: theme.palette.bgElevated)
        }
        nameLabel.toolTip = row.relativePath
        let hint = ReviewSheetText.folderHint(row, maxIndentDepth: CopyPasteSheetLayout.maxIndentDepth)
        pathLabel.isHidden = hint == nil
        pathLabel.toolTip = hint
        pathLabel.content = { theme in
            singleLineText(
                [(hint ?? "", Self.font, theme.palette.textSecondary)], background: theme.palette.bgElevated)
        }
        let detail = row.detail
        let tone = row.tone
        var detailStyle = TextStyle(
            font: Self.font, color: { tone == .danger ? $0.palette.danger : $0.palette.textSecondary },
            lineHeight: Double(Self.lineHeight) / Double(Self.font.pointSize))
        detailStyle.background = { $0.palette.bgElevated }
        detailLabel.content = { detailStyle.string(detail, $0) }
        if let choice = row.choice {
            popUp.isHidden = false
            addsLabel.isHidden = true
            popUp.set(
                row.choices, selected: choice, blockedReason: row.replaceBlockedReason,
                label: "Choice for \(row.relativePath)")
        } else {
            popUp.isHidden = true
            addsLabel.isHidden = false
            addsLabel.content = { theme in
                singleLineText([(adds, Self.font, theme.palette.textSecondary)], background: theme.palette.bgElevated)
            }
        }
        setAccessibilityLabel(row.relativePath)
        needsLayout = true
        needsDisplay = true
    }

    var isReplacing: Bool { row?.choice == .overwrite }

    private var leftPadding: CGFloat {
        let layout = CopyPasteSheetLayout.self
        let depth = min(row?.depth ?? 0, layout.maxIndentDepth)
        return CGFloat(layout.rowHorizontal + Double(depth) * layout.indent)
    }

    private var trailingWidth: CGFloat {
        popUp.isHidden ? addsLabel.naturalWidth : popUp.preferredWidth
    }

    private func textWidth(_ width: CGFloat) -> CGFloat {
        let layout = CopyPasteSheetLayout.self
        return max(
            0,
            width - leftPadding - CGFloat(layout.glyphColumn) - 2 * CGFloat(layout.rowColumnGap) - trailingWidth
                - CGFloat(layout.rowHorizontal))
    }

    /// A line of the row's text as the original's lays it out (`line-height: normal`, 15 at 13 pt).
    private static let lineHeight = ThemeFonts.normalLineHeight(font)

    /// The detail's height: it wraps where it is long, each line at the original's line height.
    private func detailHeight(_ inner: CGFloat) -> CGFloat {
        max(Self.lineHeight, ceil(detailLabel.height(forWidth: inner)))
    }

    private func textHeight(_ inner: CGFloat) -> CGFloat {
        let gap = CGFloat(CopyPasteSheetLayout.rowTextGap)
        var height = Self.lineHeight
        if !pathLabel.isHidden { height += gap + Self.lineHeight }
        return height + gap + detailHeight(inner)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let layout = CopyPasteSheetLayout.self
        let content = max(
            textHeight(textWidth(width)), CGFloat(layout.glyphSize), CGFloat(DesignTokens.controlHeights.regular))
        return content + 2 * CGFloat(layout.rowVertical)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let layout = CopyPasteSheetLayout.self
        let height = bounds.height
        var x = leftPadding
        let glyphSize = CGFloat(layout.glyphSize)
        glyph.frame = NSRect(
            x: x + (CGFloat(layout.glyphColumn) - glyphSize) / 2, y: (height - glyphSize) / 2, width: glyphSize,
            height: glyphSize)
        x += CGFloat(layout.glyphColumn + layout.rowColumnGap)
        let inner = textWidth(bounds.width)
        let gap = CGFloat(layout.rowTextGap)
        // Each line takes the original's 15; the labels keep their own height, so no descender is cut.
        var y = (height - textHeight(inner)) / 2
        let nameHeight = ceil(nameLabel.height(forWidth: 10_000))
        nameLabel.frame = NSRect(x: x, y: y, width: inner, height: nameHeight)
        y += Self.lineHeight + gap
        if !pathLabel.isHidden {
            let pathHeight = ceil(pathLabel.height(forWidth: 10_000))
            pathLabel.frame = NSRect(x: x, y: y, width: inner, height: pathHeight)
            y += Self.lineHeight + gap
        }
        detailLabel.frame = NSRect(x: x, y: y, width: inner, height: detailHeight(inner) + 1)
        let trailing = trailingWidth
        let right = bounds.width - CGFloat(layout.rowHorizontal)
        if popUp.isHidden {
            let addsHeight = ceil(addsLabel.height(forWidth: 10_000))
            addsLabel.frame = NSRect(
                x: right - trailing, y: (height - addsHeight) / 2, width: trailing, height: addsHeight)
        } else {
            let popHeight = CGFloat(DesignTokens.controlHeights.regular)
            popUp.frame = NSRect(x: right - trailing, y: (height - popHeight) / 2, width: trailing, height: popHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isReplacing else { return }
        // color-mix(in srgb, var(--danger) 7%, transparent).
        NSColor(theme.palette.danger.withAlpha(CopyPasteSheetLayout.replacingAlpha)).setFill()
        bounds.fill(using: .sourceOver)
    }

    @objc private func choicePicked(_ sender: Any?) {
        guard let choice = popUp.choice else { return }
        onChoice(choice)
    }
}
