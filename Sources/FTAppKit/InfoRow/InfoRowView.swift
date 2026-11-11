import AppKit
import FTFileSystem
import FTFoundation

/// What the Info Row describes.
struct InfoRowDisplay: Equatable {
    struct Fact: Equatable {
        enum Content: Equatable {
            case text(String)
            case folderSize(FolderSizeEntry)
        }
        var content: Content
        var tooltip: String?
    }

    var name: String
    var nameTooltip: String?
    var icon: IconEntry?
    var facts: [Fact]
}

/// One fact of the line: its text or the folder size cell, with the dot before it that comes with every fact but the
/// first (6 each side, inside the fact's box).
final class InfoRowFactView: NSView, TextStyleSource {
    let text = FlushTextField(labelWithString: "")
    let dot = FlushTextField(labelWithString: "·")
    var cell: FolderSizeCellView?
    var hasDot = false

    var styleTextField: NSTextField? { text }
    override var isFlipped: Bool { true }

    init(cell: FolderSizeCellView?, hasDot: Bool) {
        self.cell = cell
        self.hasDot = hasDot
        super.init(frame: .zero)
        setAccessibilityIdentifier("infoRow.fact")
        text.font = tabularFont(DesignTokens.typeScale.callout)
        text.lineBreakMode = .byTruncatingTail
        dot.font = tabularFont(DesignTokens.typeScale.callout)
        dot.setAccessibilityIdentifier("infoRow.dot")
        if hasDot { addSubview(dot) }
        if let cell {
            addSubview(cell)
            text.alphaValue = 0
            text.stringValue = "Calculate size"
        }
        addSubview(text)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The width of the dot and its margins.
    var dotSpace: Double {
        hasDot ? textExtent("·", dot.font) + 2 * InfoMetrics.infoRowFactMargin : 0
    }

    var naturalWidth: Double {
        dotSpace + (cell.map { Double($0.naturalSize.width) } ?? textExtent(text.stringValue, text.font))
    }

    func applyColors() {
        let palette = infoTheme.palette
        text.textColor = NSColor(palette.textSecondary)
        dot.textColor = NSColor(palette.textDim)
    }

    override func layout() {
        super.layout()
        applyColors()
        let line = lineBox(text.font)
        let space = dotSpace
        if hasDot {
            dot.frame = NSRect(
                x: InfoMetrics.infoRowFactMargin, y: (bounds.height - line) / 2,
                width: textExtent("·", dot.font), height: line)
        }
        if let cell {
            let size = cell.naturalSize
            cell.frame = NSRect(x: space, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            text.frame = cell.frame
        } else {
            text.frame = NSRect(
                x: space, y: (bounds.height - line) / 2, width: max(0, bounds.width - space), height: line)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === text || hit === dot ? nil : hit
    }
}

/// The Info Row's place under the list: 30 tall with a line on top while open; closed it keeps its 1 pt line, unseen
/// (no height, fully transparent). Like the path bar row it starts in the divider's half past the hairline. One line:
/// the icon, the name, then the facts with dots between them.
final class InfoRowView: NSView {
    /// The open row's height, 30.
    static var openHeight: Double { InfoMetrics.infoRowHeight }
    static let closedHeight = 1.0
    /// The slide: the height over 220 ms, the opacity over 180 ms.
    static let slideDuration = 0.22

    private let backdrop = ContentBackdrop()
    private let icon = InfoIconView()
    private let name = FlushTextField(labelWithString: "")
    private let factsClip = InfoFlippedView()
    private var factViews: [InfoRowFactView] = []
    private(set) var display: InfoRowDisplay?
    var iconStore: FileIconStore?
    var onCalculate: () -> Void = {}
    var onRecalculate: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Told when the row's height changes while it slides, so the pane lays out again.
    var onHeightChange: (() -> Void)?
    private let cell = FolderSizeCellView(style: .row, identifier: "infoRow.folderSize")
    private(set) var slideTimer: Timer?
    /// Whether the system asks for less motion: the row then opens and closes at once, with no timer.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var slideFrom = 0.0
    private var slideStart = Date()
    private var shownHeight = InfoRowView.closedHeight

    private(set) var isOpen = false

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        let target = open ? Self.openHeight : Self.closedHeight
        slideTimer?.invalidate()
        if !animated || window == nil || reducesMotion() {
            shownHeight = target
            alphaValue = open ? 1 : 0
            needsDisplay = true
            onHeightChange?()
            return
        }
        slideFrom = shownHeight
        slideStart = Date()
        let alphaFrom = alphaValue
        slideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            // The row went away while it slid: nothing else would stop the timer.
            guard self != nil else { return timer.invalidate() }
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(self.slideStart)
                let progress = min(1, elapsed / Self.slideDuration)
                let eased = progress * progress * (3 - 2 * progress)
                self.shownHeight = self.slideFrom + (target - self.slideFrom) * eased
                let opacityProgress = min(1, elapsed / (DesignTokens.motion.base / 1000))
                self.alphaValue = alphaFrom + ((open ? 1 : 0) - alphaFrom) * opacityProgress
                self.onHeightChange?()
                if progress >= 1 {
                    self.slideTimer?.invalidate()
                    self.shownHeight = target
                }
            }
        }
        RunLoop.main.add(slideTimer!, forMode: .common)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        setAccessibilityIdentifier("infoRow")
        icon.setAccessibilityIdentifier("infoRow.icon")
        // The app's icon: 18 in the row's 16 box, past its right and bottom edges.
        icon.nativeIconSide = 18
        icon.clipsToBounds = false
        name.setAccessibilityIdentifier("infoRow.name")
        name.font = tabularFont(DesignTokens.typeScale.callout, weight: 500)
        name.lineBreakMode = .byTruncatingTail
        factsClip.wantsLayer = true
        factsClip.layer?.masksToBounds = true
        addSubview(backdrop)
        addSubview(icon)
        addSubview(name)
        addSubview(factsClip)
        cell.onCalculate = { [weak self] in self?.onCalculate() }
        cell.onRecalculate = { [weak self] in self?.onRecalculate() }
        cell.onCancel = { [weak self] in self?.onCancel() }
        cell.onSizeChange = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The height the row takes now (while sliding, between the two).
    var height: Double { shownHeight }

    func show(_ next: InfoRowDisplay?) {
        guard next != display else { return }
        let sameShape = display?.facts.count == next?.facts.count && display?.name == next?.name
        display = next
        if sameShape, let next, rebuildInPlace(next) {
            needsLayout = true
            return
        }
        rebuildFacts()
        needsLayout = true
    }

    /// The same facts with new values (a size arriving, or another selection that reads the same, such as "2 items"):
    /// only the icon, the folder size cell and the texts change. The icon view keeps an icon it already shows.
    private func rebuildInPlace(_ next: InfoRowDisplay) -> Bool {
        guard factViews.count == next.facts.count else { return false }
        for (view, fact) in zip(factViews, next.facts) {
            switch fact.content {
            case .text(let text):
                guard view.cell == nil else { return false }
                view.text.stringValue = text
            case .folderSize(let entry):
                guard view.cell != nil else { return false }
                cell.update(entry)
            }
            view.toolTip = fact.tooltip
        }
        icon.show(next.icon, store: iconStore, deferLoad: true)
        return true
    }

    private func rebuildFacts() {
        for view in factViews { view.removeFromSuperview() }
        factViews = []
        guard let display else {
            name.stringValue = ""
            icon.show(nil, store: iconStore, deferLoad: true)
            return
        }
        name.stringValue = display.name
        name.toolTip = display.nameTooltip
        icon.show(display.icon, store: iconStore, deferLoad: true)
        for (index, fact) in display.facts.enumerated() {
            let view: InfoRowFactView
            switch fact.content {
            case .text(let text):
                view = InfoRowFactView(cell: nil, hasDot: index > 0)
                view.text.stringValue = text
            case .folderSize(let entry):
                cell.update(entry)
                view = InfoRowFactView(cell: cell, hasDot: index > 0)
            }
            view.toolTip = fact.tooltip
            factsClip.addSubview(view)
            factViews.append(view)
        }
        applyColors()
    }

    override func layout() {
        super.layout()
        // Under the 1 pt edge drawn above it.
        backdrop.frame = NSRect(x: 0, y: 1, width: bounds.width, height: max(0, bounds.height - 1))
        let reach = PathBarRowView.reach
        let left = reach + InfoMetrics.infoRowPaddingInline
        let right = bounds.width - InfoMetrics.infoRowPaddingInline
        // The line is 30 tall under a 1 pt border: its center is 16 from the row's top.
        let centerY = 1 + InfoMetrics.infoRowHeight / 2
        let side = InfoMetrics.infoRowIcon
        icon.isHidden = display == nil
        icon.frame = NSRect(x: left, y: centerY - side / 2, width: side, height: side)
        guard display != nil else { return }
        let nameHeight = lineBox(name.font)
        let nameNatural = textExtent(name.stringValue, name.font)
        let widths = factViews.map(\.naturalWidth)
        let factsTotal = widths.reduce(0, +)
        let start = left + side + InfoMetrics.infoRowGap
        let available = max(0, right - start)
        let gap = factViews.isEmpty ? 0 : InfoMetrics.infoRowGap
        var nameWidth = nameNatural
        var factsWidth = factsTotal
        let overflow = nameWidth + gap + factsWidth - available
        if overflow > 0 {
            // The overflow is taken from the name and the facts in proportion to their widths, the facts' counted ten
            // times over.
            let weight = nameWidth + 10 * factsWidth
            let nameCut = weight > 0 ? min(nameWidth, overflow * nameWidth / weight) : 0
            nameWidth -= nameCut
            factsWidth = max(0, factsWidth - (overflow - nameCut))
        }
        name.frame = NSRect(x: start, y: centerY - nameHeight / 2, width: nameWidth, height: nameHeight)
        factsClip.frame = NSRect(x: start + nameWidth + gap, y: 0, width: factsWidth, height: bounds.height)
        factsClip.isHidden = factViews.isEmpty
        var x = 0.0
        for (index, view) in factViews.enumerated() {
            view.frame = NSRect(x: x, y: centerY - nameHeight / 2, width: widths[index], height: nameHeight)
            x += widths[index]
        }
        applyColors()
    }

    private func applyColors() {
        let theme = infoTheme
        name.textColor = NSColor(theme.palette.textPrimary)
        for view in factViews { view.applyColors() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = infoTheme.palette
        ChromeColors.color(palette.border).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Closed, its line is out of sight and out of reach.
    override func hitTest(_ point: NSPoint) -> NSView? { isOpen ? super.hitTest(point) : nil }
}
