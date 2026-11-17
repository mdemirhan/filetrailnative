// The ring at the end of the toolbar's title while something runs in the background
import AppKit
import FTFoundation

/// The title's activity ring: at the end of the title's room while something runs in the background, so nothing in the
/// toolbar moves as it comes and goes. It fills as far as a file operation has gone, and spins while a folder is measured
/// or how far along isn't known; dimmed while all it lists waits. With others listed, a pill grows out to its left with
/// their count ("+2"), the ring staying where it is. A click opens the Activity list; a pointer over it shows the pill
/// as the system's borderless buttons do. A file operation that completes ends it with a check, which fades.
///
/// The rest of the title still drags the window; only the ring and its pill are pressed. Tab reaches it among the
/// toolbar's buttons (`ToolbarKeyboard`), where Return or Space opens the list.
final class TitleActivityView: NSView, ToolbarListAnchor {
    static let height = 26.0
    static let ringSize = 18.0
    /// Around the ring, inside the pill.
    static let inset = 4.0
    /// The count's room either side of its text.
    static let countPadding = 5.0
    /// How long the check shows, and how long it and the ring take to fade.
    static let checkDuration = 0.9
    static let fadeDuration = 0.25

    /// A click, Return or Space: the list opens or closes.
    var onClick: (() -> Void)?
    /// The width it wants changed (it came, went, or its count did): the title lays it out again.
    var onWidthChange: (() -> Void)?
    /// Turns the spinning off, as Reduce Motion asks; a test turns it on.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// What it shows now; nil once nothing runs.
    private(set) var indicator: ActivityIndicator?
    /// The check after a file operation completed, until it fades.
    private(set) var showsCheck = false
    /// The list is open under it.
    var isOn = false {
        didSet { updatePill() }
    }

    private let pill = CALayer()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let checkCircle = CAShapeLayer()
    private let checkMark = CAShapeLayer()
    let countField = NSTextField(labelWithString: "")
    private var hovering = false
    private var pressed = false
    private var takingKeyboard = false
    /// Counts the fades, so one that ends after something came back leaves it shown.
    private var generation = 0
    private static let spinKey = "spin"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for sublayer in [pill, track, arc, checkCircle, checkMark] { layer?.addSublayer(sublayer) }
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
        }
        checkMark.fillColor = nil
        checkMark.lineWidth = 1.8
        checkMark.lineCap = .round
        checkMark.lineJoin = .round
        countField.font = .systemFont(ofSize: 11, weight: .semibold)
        countField.alignment = .center
        countField.isHidden = true
        addSubview(countField)
        isHidden = true
        alphaValue = 0
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Activity")
        setAccessibilityIdentifier("toolbar.activity")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: What it shows

    /// Whether it takes room at the end of the title.
    var isShown: Bool { indicator != nil || showsCheck }

    /// Its width while shown: the ring, and the count's room when there is a count.
    var preferredWidth: Double {
        guard isShown else { return 0 }
        let ring = Self.ringSize + 2 * Self.inset
        guard !showsCheck, let label = indicator?.countLabel, let font = countField.font else { return ring }
        let text = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        return ring + text + 2 * Self.countPadding - Self.inset
    }

    /// How far round the ring is filled; nil while it spins or isn't shown. A test seam.
    var ringFill: Double? {
        guard indicator?.progress != nil, !showsCheck else { return nil }
        return Double(arc.strokeEnd)
    }

    /// It spins: the arc turns, or would but for Reduce Motion.
    var spins: Bool { indicator != nil && !showsCheck && indicator?.progress == nil }

    /// Shows `next`; nil ends it, with the check when it `endedWell`.
    func show(_ next: ActivityIndicator?, endedWell: Bool = false) {
        // Nothing new, nil again included: a check or a fade under way goes on.
        guard next != indicator else { return }
        let wasShown = isShown
        let oldWidth = preferredWidth
        generation += 1
        if let next {
            indicator = next
            showsCheck = false
        } else {
            indicator = nil
            showsCheck = endedWell
            if endedWell { scheduleFade(after: Self.checkDuration) }
        }
        updateLayers()
        if isShown, !wasShown {
            isHidden = false
            fade(to: 1)
        } else if !isShown, wasShown {
            fadeOut()
        }
        if preferredWidth != oldWidth { onWidthChange?() }
    }

    /// The ring's tooltip and what accessibility reads as its value: what runs, and how many more.
    func setSummary(_ summary: String) {
        toolTip = summary
        setAccessibilityHelp(summary)
        setAccessibilityValue(summary)
    }

    private func scheduleFade(after delay: Double) {
        let at = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == at, self.showsCheck else { return }
                self.showsCheck = false
                self.fadeOut()
            }
        }
    }

    private func fadeOut() {
        let at = generation
        fade(to: 0) { [weak self] in
            guard let self, self.generation == at, !self.isShown else { return }
            self.isHidden = true
            self.isOn = false
            self.hovering = false
            self.updateLayers()
            self.onWidthChange?()
            if self.window?.firstResponder === self { self.window?.makeFirstResponder(nil) }
        }
    }

    private func fade(to alpha: CGFloat, then done: (@MainActor () -> Void)? = nil) {
        guard window != nil, !reducesMotion() else {
            alphaValue = alpha
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayers()
    }

    /// The ring's square: at the right end, so it stays put as the count comes and goes.
    var ringFrame: NSRect {
        NSRect(
            x: bounds.maxX - Self.inset - Self.ringSize, y: (bounds.height - Self.ringSize) / 2, width: Self.ringSize,
            height: Self.ringSize)
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let ring = ringFrame
        let circle = CGPath(
            ellipseIn: CGRect(origin: .zero, size: ring.size).insetBy(dx: 1.5, dy: 1.5), transform: nil)
        for shape in [track, arc, checkCircle, checkMark] {
            shape.frame = ring
        }
        track.path = circle
        // From the top, clockwise as seen, in the view's flipped space.
        let center = CGPoint(x: ring.width / 2, y: ring.height / 2)
        let path = CGMutablePath()
        path.addArc(
            center: center, radius: ring.width / 2 - 1.5, startAngle: -.pi / 2, endAngle: 1.5 * .pi,
            clockwise: false)
        arc.path = path
        checkCircle.path = CGPath(ellipseIn: CGRect(origin: .zero, size: ring.size), transform: nil)
        checkMark.path = Self.checkPath(in: ring.size)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            arc.strokeColor = NSColor.controlAccentColor.cgColor
            checkCircle.fillColor = NSColor.controlAccentColor.cgColor
            checkMark.strokeColor = NSColor.white.cgColor
            countField.textColor = .secondaryLabelColor
        }

        let shown = indicator
        track.isHidden = shown == nil || showsCheck
        arc.isHidden = shown == nil || showsCheck
        checkCircle.isHidden = !showsCheck
        checkMark.isHidden = !showsCheck
        arc.opacity = shown?.isWaiting == true ? 0.4 : 1
        if let progress = shown?.progress {
            arc.removeAnimation(forKey: Self.spinKey)
            arc.transform = CATransform3DIdentity
            arc.strokeStart = 0
            setStrokeEnd(CGFloat(min(1, max(0, progress))))
        } else if shown != nil {
            arc.strokeStart = 0
            arc.strokeEnd = 0.28
            if reducesMotion() || window == nil {
                arc.removeAnimation(forKey: Self.spinKey)
            } else if arc.animation(forKey: Self.spinKey) == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = 0.9
                spin.repeatCount = .infinity
                arc.add(spin, forKey: Self.spinKey)
            }
        } else {
            arc.removeAnimation(forKey: Self.spinKey)
        }

        let label = showsCheck ? nil : shown?.countLabel
        countField.isHidden = label == nil
        if let label {
            countField.stringValue = label
            let height = ceil(countField.intrinsicContentSize.height)
            countField.frame = NSRect(
                x: Self.countPadding, y: (bounds.height - height) / 2,
                width: max(0, ring.minX - Self.countPadding - 1), height: height)
        }
        updatePill()
    }

    /// The fill moves on smoothly, as a progress bar does.
    private func setStrokeEnd(_ end: CGFloat) {
        guard arc.strokeEnd != end else { return }
        if window != nil, !reducesMotion() {
            let move = CABasicAnimation(keyPath: "strokeEnd")
            move.fromValue = arc.presentation()?.strokeEnd ?? arc.strokeEnd
            move.toValue = end
            move.duration = 0.25
            arc.add(move, forKey: "fill")
        }
        arc.strokeEnd = end
    }

    private static func checkPath(in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let scale = size.width / 18
        path.move(to: CGPoint(x: 5.6 * scale, y: 9.2 * scale))
        path.addLine(to: CGPoint(x: 7.9 * scale, y: 11.5 * scale))
        path.addLine(to: CGPoint(x: 12.4 * scale, y: 6.7 * scale))
        return path
    }

    /// The pill: under the count, and under the ring alone while the pointer is over it, it is pressed or its list is
    /// open.
    private func updatePill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        pill.frame = bounds
        pill.cornerRadius = bounds.height / 2
        let hasCount = !countField.isHidden
        let alpha: CGFloat =
            if pressed || isOn { 0.16 } else if hovering { 0.10 } else if hasCount { 0.06 } else { 0 }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }

    /// The pill's look, as a test reads it.
    var pillShown: Bool { (pill.backgroundColor?.alpha ?? 0) > 0 }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A press on the ring is the ring's, not a drag of the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown, !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updatePill()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updatePill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isShown else { return }
        pressed = true
        updatePill()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        hovering = bounds.contains(convert(event.locationInWindow, from: nil))
        updatePill()
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        updatePill()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isShown else { return false }
        onClick?()
        return true
    }

    override func isAccessibilityElement() -> Bool { isShown }

    // MARK: Keyboard

    /// Only Tab gives it the keyboard: a press never does.
    override var acceptsFirstResponder: Bool { takingKeyboard && isShown }
    override var canBecomeKeyView: Bool { false }

    @discardableResult
    func takeKeyboard() -> Bool {
        guard let window else { return false }
        takingKeyboard = true
        defer { takingKeyboard = false }
        return window.makeFirstResponder(self)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49: onClick?()
        case 48: ToolbarKeyboard.move(from: self, backward: event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }
}
