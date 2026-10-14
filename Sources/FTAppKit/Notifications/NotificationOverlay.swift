// Port of apps/desktop/src/renderer/lib/bottomStack.ts and the placement rules of ToastViewport.tsx and
// CopyPasteProgressCard.tsx
import AppKit
import FTFoundation

/// The bottom right of a window: a running operation's card above the path bar and the Info Row, and the
/// notifications above the card when there is one. It covers the window and takes no mouse events.
@MainActor
final class NotificationOverlay: NSView {
    let toasts = ToastCenter()
    let progress = ProgressCardModel()

    /// The bars at the bottom of the window the stack rests above (`.content-pathbar-row`, `.info-row.open`).
    var bars: () -> [NSView] = { [] }
    private var theme = AppearanceModel.shared.theme
    private var themeObservation: AppearanceModel.Observation?
    private var cards: [String: ToastCardView] = [:]
    private let card: ProgressCardView

    static func install(in host: NSView, bars: @escaping () -> [NSView], isEnabled: @escaping () -> Bool)
        -> NotificationOverlay
    {
        let overlay = NotificationOverlay()
        overlay.bars = bars
        overlay.toasts.isEnabled = isEnabled
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
        return overlay
    }

    /// The overlay of the window the notification is for (the window in front when none is given).
    static func overlay(for window: NSWindow?) -> NotificationOverlay? {
        let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        return window?.contentView?.subviews.lazy.compactMap { $0 as? NotificationOverlay }.first
    }

    /// Shows a notification in the window (`pushToast`); false when no window can take one.
    @discardableResult
    static func push(_ kind: ToastKind, title: String, message: String? = nil, in window: NSWindow?) -> Bool {
        guard let overlay = overlay(for: window) else { return false }
        overlay.toasts.push(kind, title: title, message: message)
        return true
    }

    init() {
        card = ProgressCardView(theme: AppearanceModel.shared.theme)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        card.isHidden = true
        addSubview(card)
        toasts.onChange = { [weak self] arrived in self?.toastsChanged(arrived: arrived) }
        progress.onChange = { [weak self] in self?.progressChanged() }
        card.onStop = { [weak self] in self?.progress.onStop() }
        themeObservation = AppearanceModel.shared.observe { [weak self] theme in
            guard let self else { return }
            self.theme = theme
            for view in self.subviews { view.applyTheme(theme, throughSubviews: true) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the card's Stop button takes the mouse.
        guard !card.isHidden else { return nil }
        let hit = card.hitTest(convert(point, from: superview))
        return hit === card ? nil : hit
    }

    /// Notifications are turned off: those showing go (`notificationsEnabled`).
    func notificationsSettingChanged() {
        if !toasts.isEnabled() { toasts.clear() }
    }

    // MARK: Showing

    private func progressChanged() {
        if let text = progress.text {
            card.show(text)
            card.isHidden = false
        } else {
            card.isHidden = true
        }
        // The notifications rest above the card: placed again when it comes or goes.
        needsLayout = true
    }

    private func toastsChanged(arrived: String?) {
        let showing = Set(toasts.entries.map(\.id))
        for (id, view) in cards where !showing.contains(id) {
            view.removeFromSuperview()
            cards[id] = nil
        }
        var added: ToastCardView?
        for entry in toasts.entries where cards[entry.id] == nil {
            let view = ToastCardView(entry: entry, theme: theme)
            cards[entry.id] = view
            addSubview(view)
            if entry.id == arrived { added = view }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let added { slideIn(added) }
    }

    /// The slide-in of a notification: 8 pt up, fading in, 180 ms (`toast-slide-in`).
    private func slideIn(_ view: ToastCardView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = view.layer else { return }
        let duration = DesignTokens.motion.base / 1000
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = DesignTokens.toast.slideDistance
        slide.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "toast-slide-in")
    }

    // MARK: Layout

    /// `offsetAboveBars`: the gap from the window's bottom edge to just above the bars on screen.
    func offsetAboveBars() -> Double {
        BottomStack.offsetAboveBars(windowHeight: Double(bounds.height), barTops: barTops())
    }

    override func layout() {
        super.layout()
        let metrics = DesignTokens.toast
        let cardMetrics = DesignTokens.progressCard
        let bottom = offsetAboveBars()
        var cardHeight: Double?
        if !card.isHidden {
            let size = card.fittingSize(availableWidth: bounds.width)
            card.frame = NSRect(
                x: bounds.width - cardMetrics.rightInset - size.width,
                y: bounds.height - bottom - size.height, width: size.width, height: size.height)
            cardHeight = Double(size.height)
        }
        // The notifications stack upward from just above the card (or the bars), the newest at the bottom.
        var y =
            bounds.height
            - CGFloat(
                BottomStack.offsetAboveBarsAndCard(
                    windowHeight: Double(bounds.height), barTops: barTops(), cardHeight: cardHeight))
        for entry in toasts.entries.reversed() {
            guard let view = cards[entry.id] else { continue }
            let size = view.fittingSize(availableWidth: bounds.width)
            y -= size.height
            view.frame = NSRect(
                x: bounds.width - metrics.rightInset - size.width, y: y, width: size.width, height: size.height)
            y -= metrics.stackGap
        }
    }

    private func barTops() -> [Double] {
        bars().filter { $0.window === window && !$0.isHidden && $0.frame.height > 0 }
            .map { Double(convert($0.bounds, from: $0).minY) }
    }
}
