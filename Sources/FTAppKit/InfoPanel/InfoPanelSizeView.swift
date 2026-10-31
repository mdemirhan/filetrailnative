// Port of FolderSizeCell as apps/desktop/src/renderer/components/GetInfoPanel.tsx shows it in the panel since 59f60cf
import AppKit
import FTFoundation

/// The Size value of the Info panel, always one line. A measured folder shows its size and the recalculate button, its
/// counts having a row of their own; until then the shared cell offers Calculate, or the spinner and Stop.
final class InfoPanelSizeView: NSView {
    private let cell: FolderSizeCellView
    private let sizeLine = FlushTextField(labelWithString: "")
    private let refresh: InfoIconButton
    private var isMeasured = false

    var onCalculate: () -> Void {
        get { cell.onCalculate }
        set { cell.onCalculate = newValue }
    }
    var onRecalculate: () -> Void = {}
    var onCancel: () -> Void {
        get { cell.onCancel }
        set { cell.onCancel = newValue }
    }
    /// Told when the natural size changes, so the owner lays the view out again.
    var onSizeChange: (() -> Void)?

    init(identifier: String) {
        cell = FolderSizeCellView(style: .panel, identifier: identifier)
        refresh = InfoIconButton(
            glyph: .refresh, iconSize: FolderSizeCellView.refreshSize, strokeWidth: 2, cornerRadius: 0,
            identifier: identifier + ".refresh", label: "Recalculate folder size")
        super.init(frame: .zero)
        sizeLine.lineBreakMode = .byTruncatingTail
        sizeLine.alignment = .right
        sizeLine.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        sizeLine.setAccessibilityIdentifier(identifier + ".size")
        refresh.tooltip = "Calculate Size Again"
        refresh.normalColor = { $0.palette.textDim }
        refresh.hoverColor = { $0.accent.solid }
        refresh.onClick = { [weak self] in self?.onRecalculate() }
        cell.onSizeChange = { [weak self] in self?.onSizeChange?() }
        for view in [cell, sizeLine, refresh] as [NSView] { addSubview(view) }
        showMeasured(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func update(_ entry: FolderSizeEntry) {
        guard entry != cell.entry else { return }
        if case .ready(let size, let disk, let files, let folders) = entry {
            sizeLine.stringValue =
                InfoPanelModel.folderSizeLines(sizeBytes: size, diskBytes: disk, fileCount: files, folderCount: folders)
                .top
            showMeasured(true)
        } else {
            showMeasured(false)
        }
        needsLayout = true
        applyColors()
        // Last: the cell tells the owner its size changed, and the owner then lays out what was set above.
        cell.update(entry)
    }

    private func showMeasured(_ measured: Bool) {
        isMeasured = measured
        cell.isHidden = measured
        sizeLine.isHidden = !measured
        refresh.isHidden = !measured
    }

    /// The width the value takes now: its height is always the row's one line.
    var naturalWidth: Double {
        guard isMeasured else { return cell.naturalSize.width }
        return textExtent(sizeLine.stringValue, sizeLine.font) + FolderSizeCellView.gap + FolderSizeCellView.refreshSize
    }

    private func applyColors() {
        sizeLine.textColor = NSColor(infoTheme.palette.textPrimary)
    }

    override func layout() {
        super.layout()
        applyColors()
        cell.frame = bounds
        let side = FolderSizeCellView.refreshSize
        refresh.frame = NSRect(x: bounds.width - side, y: (bounds.height - side) / 2, width: side, height: side)
        let textWidth = max(0, bounds.width - side - FolderSizeCellView.gap)
        let shown = min(textWidth, textExtent(sizeLine.stringValue, sizeLine.font))
        let height = lineBox(sizeLine.font)
        sizeLine.frame = NSRect(x: textWidth - shown, y: (bounds.height - height) / 2, width: shown, height: height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Only the controls take clicks: for the first moments of a calculation the value shows nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
