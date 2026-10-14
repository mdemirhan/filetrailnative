// Port of apps/desktop/src/renderer/components/CopyPasteProgressCard.tsx, lib/progressCardDelay.ts and the card's rules
// in styles.css:1631-1726
import AppKit
import FTFoundation

/// What the progress card shows and when. P5-08 connects the write coordinator to it: it sets `state` while an
/// operation runs and clears it when it ends, and takes the Stop button through `onStop`. As in Finder, an operation
/// over in a moment (a rename, one item to the Trash) shows no card; it comes once the operation has run for 500 ms.
@MainActor
final class ProgressCardModel {
    /// The running operation; nil when none is.
    var state: WriteOperationCardState? {
        didSet {
            guard state != oldValue else { return }
            stateChanged(wasNil: oldValue == nil)
        }
    }
    /// The folder on screen, which names the card's item when the operation has none.
    var currentPath: () -> String = { "" }
    var onStop: () -> Void = {}
    /// The delay before the card shows, in milliseconds (`PROGRESS_CARD_DELAY_MS`).
    var delayMs = ShowDelays.progressCardMs
    var schedule: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ToastCenter.Cancel = {
        delay, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return ToastCenter.Cancel { item.cancel() }
    }
    /// Told when the card appears, changes or goes.
    var onChange: () -> Void = {}

    private(set) var isVisible = false
    private var pending: ToastCenter.Cancel?

    /// The words of the card now, if it shows.
    var text: ProgressCardText? {
        guard isVisible, let state else { return nil }
        return ProgressCardText(state, currentPath: currentPath())
    }

    private func stateChanged(wasNil: Bool) {
        if state == nil {
            pending?.cancel()
            pending = nil
            if isVisible {
                isVisible = false
                onChange()
            }
            return
        }
        if isVisible {
            onChange()
        } else if pending == nil {
            // `useDelayedFlag`: the card shows once the operation has run this long.
            pending = schedule(delayMs / 1000) { [weak self] in
                guard let self else { return }
                self.pending = nil
                guard self.state != nil else { return }
                self.isVisible = true
                self.onChange()
            }
        }
        _ = wasNil
    }

    /// Shows the card at once (a capture, a test).
    func showNow() {
        pending?.cancel()
        pending = nil
        guard state != nil else { return }
        isVisible = true
        onChange()
    }
}

/// The small push button (`.push-button.is-small`): 22 tall, 12 pt text, 12 each side.
final class SmallPushButton: TextControl {
    private static let font = ThemeFonts.sans(DesignTokens.progressCard.stopFontSize)

    init(title: String, theme: Theme, target: AnyObject?, action: Selector?) {
        super.init(text: title, theme: theme)
        self.target = target
        self.action = action
        font = Self.font
        alignment = .center
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        textColor = NSColor(theme.palette.textPrimary)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredWidth: CGFloat {
        let layout = DesignTokens.progressCard
        return max(
            CGFloat(layout.stopMinWidth),
            (title as NSString).size(withAttributes: [.font: Self.font]).width
                + CGFloat(2 * layout.stopPaddingHorizontal))
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        textColor = NSColor(theme.palette.textPrimary)
    }

    override func drawChrome() {
        let radius = CGFloat(DesignTokens.radii.control)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let palette = theme.palette
        NSColor(palette.pushButtonBg).setFill()
        shape.fill()
        for layer in palette.pushButtonBezel where layer.blur == 0 && layer.spread > 0 {
            NSColor(layer.color).setStroke()
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = CGFloat(layer.spread)
            edge.stroke()
        }
        if isHovering { NSColor(palette.bgHover).setFill(); shape.fill() }
        if isPressed {
            NSColor.black.withAlphaComponent(CGFloat(1 - palette.pushButtonPressed)).setFill()
            shape.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if track() { perform() }
    }
}

/// The accent bar of the card: a 4 pt track with the fill as far along as the operation is.
final class ProgressTrackView: NSView, ThemeApplying {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    private var theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityIdentifier("progressCard.track")
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor(theme.palette.textPrimary.withAlpha(0.12)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = bounds.width * CGFloat(min(1, max(0, fraction)))
        guard width > 0 else { return }
        NSColor(theme.accent.solid).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius)
            .fill()
    }
}

/// A running file operation: a card on the notifications' surface, with what it is doing, how far along it is, the
/// item it is on, and Stop.
@MainActor
final class ProgressCardView: NSView, ThemeApplying {
    private var theme: Theme
    private let title: ThemedText
    private let percent: ThemedText
    private let track: ProgressTrackView
    private let detailLabel: ThemedText
    private let detailValue: ThemedText
    private let meta: ThemedText
    private let stop: SmallPushButton
    private var text: ProgressCardText?
    var onStop: () -> Void = {}

    private var metrics: ProgressCardLayout { DesignTokens.progressCard }

    private static func styles(_ theme: Theme) -> (title: TextStyle, percent: TextStyle, small: TextStyle, value: TextStyle) {
        let scale = DesignTokens.typeScale
        return (
            TextStyle(font: ThemeFonts.sans(scale.body, .semibold), color: { $0.palette.textPrimary }),
            TextStyle(font: ThemeFonts.sans(scale.callout), color: { $0.palette.textSecondary }),
            TextStyle(font: ThemeFonts.sans(scale.small), color: { $0.palette.textSecondary }),
            TextStyle(font: ThemeFonts.sans(scale.small), color: { $0.palette.textPrimary })
        )
    }

    init(theme: Theme) {
        self.theme = theme
        let styles = Self.styles(theme)
        title = ThemedText("", style: styles.title)
        percent = ThemedText("", style: styles.percent)
        track = ProgressTrackView(theme: theme)
        detailLabel = ThemedText("", style: styles.small)
        detailValue = ThemedText("", style: styles.value)
        meta = ThemedText("", style: styles.small)
        stop = SmallPushButton(title: "Stop", theme: theme, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("progressCard")
        setAccessibilityRole(.group)
        title.setAccessibilityIdentifier("progressCard.title")
        percent.setAccessibilityIdentifier("progressCard.percent")
        detailLabel.setAccessibilityIdentifier("progressCard.detailLabel")
        detailValue.setAccessibilityIdentifier("progressCard.detailValue")
        meta.setAccessibilityIdentifier("progressCard.meta")
        stop.setAccessibilityIdentifier("progressCard.stop")
        for field in [title, detailValue, meta] { field.lineBreakMode = .byTruncatingTail }
        stop.target = self
        stop.action = #selector(stopPressed)
        for view in [title, percent, track, detailLabel, detailValue, meta, stop] as [NSView] { addSubview(view) }
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    @objc private func stopPressed() { onStop() }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        MenuSurface.apply(to: layer, theme: theme, borderWidth: metrics.borderWidth)
        for view in subviews { view.applyTheme(theme, throughSubviews: true) }
    }

    func show(_ text: ProgressCardText) {
        self.text = text
        title.content = { [style = Self.styles(theme).title] in style.string(text.title, $0) }
        percent.content = { [style = Self.styles(theme).percent] in style.string(text.percentLabel, $0) }
        detailLabel.content = { [style = Self.styles(theme).small] in style.string(text.detailLabel + ":", $0) }
        detailValue.content = { [style = Self.styles(theme).value] in style.string(text.detailValue, $0) }
        meta.content = { [style = Self.styles(theme).small] in style.string("\(text.metaStart) · \(text.metaEnd)", $0) }
        detailValue.toolTip = text.detailValue
        track.fraction = min(100, max(0, text.percent)) / 100
        setAccessibilityLabel(text.title)
        needsLayout = true
    }

    /// The card's size in a window `available` wide (320, or the window less 24).
    func fittingSize(availableWidth: CGFloat) -> NSSize {
        let width = min(metrics.width, Double(availableWidth) - metrics.windowMargin)
        let line = title.height(forWidth: 10_000)
        let small = detailLabel.height(forWidth: 10_000)
        let footer = max(small, CGFloat(metrics.stopHeight))
        let height = 2 * metrics.borderWidth + metrics.paddingTop + metrics.paddingBottom + Double(line)
            + 3 * metrics.rowGap + metrics.trackHeight + Double(small) + Double(footer)
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        let border = metrics.borderWidth
        let left = border + metrics.paddingHorizontal
        let innerWidth = bounds.width - 2 * left
        var y = border + metrics.paddingTop
        // Header: the title, and the percent at the end; both share a baseline.
        let line = title.height(forWidth: 10_000)
        percent.sizeToFitWidth()
        let percentWidth = percent.frame.width
        percent.frame = NSRect(x: left + innerWidth - percentWidth, y: y, width: percentWidth, height: line)
        title.frame = NSRect(
            x: left, y: y, width: max(0, innerWidth - percentWidth - metrics.headerGap), height: line)
        y += line + metrics.rowGap
        track.frame = NSRect(x: left, y: y, width: innerWidth, height: metrics.trackHeight)
        y += metrics.trackHeight + metrics.rowGap
        let small = detailLabel.height(forWidth: 10_000)
        detailLabel.sizeToFitWidth()
        let labelWidth = detailLabel.frame.width
        detailLabel.frame = NSRect(x: left, y: y, width: labelWidth, height: small)
        let valueStart = left + labelWidth + metrics.detailGap
        detailValue.frame = NSRect(x: valueStart, y: y, width: max(0, left + innerWidth - valueStart), height: small)
        y += small + metrics.rowGap
        let footer = max(small, CGFloat(metrics.stopHeight))
        let stopWidth = stop.preferredWidth
        stop.frame = NSRect(
            x: left + innerWidth - stopWidth, y: y + (footer - CGFloat(metrics.stopHeight)) / 2, width: stopWidth,
            height: metrics.stopHeight)
        meta.frame = NSRect(
            x: left, y: y + (footer - small) / 2, width: max(0, innerWidth - stopWidth - metrics.footerGap),
            height: small)
    }
}

extension ThemedText {
    /// The frame as wide as the text, for text laid out from its leading or trailing edge.
    func sizeToFitWidth() {
        frame.size = NSSize(width: naturalWidth, height: frame.height)
    }
}
