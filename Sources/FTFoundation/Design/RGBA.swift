// Port of apps/desktop/src/renderer/lib/colorUtils.ts (hexToRgb, withAlpha, darkenHex)
import Foundation

/// A colour in sRGB, each component 0...1. Channels that came from a `#rrggbb` string hold
/// `byte / 255`, so `bytes` reads the exact original back.
public struct RGBA: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From 0...255 channels, as written in CSS.
    public init(r: Int, g: Int, b: Int, alpha: Double = 1) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: alpha)
    }

    /// `#rrggbb` (a leading `#` is optional). Nil for anything else.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(r: (value >> 16) & 255, g: (value >> 8) & 255, b: value & 255)
    }

    /// `#rrggbb`, `rgb()`/`rgba()` or `transparent`: the spellings the reference stylesheet uses.
    public init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "transparent" {
            self.init(r: 0, g: 0, b: 0, alpha: 0)
        } else if text.hasPrefix("#") {
            self.init(hex: text)
        } else if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") {
            let parts = text[text.index(after: open)..<close].split(separator: ",").map {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard parts.count == 3 || parts.count == 4, !parts.contains(where: { $0 == nil }) else { return nil }
            let values = parts.compactMap { $0 }
            self.init(
                red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255,
                alpha: values.count == 4 ? values[3] : 1)
        } else {
            return nil
        }
    }

    public static let white = RGBA(r: 255, g: 255, b: 255)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let clear = RGBA(r: 0, g: 0, b: 0, alpha: 0)

    /// The channels as 0...255 integers, rounded as JavaScript's `Math.round` does.
    public var bytes: (r: Int, g: Int, b: Int) {
        (Self.byte(red), Self.byte(green), Self.byte(blue))
    }

    private static func byte(_ channel: Double) -> Int {
        Int((channel * 255).rounded(.toNearestOrAwayFromZero))
    }

    /// The same colour with a different alpha (`withAlpha` in the reference).
    public func withAlpha(_ alpha: Double) -> RGBA {
        var copy = self
        copy.alpha = alpha
        return copy
    }

    /// `#rrggbb`, ignoring alpha.
    public var hexString: String {
        let (r, g, b) = bytes
        return "#" + [r, g, b].map { String(format: "%02x", $0) }.joined()
    }

    /// The reference's spelling: `#rrggbb` when opaque, otherwise `rgba(r, g, b, a)`.
    public var cssString: String {
        if alpha == 1 { return hexString }
        let (r, g, b) = bytes
        return "rgba(\(r), \(g), \(b), \(formatCSSNumber(alpha)))"
    }
}

/// A number as JavaScript prints it for the values used here: no trailing `.0`.
func formatCSSNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    return "\(value)"
}
