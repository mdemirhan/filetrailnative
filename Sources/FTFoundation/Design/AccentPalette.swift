// Port of apps/desktop/src/renderer/lib/accent.ts and theme.ts (plus the accent mixes in styles.css)
import Foundation

/// Every colour derived from the user's accent, computed exactly as the reference does. The
/// accent can be any hex colour, so nothing here uses `NSColor.controlAccentColor`.
public struct AccentPalette: Equatable, Sendable {
    /// The default accent (Blue), used when a saved value is not a `#rrggbb` colour.
    public static let defaultHex = "#007aff"

    public let solid: RGBA
    public let solidDark: RGBA
    /// Background of solid buttons: the accent, a touch darker if that keeps white text readable.
    public let solidButton: RGBA
    /// Text on `solidButton`: white or black, at least 4.5:1.
    public let onSolid: RGBA
    /// Fill of a selected row in the focused pane.
    public let selectionBg: RGBA
    /// Text on `selectionBg`: always white.
    public let onSelection: RGBA
    /// `--ft-accent-on-selection-soft`: selection text for secondary cells.
    public let onSelectionSoft: RGBA
    public let hoverBg: RGBA
    public let pillBg: RGBA
    public let pillText: RGBA
    public let border: RGBA
    public let focusBorder: RGBA
    public let softBg: RGBA
    public let activeBg: RGBA
    public let heroIconBg: RGBA
    public let folderTint: RGBA
    public let pathCrumbHover: RGBA
    public let actionHoverBg: RGBA
    public let searchPillBorder: RGBA
    public let locationRing: RGBA
    public let ringSoft: RGBA
    /// Text of the Rename sheet's marks (the accent mixed 65% with white in the dark theme).
    public let batchRenameMarkText: RGBA
    public let batchRenameMarkBg: RGBA

    /// `--focus-ring`: 3 px, the accent at 50%.
    public var focusRing: ShadowLayer {
        ShadowLayer(x: 0, y: 0, blur: 0, spread: 3, color: solid.withAlpha(0.5))
    }

    /// An unparseable `hex` falls back to the default accent.
    public init(hex: String, appearance: ThemeAppearance) {
        let accent = RGBA(hex: hex) ?? RGBA(hex: Self.defaultHex) ?? .black
        let isLight = appearance == .light
        let profile = isLight ? Profile.light : Profile.dark
        let dark = Self.darken(accent, by: Self.darkShade)
        let button = Self.solidButtonColors(accent)
        let selection = Self.selectionColors(accent)

        solid = accent
        solidDark = dark
        solidButton = button.background
        onSolid = button.foreground
        selectionBg = selection.background
        onSelection = selection.foreground
        onSelectionSoft = selection.foreground.withAlpha(0.85)
        hoverBg = accent.withAlpha(profile.hoverBgAlpha)
        pillBg = accent.withAlpha(profile.pillBgAlpha)
        pillText = isLight ? dark : accent
        border = accent.withAlpha(0.3)
        focusBorder = accent.withAlpha(profile.focusBorderAlpha)
        softBg = accent.withAlpha(0.08)
        activeBg = accent.withAlpha(profile.activeBgAlpha)
        heroIconBg = accent.withAlpha(profile.heroIconBgAlpha)
        folderTint = accent.withAlpha(profile.folderTintAlpha)
        pathCrumbHover = isLight ? dark : accent
        actionHoverBg = accent.withAlpha(profile.actionHoverBgAlpha)
        searchPillBorder = accent.withAlpha(profile.searchPillBorderAlpha)
        locationRing = accent.withAlpha(profile.locationRingAlpha)
        ringSoft = accent.withAlpha(0.15)
        if isLight {
            batchRenameMarkText = dark
            batchRenameMarkBg = accent.withAlpha(0.08)
        } else {
            batchRenameMarkText = Self.mix(accent, 65, .white)
            batchRenameMarkBg = accent.withAlpha(0.16)
        }
    }

    // MARK: Profiles

    private struct Profile {
        var hoverBgAlpha: Double
        var activeBgAlpha: Double
        var pillBgAlpha: Double
        var focusBorderAlpha: Double
        var heroIconBgAlpha: Double
        var actionHoverBgAlpha: Double
        var searchPillBorderAlpha: Double
        var locationRingAlpha: Double
        var folderTintAlpha: Double

        static let light = Profile(
            hoverBgAlpha: 0.14, activeBgAlpha: 0.08, pillBgAlpha: 0.14, focusBorderAlpha: 0.5,
            heroIconBgAlpha: 0.1, actionHoverBgAlpha: 0.1, searchPillBorderAlpha: 0.55,
            locationRingAlpha: 0.16, folderTintAlpha: 0.16)
        static let dark = Profile(
            hoverBgAlpha: 0.12, activeBgAlpha: 0.1, pillBgAlpha: 0.12, focusBorderAlpha: 0.4,
            heroIconBgAlpha: 0.08, actionHoverBgAlpha: 0.1, searchPillBorderAlpha: 0.5,
            locationRingAlpha: 0.14, folderTintAlpha: 0.14)
    }

    // MARK: Contrast math

    private static let darkShade = 0.18
    private static let minTextContrast = 4.5
    private static let maxButtonDarkening = 0.2
    private static let selectionDarkeningPercent = 14
    private static let maxSelectionDarkeningPercent = 34

    /// `darkenHex`: each channel scaled by `1 - factor`, rounded.
    static func darken(_ color: RGBA, by factor: Double) -> RGBA {
        let scale = max(0, min(1, 1 - factor))
        let (r, g, b) = color.bytes
        func scaled(_ channel: Int) -> Int { Int((Double(channel) * scale).rounded(.toNearestOrAwayFromZero)) }
        return RGBA(r: scaled(r), g: scaled(g), b: scaled(b))
    }

    /// WCAG relative luminance.
    static func relativeLuminance(_ color: RGBA) -> Double {
        func linear(_ byte: Int) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = color.bytes
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func contrastRatio(_ foreground: RGBA, _ background: RGBA) -> Double {
        let a = relativeLuminance(foreground)
        let b = relativeLuminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `solidButtonColors`: white text on the accent, darkened in 1% steps (up to 20%) until it
    /// reaches 4.5:1; otherwise black text on the plain accent.
    static func solidButtonColors(_ accent: RGBA) -> (background: RGBA, foreground: RGBA) {
        for step in 0...Int(maxButtonDarkening * 100) {
            let background = step == 0 ? accent : darken(accent, by: Double(step) / 100)
            if contrastRatio(.white, background) >= minTextContrast {
                return (background, .white)
            }
        }
        return (accent, .black)
    }

    /// `selectionColors`: the accent darkened by 14%, then further up to 34% until white text
    /// reaches 4.5:1.
    static func selectionColors(_ accent: RGBA) -> (background: RGBA, foreground: RGBA) {
        var percent = selectionDarkeningPercent
        var background = darken(accent, by: Double(percent) / 100)
        while percent < maxSelectionDarkeningPercent && contrastRatio(.white, background) < minTextContrast {
            percent += 1
            background = darken(accent, by: Double(percent) / 100)
        }
        return (background, .white)
    }

    /// `color-mix(in srgb, color percent%, other)` for an opaque `other`, rounded to bytes.
    static func mix(_ color: RGBA, _ percent: Double, _ other: RGBA) -> RGBA {
        let w1 = percent / 100
        let w2 = (100 - percent) / 100
        func channel(_ x: Int, _ y: Int) -> Int {
            Int(((Double(x) * 1 * w1 + Double(y) * 1 * w2) / 1).rounded(.toNearestOrAwayFromZero))
        }
        let (r1, g1, b1) = color.bytes
        let (r2, g2, b2) = other.bytes
        return RGBA(r: channel(r1, r2), g: channel(g1, g2), b: channel(b1, b2))
    }
}
