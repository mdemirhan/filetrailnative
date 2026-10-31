// Port of apps/desktop/src/renderer/components/CopyPasteResultDialog.tsx (the sheet and ResultSection) with the
// .copy-paste-result-* rules of styles.css
import AppKit
import FTFoundation

/// The result sheet (`CopyPasteResultDialog`): shown when a copy-like operation, a rename of several items, an Undo
/// or a Redo finished with problems; every failed, unstarted and skipped item with its reason, and a retry for the
/// ones worth retrying. Done (and Escape) dismisses it.
@MainActor
final class CopyPasteResultSheet: CopyPasteSheetView {
    let text: CopyPasteResultText
    let doneButton = SystemButton(title: "Done")
    let retryButton: SystemButton?
    private var sections: [ResultSectionView] = []
    var onDone: () -> Void = {}
    var onRetry: () -> Void = {}

    init(text: CopyPasteResultText) {
        self.text = text
        retryButton = text.retryLabel.map { SystemButton(title: $0) }
        super.init(identifier: "resultSheet")
        setTitle(text.title, message: text.message)
        listInsets = (0, CGFloat(CopyPasteSheetLayout.resultListBottom))
        doneButton.isDefault = true
        doneButton.target = self
        doneButton.action = #selector(donePressed(_:))
        doneButton.setAccessibilityIdentifier("resultSheet.done")
        if let retryButton {
            retryButton.target = self
            retryButton.action = #selector(retryPressed(_:))
            retryButton.setAccessibilityIdentifier("resultSheet.retry")
        }
        buttons = [retryButton].compactMap { $0 } + [doneButton]
        sections = text.sections.map(ResultSectionView.init)
        for section in sections { list.addSubview(section) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var sectionViews: [ResultSectionView] { sections }

    override var initialResponder: NSView? { doneButton }

    override func layoutRows(width: CGFloat) -> CGFloat {
        var y = listInsets.top
        var lines: [CGFloat] = []
        for (index, section) in sections.enumerated() {
            if index > 0 { lines.append(y) }
            let height = section.height(forWidth: width)
            section.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        list.sectionLines = lines
        return y - listInsets.top
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        if KeyCode.isCancel(event) {
            onDone()
            return true
        }
        if super.handleKey(event) { return true }
        guard KeyCode.isReturn(event), event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        // A focused button takes Return; nothing else in the sheet does.
        if let button = window?.firstResponder as? SystemButton, button.isDescendant(of: self) { button.perform() }
        return true
    }

    @objc private func donePressed(_ sender: Any?) { onDone() }
    @objc private func retryPressed(_ sender: Any?) { onRetry() }
}

/// A section of the result (`ResultSection`): its title, then each item's path and why.
@MainActor
final class ResultSectionView: NSView {
    let section: ResultSectionText
    let titleLabel: ThemedText
    let rows: [(path: ThemedText, detail: ThemedText)]
    let moreLabel: ThemedText?
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    init(_ section: ResultSectionText) {
        self.section = section
        var titleStyle = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.small, .semibold), color: { $0.palette.textSecondary })
        titleStyle.background = { $0.palette.bgElevated }
        titleLabel = ThemedText(section.label, style: titleStyle)
        let danger = section.tone == .danger
        var detailStyle = TextStyle(
            font: Self.font, color: { danger ? $0.palette.danger : $0.palette.textSecondary })
        detailStyle.background = { $0.palette.bgElevated }
        rows = section.rows.map { row in
            let path = ThemedText { theme in
                singleLineText(
                    [(row.path, ThemeFonts.sans(DesignTokens.typeScale.body, .medium), theme.palette.textPrimary)],
                    background: theme.palette.bgElevated)
            }
            path.lineBreakMode = .byTruncatingTail
            path.toolTip = row.path
            path.setAccessibilityIdentifier("resultSheet.row.path")
            let detail = ThemedText(row.detail, style: detailStyle, wrapping: true)
            detail.setAccessibilityIdentifier("resultSheet.row.detail")
            return (path, detail)
        }
        var moreStyle = TextStyle(font: Self.font, color: { $0.palette.textSecondary })
        moreStyle.background = { $0.palette.bgElevated }
        moreLabel = section.more.map { ThemedText($0, style: moreStyle) }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(section.label)
        setAccessibilityIdentifier("resultSheet.section")
        titleLabel.setAccessibilityIdentifier("resultSheet.section.title")
        addSubview(titleLabel)
        for row in rows {
            addSubview(row.path)
            addSubview(row.detail)
        }
        if let moreLabel {
            moreLabel.setAccessibilityIdentifier("resultSheet.more")
            addSubview(moreLabel)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func inner(_ width: CGFloat) -> CGFloat {
        max(0, width - 2 * CGFloat(CopyPasteSheetLayout.rowHorizontal))
    }

    private func rowHeight(_ row: (path: ThemedText, detail: ThemedText), _ inner: CGFloat) -> CGFloat {
        let layout = CopyPasteSheetLayout.self
        return 2 * CGFloat(layout.resultRowVertical) + row.path.normalLineBoxHeight(forWidth: 10_000)
            + CGFloat(layout.rowTextGap) + row.detail.normalLineBoxHeight(forWidth: inner)
    }

    private var moreHeight: CGFloat {
        moreLabel.map {
            2 * CGFloat(CopyPasteSheetLayout.resultRowVertical) + $0.normalLineBoxHeight(forWidth: 10_000)
        } ?? 0
    }

    private var titleHeight: CGFloat {
        let layout = CopyPasteSheetLayout.self
        return CGFloat(layout.sectionTitleTop) + titleLabel.normalLineBoxHeight(forWidth: 10_000)
            + CGFloat(layout.sectionTitleBottom)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = inner(width)
        return titleHeight + rows.reduce(0) { $0 + rowHeight($1, inner) } + moreHeight
    }

    override func layout() {
        super.layout()
        let layout = CopyPasteSheetLayout.self
        let inner = inner(bounds.width)
        titleLabel.frame = NSRect(
            x: CGFloat(layout.sectionTitleHorizontal), y: CGFloat(layout.sectionTitleTop),
            width: max(0, bounds.width - 2 * CGFloat(layout.sectionTitleHorizontal)),
            height: ceil(titleLabel.height(forWidth: 10_000)))
        var y = titleHeight
        let x = CGFloat(layout.rowHorizontal)
        separators = []
        for (index, row) in rows.enumerated() {
            if index > 0 { separators.append(y) }
            // Each line takes the original's height; the labels keep their own, so no descender is cut.
            let pathHeight = ceil(row.path.height(forWidth: 10_000))
            row.path.frame = NSRect(x: x, y: y + CGFloat(layout.resultRowVertical), width: inner, height: pathHeight)
            let detailTop =
                y + CGFloat(layout.resultRowVertical) + row.path.normalLineBoxHeight(forWidth: 10_000)
                + CGFloat(layout.rowTextGap)
            row.detail.frame = NSRect(
                x: x, y: detailTop, width: inner, height: ceil(row.detail.height(forWidth: inner)))
            y += rowHeight(row, inner)
        }
        if let moreLabel {
            if !rows.isEmpty { separators.append(y) }
            moreLabel.frame = NSRect(
                x: x, y: y + CGFloat(layout.resultRowVertical), width: inner,
                height: ceil(moreLabel.height(forWidth: 10_000)))
        }
        needsDisplay = true
    }

    /// The lines between the rows (`.copy-paste-sheet-row + .copy-paste-sheet-row`).
    private var separators: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        let border = AppearanceModel.shared.theme.palette.borderLight
        NSColor(border.withAlpha(border.alpha * CopyPasteSheetLayout.rowSeparatorAlpha)).setFill()
        for y in separators {
            NSRect(x: 0, y: y, width: bounds.width, height: CGFloat(CopyPasteSheetLayout.border)).fill(
                using: .sourceOver)
        }
    }
}
