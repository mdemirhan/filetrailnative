// Port of AppearanceThumbnail, AppearanceModePicker and AccentSelector of
// apps/desktop/src/renderer/components/SettingsView.tsx, drawn as styles.css:5588-5740 draws them
import AppKit
import FTFoundation

/// One of Auto, Light and Dark: a small picture of a window in a ring, and its name under it.
final class AppearanceOption: SettingsControlView {
    let mode: ThemePreference
    let title: String
    var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected ? 1 : 0)
            label.content = { [title, isSelected] theme in Self.labelStyle(isSelected).string(title, theme) }
            needsDisplay = true
        }
    }
    let label: ThemedText

    static func labelStyle(_ selected: Bool) -> TextStyle {
        var style = SettingsStyle.style(DesignTokens.typeScale.small, selected ? .semibold : .regular) {
            selected ? $0.palette.textPrimary : $0.palette.settingsLabelSecondary
        }
        style.alignment = .center
        return style
    }

    init(mode: ThemePreference, title: String, theme: Theme) {
        self.mode = mode
        self.title = title
        label = ThemedText(title, style: Self.labelStyle(false))
        super.init(theme: theme)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("settings.appearance")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var ringSize: NSSize {
        let padding = SettingsMetrics.appearanceRingPadding
        return NSSize(
            width: SettingsMetrics.thumbSize.width + 2 * padding, height: SettingsMetrics.thumbSize.height + 2 * padding
        )
    }

    var preferredSize: NSSize {
        let ring = ringSize
        let labelHeight = ThemeFonts.normalLineHeight(ThemeFonts.sans(DesignTokens.typeScale.small))
        return NSSize(
            width: max(ring.width, label.naturalWidth),
            height: ring.height + SettingsMetrics.appearanceLabelGap + labelHeight)
    }

    override func layout() {
        super.layout()
        let ring = ringSize
        let labelHeight = bounds.height - ring.height - SettingsMetrics.appearanceLabelGap
        label.frame = NSRect(
            x: 0, y: ring.height + SettingsMetrics.appearanceLabelGap, width: bounds.width, height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ring = ringSize
        let ringRect = NSRect(x: (bounds.width - ring.width) / 2, y: 0, width: ring.width, height: ring.height)
        if isSelected {
            let width = SettingsMetrics.appearanceRingWidth
            let path = NSBezierPath(
                roundedRect: ringRect.insetBy(dx: -width / 2, dy: -width / 2),
                xRadius: SettingsMetrics.appearanceRingRadius + width / 2,
                yRadius: SettingsMetrics.appearanceRingRadius + width / 2)
            path.lineWidth = width
            NSColor(theme.accent.solid).setStroke()
            path.stroke()
        }
        let padding = SettingsMetrics.appearanceRingPadding
        let thumb = NSRect(
            x: ringRect.minX + padding, y: padding, width: SettingsMetrics.thumbSize.width,
            height: SettingsMetrics.thumbSize.height)
        drawThumbnail(in: thumb)
    }

    /// Auto is the light window with the dark one over its right half.
    private func drawThumbnail(in rect: NSRect) {
        let radius = SettingsMetrics.thumbRadius
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawHalf(mode == .dark ? SettingsMetrics.thumbDark : SettingsMetrics.thumbLight, in: rect)
        if mode == .auto {
            NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height).clip()
            drawHalf(SettingsMetrics.thumbDark, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        let half = SettingsMetrics.hairline / 2
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: -half, dy: -half), xRadius: radius, yRadius: radius)
        edge.lineWidth = SettingsMetrics.hairline
        NSColor(SettingsMetrics.thumbEdge).setStroke()
        edge.stroke()
    }

    private func drawHalf(_ colors: (side: RGBA, main: RGBA, bar: RGBA), in rect: NSRect) {
        NSColor(colors.main).setFill()
        rect.fill()
        NSColor(colors.side).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: SettingsMetrics.thumbSideWidth, height: rect.height).fill()
        let left = rect.minX + SettingsMetrics.thumbSideWidth + SettingsMetrics.thumbPaddingHorizontal
        let width = rect.maxX - SettingsMetrics.thumbPaddingHorizontal - left
        var y = rect.minY + SettingsMetrics.thumbPaddingVertical
        for (index, fraction) in SettingsMetrics.thumbBarWidths.enumerated() {
            NSColor(index == 1 ? theme.accent.solid : colors.bar).setFill()
            let bar = NSRect(x: left, y: y, width: width * fraction, height: SettingsMetrics.thumbBarHeight)
            NSBezierPath(
                roundedRect: bar, xRadius: SettingsMetrics.thumbBarRadius, yRadius: SettingsMetrics.thumbBarRadius
            ).fill()
            y += SettingsMetrics.thumbBarHeight + SettingsMetrics.thumbBarGap
        }
    }
}

/// `AppearanceModePicker`: Auto, Light and Dark, like System Settings.
final class AppearancePicker: NSView, SettingsSized {
    private(set) var options: [AppearanceOption] = []
    var onChange: (ThemePreference) -> Void = { _ in }

    init(theme selected: ThemePreference, appTheme: Theme) {
        super.init(frame: .zero)
        for option in AppPreferenceLimits.themeOptions {
            let view = AppearanceOption(mode: option.value, title: option.label, theme: appTheme)
            view.onPress = { [weak self] in self?.onChange(option.value) }
            options.append(view)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Theme")
        update(selected)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func update(_ selected: ThemePreference) {
        for option in options { option.isSelected = option.mode == selected }
    }

    var preferredSize: NSSize {
        let sizes = options.map(\.preferredSize)
        return NSSize(
            width: sizes.map(\.width).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * SettingsMetrics.appearanceGap,
            height: sizes.map(\.height).max() ?? 0)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for option in options {
            let size = option.preferredSize
            option.frame = NSRect(x: x, y: 0, width: size.width, height: size.height)
            x += size.width + SettingsMetrics.appearanceGap
        }
    }
}

/// A swatch of an accent: a 15 pt circle, ringed when it is the accent.
final class AccentSwatch: SettingsControlView {
    /// The preset's color, or nil for the custom swatch.
    let color: RGBA?
    let value: String?
    var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected ? 1 : 0)
            needsDisplay = true
        }
    }
    /// The custom color shown inside the custom swatch while the accent is one.
    var customFill: RGBA? { didSet { needsDisplay = true } }

    init(value: String?, label: String, theme: Theme) {
        self.value = value
        color = value.flatMap(RGBA.init(hex:))
        super.init(theme: theme)
        toolTip = value == nil ? "Custom Color" : label
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("Accent color \(label)")
        setAccessibilityIdentifier("settings.accent")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(
            x: (bounds.width - SettingsMetrics.swatchSize) / 2, y: (bounds.height - SettingsMetrics.swatchSize) / 2,
            width: SettingsMetrics.swatchSize, height: SettingsMetrics.swatchSize)
        if isSelected {
            // 0 0 0 2px page, 0 0 0 3.5px accent: an accent ring 1.5 wide, 2 out from the swatch.
            let outer = SettingsMetrics.swatchRingOuter
            let inner = SettingsMetrics.swatchRingGap
            let width = outer - inner
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -(inner + width / 2), dy: -(inner + width / 2)))
            ring.lineWidth = width
            NSColor(theme.accent.solid).setStroke()
            ring.stroke()
        }
        let shape = NSBezierPath(ovalIn: circle)
        if let color {
            NSColor(color).setFill()
            shape.fill()
        } else {
            drawConic(in: circle)
            if let customFill {
                NSColor(customFill).setFill()
                let inset = SettingsMetrics.customFillInset
                NSBezierPath(ovalIn: circle.insetBy(dx: inset, dy: inset)).fill()
            }
        }
        let half = SettingsMetrics.hairline / 2
        let edge = NSBezierPath(ovalIn: circle.insetBy(dx: half, dy: half))
        edge.lineWidth = SettingsMetrics.hairline
        NSColor(SettingsMetrics.swatchEdge).setStroke()
        edge.stroke()
    }

    /// `conic-gradient(from 210deg, …)`: wedges of the colors between the stops, clockwise from 210 degrees.
    private func drawConic(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        let stops = SettingsMetrics.customSwatchStops
        let steps = SettingsMetrics.conicSteps
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width
        for step in 0..<steps {
            let t = Double(step) / Double(steps)
            let segment = t * Double(stops.count - 1)
            let index = min(stops.count - 2, Int(segment))
            let mix = segment - Double(index)
            let a = stops[index]
            let b = stops[index + 1]
            NSColor(
                srgbRed: a.red + (b.red - a.red) * mix, green: a.green + (b.green - a.green) * mix,
                blue: a.blue + (b.blue - a.blue) * mix, alpha: 1
            ).setFill()
            // CSS angles start at the top and go clockwise; the view is flipped (y down).
            let start = (Double(SettingsMetrics.customSwatchStartDegrees) + t * 360 - 90)
            // Each wedge overlaps the next a little, so no seam shows between them.
            let end = start + 360 / Double(steps) + Double(SettingsMetrics.hairline)
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            wedge.close()
            wedge.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Opens the system's color picker on a color, and tells each color picked.
typealias ColorPicker = @MainActor (String, @escaping @MainActor (String) -> Void) -> Void

/// `AccentSelector`: the accent colors as a row of swatches, with a custom color at the end that opens the system's
/// color picker (B-DLG-236).
final class AccentSelector: NSView, SettingsSized {
    private(set) var swatches: [AccentSwatch] = []
    var onChange: (String) -> Void = { _ in }
    private(set) var accent: String
    /// Opens the color picker on a color; P6-04 uses NSColorPanel, tests replace it.
    var openColorPicker: ColorPicker = AccentSelector.openColorPanel

    init(accent: String, theme: Theme) {
        self.accent = accent
        super.init(frame: .zero)
        for option in AppPreferenceLimits.accentOptions {
            let swatch = AccentSwatch(value: option.value, label: option.label, theme: theme)
            swatch.onPress = { [weak self] in self?.onChange(option.value) }
            swatches.append(swatch)
            addSubview(swatch)
        }
        let custom = AccentSwatch(value: nil, label: "Custom", theme: theme)
        custom.onPress = { [weak self] in self?.openCustom() }
        swatches.append(custom)
        addSubview(custom)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Accent color")
        update(accent)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var customSwatch: AccentSwatch? { swatches.last }

    func update(_ accent: String) {
        self.accent = accent
        let isPreset = AppPreferenceLimits.accentOptions.contains { $0.value == accent }
        for swatch in swatches {
            swatch.isSelected = swatch.value == nil ? !isPreset : swatch.value == accent
        }
        customSwatch?.customFill = isPreset ? nil : RGBA(hex: accent)
    }

    /// The custom swatch: the picker opens on the accent if it is a color, else on the default; a picked value is
    /// taken only as `#rrggbb`.
    func openCustom() {
        let start = AppPreferenceLimits.normalizeAccentColor(accent) ?? AppPreferenceLimits.defaultAccent
        openColorPicker(start) { [weak self] picked in
            if let next = AppPreferenceLimits.normalizeAccentColor(picked) { self?.onChange(next) }
        }
    }

    var preferredSize: NSSize {
        let count = CGFloat(swatches.count)
        return NSSize(
            width: count * SettingsMetrics.swatchSize + (count - 1) * SettingsMetrics.swatchGap,
            height: SettingsMetrics.swatchSize)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for swatch in swatches {
            swatch.frame = NSRect(x: x, y: 0, width: SettingsMetrics.swatchSize, height: SettingsMetrics.swatchSize)
            x += SettingsMetrics.swatchSize + SettingsMetrics.swatchGap
        }
    }

    /// The system's color panel, telling each color picked as `#rrggbb`.
    static func openColorPanel(_ start: String, _ picked: @escaping @MainActor (String) -> Void) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        ColorPanelRelay.shared.picked = picked
        if let color = RGBA(hex: start) { panel.color = NSColor(color) }
        panel.setTarget(ColorPanelRelay.shared)
        panel.setAction(#selector(ColorPanelRelay.colorChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }
}

/// Hands the color panel's colors to the custom swatch.
@MainActor
final class ColorPanelRelay: NSObject {
    static let shared = ColorPanelRelay()
    var picked: (@MainActor (String) -> Void)?

    @objc func colorChanged(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        let hex = String(
            format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        picked?(hex)
    }
}
