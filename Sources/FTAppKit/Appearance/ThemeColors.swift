// Colors and fonts of the stylesheet (apps/desktop/src/renderer/styles.css) as AppKit draws them
import AppKit
import FTFoundation

extension NSColor {
    /// The color in sRGB, as the stylesheet writes it.
    public convenience init(_ color: RGBA) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension RGBA {
    public var nsColor: NSColor { NSColor(self) }
}

/// The fonts of `--font-sans` and `--font-mono`: the system fonts the stacks name.
public enum ThemeFonts {
    public static func sans(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: CGFloat(size), weight: weight)
    }

    public static func mono(_ size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
}
