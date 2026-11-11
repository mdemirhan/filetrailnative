// Colors and fonts of the theme as AppKit draws them
import AppKit
import FTFoundation

extension NSColor {
    /// The color in sRGB, as the theme gives it.
    public convenience init(_ color: RGBA) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension RGBA {
}

/// The app's two fonts: the system font, and the system's monospaced font.
public enum ThemeFonts {
    public static func sans(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: CGFloat(size), weight: weight)
    }

    public static func mono(_ size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
}
