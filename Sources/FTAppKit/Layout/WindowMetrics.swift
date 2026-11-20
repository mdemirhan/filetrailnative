import AppKit
import FTFoundation

/// The one place the UI builds its `Metrics`: every view of the explorer window takes its sizes from here, so a
/// change to how metrics are made (density) is one line.
@MainActor
enum WindowMetrics {
    /// The metrics for a density, at 100% sizes (there is no UI zoom).
    static func metrics(density: Density = .standard) -> Metrics {
        Metrics(density: density)
    }

    static let standard = metrics()
}

/// The theme's and the accent's colors for a view, as drawn in its appearance, with the accent the preferences chose.
@MainActor
enum ChromeColors {
    static func appearance(of view: NSView?) -> ThemeAppearance {
        let appearance = view?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    static func palette(for view: NSView?) -> ThemePalette {
        ThemePalette.palette(for: appearance(of: view))
    }

    static func accent(for view: NSView?) -> AccentPalette {
        AccentPalette(hex: AppearanceModel.shared.accentHex, appearance: appearance(of: view))
    }

    static func color(_ rgba: RGBA) -> NSColor {
        NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    /// The color at `percent` of its strength: its alpha scaled by `percent` / 100.
    static func color(_ rgba: RGBA, percent: Double) -> NSColor {
        color(rgba.withAlpha(rgba.alpha * percent / 100))
    }

    /// A system color as it is in a view's appearance (a `cgColor`, or a changed alpha, would otherwise take the current
    /// one's).
    private static func resolved(_ color: NSColor, for view: NSView?) -> NSColor {
        var result = color
        (view?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// The toolbar's title: the system's label color, as it is the window's title, and dimmed while the window isn't
    /// key. It was Finder's grey (0.70 black, where the label is 0.847), which read as disabled beside the toolbar's
    /// black symbols.
    static func toolbarTitle(for view: NSView?, isKey: Bool) -> NSColor {
        resolved(isKey ? .labelColor : .tertiaryLabelColor, for: view)
    }

    /// The system font at a size and a numbered weight: 400 regular, 500 medium, 600 semibold, 700 bold.
    static func font(size: Double, weight: Int = 400) -> NSFont {
        let weights: [Int: NSFont.Weight] = [500: .medium, 600: .semibold, 700: .bold]
        return NSFont.systemFont(ofSize: size, weight: weights[weight] ?? .regular)
    }
}
