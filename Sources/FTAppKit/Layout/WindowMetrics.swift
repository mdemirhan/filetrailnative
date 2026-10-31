// Port of the metrics the explorer window reads from apps/desktop/src/renderer/lib/layoutTokens.ts and styles.css
import AppKit
import FTFoundation

/// The one place the UI builds its `Metrics`: every view of the explorer window takes its sizes from here, so a
/// change to how metrics are made (density, D-005's zoom removal) is one line.
@MainActor
enum WindowMetrics {
    /// The metrics for a density (the original's 100% sizes; UI zoom is not ported, D-005).
    static func metrics(density: Density = .comfortable) -> Metrics {
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

    /// `color-mix(in srgb, <color> <percent>%, transparent)`.
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

    /// The content column's background, band included, Finder's: the system's, in every appearance (D-015).
    static func contentBackground(for view: NSView?) -> NSColor {
        resolved(.controlBackgroundColor, for: view)
    }

    /// How much of the system's label color Finder's toolbar title shows in a key window: 0.70 black on its white band
    /// against the label's 0.847, measured from Finder's screenshots.
    private static let toolbarTitleStrength = 0.7 / 0.847

    /// The toolbar's title, Finder's: the system's label color, dimmed as Finder's in a key window (D-015).
    static func toolbarTitle(for view: NSView?, isKey: Bool) -> NSColor {
        guard isKey else { return resolved(.tertiaryLabelColor, for: view) }
        let label = resolved(.labelColor, for: view)
        return label.withAlphaComponent(label.alphaComponent * toolbarTitleStrength)
    }

    /// The font the original names with `--font-sans` at a size and CSS weight.
    static func font(size: Double, weight: Int = 400) -> NSFont {
        let weights: [Int: NSFont.Weight] = [500: .medium, 600: .semibold, 700: .bold]
        return NSFont.systemFont(ofSize: size, weight: weights[weight] ?? .regular)
    }
}
