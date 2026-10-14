// Port of apps/desktop/src/renderer/components/InfoRow.tsx with the .info-row rules of styles.css:3269-3340
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

/// The Info Row's place under the list: 30 tall with a line on top while open; closed it keeps its 1 pt line, unseen
/// (`max-height: 0`, `opacity: 0`). Like the path bar row it starts in the divider's half past the hairline. One line:
/// the icon, the name, then the facts with dots between them.
final class InfoRowView: NSView {
    /// `.info-row.open { max-height: 30px }`.
    static var openHeight: Double { InfoMetrics.infoRowHeight }
    static let closedHeight = 1.0
    /// The slide: max-height 220 ms, opacity 180 ms.
    static let slideDuration = 0.22

    private let icon = InfoIconView()
    private let name = FlushTextField(labelWithString: "")
    private let factsClip = NSView()
    private var factViews: [NSView] = []
    private var dots: [FlushTextField] = []
    private(set) var display: InfoRowDisplay?
    var iconStore: FileIconStore?
    var onCalculate: () -> Void = {}
    var onRecalculate: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Told when the row's height changes while it slides, so the pane lays out again.
    var onHeightChange: (() -> Void)?
    private let cell = FolderSizeCellView(style: .row, identifier: "infoRow.folderSize")
    private var slideTimer: Timer?
    private var slideFrom = 0.0
    private var slideStart = Date()
    private var shownHeight = InfoRowView.closedHeight

    private(set) var isOpen = false

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        let target = open ? Self.openHeight : Self.closedHeight
        slideTimer?.invalidate()
        if !animated || window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            shownHeight = target
            alphaValue = open ? 1 : 0
            needsDisplay = true
            onHeightChange?()
            return
        }
        slideFrom = shownHeight
        slideStart = Date()
        let alphaFrom = alphaValue
        slideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
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
        name.setAccessibilityIdentifier("infoRow.name")
        name.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: 500)
        name.lineBreakMode = .byTruncatingTail
        factsClip.wantsLayer = true
        factsClip.layer?.masksToBounds = true
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
        display = next
        rebuildFacts()
        needsLayout = true
    }

    private func rebuildFacts() {
        for view in factViews { view.removeFromSuperview() }
        for dot in dots { dot.removeFromSuperview() }
        factViews = []
        dots = []
        guard let display else {
            name.stringValue = ""
            icon.show(nil, store: iconStore, deferLoad: true)
            return
        }
        name.stringValue = display.name
        name.toolTip = display.nameTooltip
        icon.show(display.icon, store: iconStore, deferLoad: true)
        for (index, fact) in display.facts.enumerated() {
            if index > 0 {
                let dot = FlushTextField(labelWithString: "·")
                dot.font = ChromeColors.font(size: DesignTokens.typeScale.callout)
                dot.setAccessibilityIdentifier("infoRow.dot")
                dots.append(dot)
                factsClip.addSubview(dot)
            }
            switch fact.content {
            case .text(let text):
                let field = FlushTextField(labelWithString: text)
                field.font = ChromeColors.font(size: DesignTokens.typeScale.callout)
                field.lineBreakMode = .byTruncatingTail
                field.toolTip = fact.tooltip
                field.setAccessibilityIdentifier("infoRow.fact")
                factViews.append(field)
                factsClip.addSubview(field)
            case .folderSize(let entry):
                cell.update(entry)
                cell.toolTip = fact.tooltip
                if cell.superview !== factsClip { factsClip.addSubview(cell) }
                factViews.append(cell)
            }
        }
        applyColors()
    }

    private func natural(_ view: NSView) -> NSSize {
        if let field = view as? NSTextField {
            let size = (field.stringValue as NSString).size(withAttributes: [.font: field.font as Any])
            return NSSize(width: ceil(size.width), height: ceil(size.height))
        }
        if let cell = view as? FolderSizeCellView { return cell.naturalSize }
        return .zero
    }

    override func layout() {
        super.layout()
        let reach = PathBarRowView.reach
        let left = reach + InfoMetrics.infoRowPaddingInline
        let right = bounds.width - InfoMetrics.infoRowPaddingInline
        // The line is 30 tall under a 1 pt border: its center is 16 from the row's top.
        let centerY = 1 + InfoMetrics.infoRowHeight / 2
        let side = InfoMetrics.infoRowIcon
        icon.isHidden = display == nil
        icon.frame = NSRect(x: left, y: centerY - side / 2, width: side, height: side)
        guard display != nil else { return }
        let nameSize = natural(name)
        // Facts: each fact's natural width, with a dot (margin 6 each side) between.
        let dotWidth = dots.first.map { natural($0).width } ?? 0
        let separator = dotWidth + 2 * InfoMetrics.infoRowFactMargin
        var factWidths = factViews.map { natural($0).width }
        let factsTotal = factWidths.reduce(0, +) + separator * Double(max(0, factViews.count - 1))
        let start = left + side + InfoMetrics.infoRowGap
        let available = max(0, right - start)
        let gap = factViews.isEmpty ? 0 : InfoMetrics.infoRowGap
        var nameWidth = nameSize.width
        var factsWidth = factsTotal
        let overflow = nameWidth + gap + factsWidth - available
        if overflow > 0 {
            // flex-shrink 1 for the name, 10 for the facts, in proportion to their sizes.
            let weight = nameWidth + 10 * factsWidth
            let nameCut = weight > 0 ? min(nameWidth, overflow * nameWidth / weight) : 0
            nameWidth -= nameCut
            factsWidth = max(0, factsWidth - (overflow - nameCut))
        }
        name.frame = NSRect(x: start, y: centerY - nameSize.height / 2, width: nameWidth, height: nameSize.height)
        let factsX = start + nameWidth + gap
        factsClip.frame = NSRect(x: factsX, y: 0, width: factsWidth, height: bounds.height)
        factsClip.isHidden = factViews.isEmpty
        var x = 0.0
        for (index, view) in factViews.enumerated() {
            if index > 0 {
                let dot = dots[index - 1]
                let size = natural(dot)
                dot.frame = NSRect(
                    x: x + InfoMetrics.infoRowFactMargin, y: centerY - size.height / 2, width: size.width, height: size.height)
                x += separator
            }
            let size = natural(view)
            view.frame = NSRect(x: x, y: centerY - size.height / 2, width: factWidths[index], height: size.height)
            x += factWidths[index]
        }
        factWidths = []
        applyColors()
    }

    private func applyColors() {
        let theme = AppearanceModel.shared.theme
        name.textColor = NSColor(theme.palette.textPrimary)
        for view in factViews {
            (view as? NSTextField)?.textColor = NSColor(theme.palette.textSecondary)
        }
        for dot in dots { dot.textColor = NSColor(theme.palette.textDim) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = AppearanceModel.shared.theme.palette
        ChromeColors.color(palette.bgBase).setFill()
        bounds.fill()
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
}
