// Port of the metrics the explorer window reads from apps/desktop/src/renderer/lib/layoutTokens.ts and styles.css
import AppKit
import FTFoundation

/// The one place the UI builds its `Metrics`: every view of the explorer window takes its sizes from here, so a
/// change to how metrics are made (density, D-005's zoom removal) is one line.
@MainActor
enum WindowMetrics {
    /// The metrics for a density (the original's 100% sizes; UI zoom is not ported, D-005).
    static func metrics(density: Density = .comfortable) -> Metrics {
        Metrics(zoom: 100, density: density)
    }

    static let standard = metrics()
}

/// The theme's and the accent's colors for a view, as drawn in its appearance. The app-wide appearance object
/// (P4-03) gives the chosen accent; until then the default one.
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
        AccentPalette(hex: AccentPalette.defaultHex, appearance: appearance(of: view))
    }

    static func color(_ rgba: RGBA) -> NSColor {
        NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    /// `color-mix(in srgb, <color> <percent>%, transparent)`.
    static func color(_ rgba: RGBA, percent: Double) -> NSColor {
        color(rgba.withAlpha(rgba.alpha * percent / 100))
    }

    /// The font the original names with `--font-sans` at a size and CSS weight.
    static func font(size: Double, weight: Int = 400) -> NSFont {
        let weights: [Int: NSFont.Weight] = [500: .medium, 600: .semibold, 700: .bold]
        return NSFont.systemFont(ofSize: size, weight: weights[weight] ?? .regular)
    }
}
