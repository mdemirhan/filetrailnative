// Port of the box-shadow tokens in apps/desktop/src/renderer/styles.css
import Foundation

public enum ThemeAppearance: String, CaseIterable, Sendable {
    case light
    case dark
}

/// One layer of a CSS `box-shadow`. AppKit draws these itself; the values are kept so the
/// native look can be checked against the stylesheet.
public struct ShadowLayer: Equatable, Sendable {
    public var inset: Bool
    public var x: Double
    public var y: Double
    public var blur: Double
    public var spread: Double
    public var color: RGBA

    public init(inset: Bool = false, x: Double, y: Double, blur: Double, spread: Double = 0, color: RGBA) {
        self.inset = inset
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.color = color
    }

    /// The stylesheet's spelling: zero lengths are bare, and a zero spread is left out.
    public var cssString: String {
        func length(_ value: Double) -> String { value == 0 ? "0" : formatCSSNumber(value) + "px" }
        var parts = [length(x), length(y), length(blur)]
        if spread != 0 { parts.append(length(spread)) }
        return (inset ? "inset " : "") + parts.joined(separator: " ") + " " + color.cssString
    }
}

extension [ShadowLayer] {
    /// `none` when empty.
    public var cssString: String {
        isEmpty ? "none" : map(\.cssString).joined(separator: ", ")
    }
}
