import AppKit

/// The warning sign as macOS draws it: the filled triangle in the symbol's own colors, scaled to the view.
@MainActor
final class WarningSymbolView: NSImageView {
    init(identifier: String? = nil) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        symbolConfiguration = .preferringMulticolor()
        imageScaling = .scaleProportionallyUpOrDown
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
