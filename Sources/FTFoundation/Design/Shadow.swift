import Foundation

public enum ThemeAppearance: String, CaseIterable, Sendable {
    case light
    case dark
}

/// One layer of a shadow, as `box-shadow` writes it: offset, blur, spread and colour.
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
}
