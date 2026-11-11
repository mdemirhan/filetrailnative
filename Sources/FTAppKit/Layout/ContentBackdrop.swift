import AppKit

/// The content's background, Finder's: the system's content material. White in light mode; in dark mode a dark gray
/// with the desktop picture's tint, as Finder's. A flat color can't follow the tint, so every view that shows the
/// content's background holds one of these under its own views: the columns, and what lies over scrolling content
/// (the Info panel, the path bar, the headers). Each takes its color from the desktop, not from what lies under it in
/// the window, so they all show the same color wherever they are.
final class ContentBackdrop: NSVisualEffectView {
    /// Finder's path bar is a little lighter than its content in dark mode: white at this strength over the material,
    /// measured from Finder's screenshots ((41, 44, 45) over (33, 37, 38)).
    static let liftedStrength = 0.033

    /// The lift, over the material.
    let shade = NSView()

    /// Lighter in dark mode, as Finder's path bar.
    var isLifted = false {
        didSet { applyShade() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .contentBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        shade.wantsLayer = true
        shade.frame = bounds
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
        applyShade()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks go to the view it lies under.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShade()
    }

    private func applyShade() {
        let lifted = isLifted && ChromeColors.appearance(of: self) == .dark
        shade.layer?.backgroundColor = lifted ? NSColor(white: 1, alpha: Self.liftedStrength).cgColor : nil
    }
}
