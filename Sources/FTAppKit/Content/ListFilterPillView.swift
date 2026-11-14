import AppKit
import FTFoundation

/// What has been typed to narrow the list above it, how it matches (a chip that switches Fuzzy and Contains), how much
/// of the list is left, and a way to bring the rest back. It floats on glass over the foot of the list, so the first
/// match, which is selected at the top, is never covered. It springs up when a filter starts and drops away when it is
/// cleared; with Reduce Motion it only fades. Text that matches nothing turns its edge red, with a small shake.
final class ListFilterPillView: NSView, TextStyleSource {
    private let symbol = NSImageView()
    let chip = ListFilterModeChip()
    private let value = ListLabel()
    private let count = ListLabel()
    private let clear = ClearButton()
    private var theme = AppearanceModel.shared.theme
    private var nothingMatches = false
    /// Counts the pill's comings and goings, so a fade out finishing late doesn't hide a pill shown again since.
    private var showing = 0
    /// Whether the pill shows a filter, whatever an animation of it leaving is doing.
    private(set) var isShowingFilter = false

    /// Told when the ✕ is pressed.
    var onClear: () -> Void = {}
    /// Told when the chip is pressed: the other mode is wanted.
    var onToggleMode: () -> Void = {}
    /// Reduce Motion, asked each time: the pill then only fades.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var styleTextField: NSTextField? { value }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        let font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        symbol.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(SelectionLayout.FilterPill.symbolSize), weight: .medium))
        symbol.imageScaling = .scaleProportionallyDown
        value.font = ThemeFonts.sans(DesignTokens.typeScale.callout, .semibold)
        value.lineBreakMode = .byTruncatingTail
        value.setAccessibilityIdentifier("listFilter.value")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(DesignTokens.typeScale.callout), weight: .regular)
        count.setAccessibilityIdentifier("listFilter.count")
        chip.font = font
        chip.setAccessibilityIdentifier("listFilter.mode")
        chip.target = self
        chip.action = #selector(toggledMode(_:))
        clear.setAccessibilityLabel("Clear filter")
        clear.toolTip = "Clear Filter (Esc)"
        clear.setAccessibilityIdentifier("listFilter.clear")
        clear.target = self
        clear.action = #selector(cleared(_:))
        for view in [symbol, chip, value, count, clear] as [NSView] { addSubview(view) }
        setAccessibilityIdentifier("listFilter")
        setAccessibilityLabel("Filter")
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func cleared(_ sender: Any?) { onClear() }

    @objc private func toggledMode(_ sender: Any?) { onToggleMode() }

    /// Shows the filter, or takes the pill away when there is none.
    func show(query: String, mode: NameMatchMode, shown: Int, total: Int, theme: Theme) {
        self.theme = theme
        guard !query.isEmpty else {
            hide()
            return
        }
        let wasShowing = isShowingFilter
        let matchedBefore = !nothingMatches
        nothingMatches = shown == 0 && total > 0
        value.stringValue = query
        count.stringValue = "\(shown) of \(total)"
        chip.mode = mode
        clear.applyTheme(theme)
        applyColors()
        needsLayout = true
        needsDisplay = true
        if !wasShowing {
            isShowingFilter = true
            showing += 1
            isHidden = false
            layer?.removeAllAnimations()
            layer?.opacity = 1
            springUp()
        } else if nothingMatches, matchedBefore {
            shake()
        }
    }

    private func hide() {
        guard isShowingFilter else { return }
        isShowingFilter = false
        nothingMatches = false
        showing += 1
        let leaving = showing
        guard window != nil, let layer else {
            isHidden = true
            return
        }
        let layout = SelectionLayout.FilterPill.self
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.showing == leaving else { return }
            self.isHidden = true
            self.layer?.opacity = 1
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        var animations: [CAAnimation] = [fade]
        if !reducesMotion() {
            let drop = CABasicAnimation(keyPath: "transform.translation.y")
            drop.fromValue = 0
            drop.toValue = layout.travel
            animations.append(drop)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = DesignTokens.motion.fast / 1000
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(group, forKey: "listFilter-leave")
        CATransaction.commit()
    }

    /// Up from below its place with a little overshoot, fading in; only the fade with Reduce Motion.
    private func springUp() {
        guard window != nil, let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = DesignTokens.motion.fast / 1000
        layer.add(fade, forKey: "listFilter-fade")
        guard !reducesMotion() else { return }
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = SelectionLayout.FilterPill.travel
        rise.toValue = 0
        rise.mass = 1
        rise.stiffness = 420
        rise.damping = 22
        rise.initialVelocity = 0
        rise.duration = rise.settlingDuration
        layer.add(rise, forKey: "listFilter-rise")
    }

    /// A short shake from side to side, as a refused password gets; none with Reduce Motion.
    private func shake() {
        guard window != nil, let layer, !reducesMotion() else { return }
        let layout = SelectionLayout.FilterPill.self
        let distance = layout.shakeDistance
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -distance, distance, -distance * 0.6, distance * 0.6, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = layout.shakeDuration
        layer.add(shake, forKey: "listFilter-shake")
    }

    private func applyColors() {
        let palette = theme.palette
        let layout = SelectionLayout.FilterPill.self
        symbol.contentTintColor = NSColor(palette.textSecondary)
        value.textColor = NSColor(palette.textPrimary)
        count.textColor = NSColor(nothingMatches ? palette.dangerText : palette.textSecondary)
        chip.theme = theme
        guard let layer else { return }
        layer.borderWidth = CGFloat(layout.borderWidth)
        layer.borderColor = NSColor(nothingMatches ? palette.danger : theme.accent.border).cgColor
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = Float(layout.shadowOpacity)
        layer.shadowRadius = CGFloat(layout.shadowRadius)
        // The pill is flipped: a shadow's positive y is down.
        layer.shadowOffset = CGSize(width: 0, height: layout.shadowOffset)
    }

    // MARK: Layout

    /// The pill's size in a list `available` wide: as wide as its parts, at most the list less 32.
    func fittingSize(in available: CGFloat) -> NSSize {
        let layout = SelectionLayout.FilterPill.self
        let gap = CGFloat(layout.gap)
        let fixed =
            CGFloat(layout.borderWidth) * 2 + CGFloat(layout.paddingLeft) + CGFloat(layout.paddingRight)
            + CGFloat(layout.symbolSize) + gap + chip.fittingWidth + gap + gap + count.textWidth + gap
            + ClearButton.size
        let maxWidth = max(0, available - CGFloat(layout.maxWidthInset))
        let valueWidth = min(value.textWidth, max(0, maxWidth - fixed))
        let inner = max(value.lineHeight, count.lineHeight, chip.fittingHeight, ClearButton.size)
        let height =
            CGFloat(layout.borderWidth) * 2 + CGFloat(layout.paddingTop) + inner + CGFloat(layout.paddingBottom)
        return NSSize(width: min(maxWidth, fixed + valueWidth), height: height.rounded(.up))
    }

    override func layout() {
        super.layout()
        GlassSurface.install(in: self, radius: bounds.height / 2)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        let layout = SelectionLayout.FilterPill.self
        let gap = CGFloat(layout.gap)
        let border = CGFloat(layout.borderWidth)
        let inner = bounds.height - 2 * border - CGFloat(layout.paddingTop) - CGFloat(layout.paddingBottom)
        let top = border + CGFloat(layout.paddingTop)
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) -> CGFloat {
            view.frame = NSRect(x: x, y: top + (inner - height) / 2, width: width, height: height)
            return x + width + gap
        }
        var x = border + CGFloat(layout.paddingLeft)
        x = place(symbol, x: x, width: CGFloat(layout.symbolSize), height: CGFloat(layout.symbolSize))
        x = place(chip, x: x, width: chip.fittingWidth, height: chip.fittingHeight)
        let countWidth = count.textWidth
        let reserved = gap + countWidth + gap + ClearButton.size + CGFloat(layout.paddingRight) + border
        let valueWidth = min(value.textWidth, max(0, bounds.width - x - reserved))
        x = place(value, x: x, width: valueWidth, height: value.lineHeight)
        x = place(count, x: x, width: countWidth, height: count.lineHeight)
        _ = place(clear, x: x, width: ClearButton.size, height: ClearButton.size)
    }

    /// The ✕, the chip and the pill take the pointer; the list keeps the keyboard (a press here does not change who has
    /// it).
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {}
}

/// The filter's mode as a word in a capsule of the accent: a press switches Fuzzy and Contains. It never takes the
/// keyboard, so typing goes on into the list.
final class ListFilterModeChip: NSControl {
    private let label = ListLabel()
    private var isHovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    var mode = NameMatchMode.fuzzy {
        didSet {
            label.stringValue = mode.label
            toolTip =
                mode == .fuzzy
                ? "Fuzzy: names with the letters you type in that order. Click for Contains."
                : "Contains: names with the letters you type side by side. Click for Fuzzy."
            needsLayout = true
            needsDisplay = true
        }
    }

    var theme = AppearanceModel.shared.theme {
        didSet {
            label.textColor = NSColor(theme.accent.solid)
            needsDisplay = true
        }
    }

    override var font: NSFont? {
        get { label.font }
        set { label.font = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.stringValue = mode.label
        addSubview(label)
        setAccessibilityRole(.button)
        mode = .fuzzy
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var fittingWidth: CGFloat {
        label.textWidth + 2 * CGFloat(SelectionLayout.FilterPill.chipPaddingHorizontal)
    }

    var fittingHeight: CGFloat {
        label.lineHeight + 2 * CGFloat(SelectionLayout.FilterPill.chipPaddingVertical)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: CGFloat(SelectionLayout.FilterPill.chipPaddingHorizontal), y: (bounds.height - label.lineHeight) / 2,
            width: label.textWidth, height: label.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = SelectionLayout.FilterPill.self
        let alpha = isHovering ? layout.chipHoverFillAlpha : layout.chipFillAlpha
        NSColor(theme.accent.solid.withAlpha(alpha)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}
