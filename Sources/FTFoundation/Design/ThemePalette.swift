// Every theme colour the app draws with, edited by hand.

/// Every theme-dependent colour and shadow, light and dark. Tokens that follow the
/// accent colour live in `AccentPalette`.
public struct ThemePalette: Equatable, Sendable {
    /// `--bg-active-inactive`
    public let bgActiveInactive: RGBA

    /// `--bg-base`
    public let bgBase: RGBA

    /// `--bg-elevated`
    public let bgElevated: RGBA

    /// `--bg-hover`
    public let bgHover: RGBA

    /// `--bg-input`
    public let bgInput: RGBA

    /// `--bg-surface`
    public let bgSurface: RGBA

    /// `--border`
    public let border: RGBA

    /// `--border-active`
    public let borderActive: RGBA

    /// `--border-light`
    public let borderLight: RGBA

    /// `--check-border`
    public let checkBorder: RGBA

    /// `--check-off-bg`
    public let checkOffBg: RGBA

    /// `--context-menu-bg`
    public let contextMenuBg: RGBA

    /// `--context-menu-border`
    public let contextMenuBorder: RGBA

    /// `--context-menu-destructive`
    public let contextMenuDestructive: RGBA

    /// `--context-menu-separator`
    public let contextMenuSeparator: RGBA

    /// `--context-menu-shadow`
    public let contextMenuShadow: [ShadowLayer]

    /// `--context-menu-shortcut`
    public let contextMenuShortcut: RGBA

    /// `--context-menu-text`
    public let contextMenuText: RGBA

    /// `--danger`
    public let danger: RGBA

    /// `--danger-text`
    public let dangerText: RGBA

    /// `--dropdown-bg`
    public let dropdownBg: RGBA

    /// `--elevation-dialog`
    public let elevationDialog: [ShadowLayer]

    /// `--field-bg`
    public let fieldBg: RGBA

    /// `--field-edge`
    public let fieldEdge: [ShadowLayer]

    /// `--get-info-close-icon`
    public let getInfoCloseIcon: RGBA

    /// `--get-info-close-icon-hover`
    public let getInfoCloseIconHover: RGBA

    /// `--get-info-meta-value`
    public let getInfoMetaValue: RGBA

    /// `--get-info-meta-value-muted`
    public let getInfoMetaValueMuted: RGBA

    /// `--icon-neutral`
    public let iconNeutral: RGBA

    /// `--neutral-ink`
    public let neutralInk: RGBA

    /// `--push-button-bezel`
    public let pushButtonBezel: [ShadowLayer]

    /// `--push-button-bg`
    public let pushButtonBg: RGBA

    /// `--push-button-pressed`
    public let pushButtonPressed: Double

    /// `--scrim`
    public let scrim: RGBA

    /// `--segmented-selected-text`
    public let segmentedSelectedText: RGBA

    /// `--settings-card-bg`
    public let settingsCardBg: RGBA

    /// `--settings-card-border`
    public let settingsCardBorder: RGBA

    /// `--settings-keycap`
    public let settingsKeycap: RGBA

    /// `--settings-label-secondary`
    public let settingsLabelSecondary: RGBA

    /// `--settings-page-bg`
    public let settingsPageBg: RGBA

    /// `--settings-separator`
    public let settingsSeparator: RGBA

    /// `--settings-sidebar-edge`
    public let settingsSidebarEdge: RGBA

    /// `--settings-sidebar-selection`
    public let settingsSidebarSelection: RGBA

    /// `--shadow-lg`
    public let shadowLg: [ShadowLayer]

    /// `--sidebar-bg`
    public let sidebarBg: RGBA

    /// `--text-dim`
    public let textDim: RGBA

    /// `--text-placeholder`
    public let textPlaceholder: RGBA

    /// `--text-primary`
    public let textPrimary: RGBA

    /// `--text-secondary`
    public let textSecondary: RGBA

    /// `--text-tertiary`
    public let textTertiary: RGBA

    /// `--toolbar-bg`
    public let toolbarBg: RGBA

    /// `--toolbar-toggle-icon-active`
    public let toolbarToggleIconActive: RGBA

    /// `--warning-glyph-fill`
    public let warningGlyphFill: RGBA

    /// `--warning-glyph-mark`
    public let warningGlyphMark: RGBA

    /// `--warning-glyph-stroke`
    public let warningGlyphStroke: RGBA

    public static let light = ThemePalette(
        bgActiveInactive: RGBA(r: 220, g: 220, b: 225),
        bgBase: RGBA(r: 255, g: 255, b: 255),
        bgElevated: RGBA(r: 255, g: 255, b: 255),
        bgHover: RGBA(r: 29, g: 29, b: 31, alpha: 0.05),
        bgInput: RGBA(r: 0, g: 0, b: 0, alpha: 0.04),
        bgSurface: RGBA(r: 236, g: 236, b: 240),
        border: RGBA(r: 220, g: 220, b: 225),
        borderActive: RGBA(r: 0, g: 0, b: 0, alpha: 0.12),
        borderLight: RGBA(r: 0, g: 0, b: 0, alpha: 0.07),
        checkBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0.25),
        checkOffBg: RGBA(r: 255, g: 255, b: 255),
        contextMenuBg: RGBA(r: 246, g: 246, b: 248),
        contextMenuBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0.16),
        contextMenuDestructive: RGBA(r: 224, g: 56, b: 62),
        contextMenuSeparator: RGBA(r: 0, g: 0, b: 0, alpha: 0.1),
        contextMenuShadow: [
            ShadowLayer(x: 0, y: 8, blur: 32, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.12)),
            ShadowLayer(x: 0, y: 2, blur: 8, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.06)),
        ],
        contextMenuShortcut: RGBA(r: 137, g: 137, b: 141),
        contextMenuText: RGBA(r: 29, g: 29, b: 31),
        danger: RGBA(r: 180, g: 35, b: 24),
        dangerText: RGBA(r: 180, g: 35, b: 24),
        dropdownBg: RGBA(r: 246, g: 246, b: 248),
        elevationDialog: [
            ShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.12)),
            ShadowLayer(x: 0, y: 20, blur: 50, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.2)),
            ShadowLayer(x: 0, y: 2, blur: 8, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.06)),
        ],
        fieldBg: RGBA(r: 0, g: 0, b: 0, alpha: 0.04),
        fieldEdge: [
            ShadowLayer(inset: true, x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.12))
        ],
        getInfoCloseIcon: RGBA(r: 176, g: 176, b: 181),
        getInfoCloseIconHover: RGBA(r: 74, g: 74, b: 80),
        getInfoMetaValue: RGBA(r: 29, g: 29, b: 31),
        getInfoMetaValueMuted: RGBA(r: 161, g: 161, b: 166),
        iconNeutral: RGBA(r: 110, g: 110, b: 115),
        neutralInk: RGBA(r: 0, g: 0, b: 0),
        pushButtonBezel: [
            ShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.14)),
            ShadowLayer(x: 0, y: 0.5, blur: 1.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.1)),
        ],
        pushButtonBg: RGBA(r: 255, g: 255, b: 255),
        pushButtonPressed: 0.94,
        scrim: RGBA(r: 0, g: 0, b: 0, alpha: 0.12),
        segmentedSelectedText: RGBA(r: 29, g: 29, b: 31),
        settingsCardBg: RGBA(r: 0, g: 0, b: 0, alpha: 0.028),
        settingsCardBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0.055),
        settingsKeycap: RGBA(r: 0, g: 0, b: 0, alpha: 0.055),
        settingsLabelSecondary: RGBA(r: 0, g: 0, b: 0, alpha: 0.5),
        settingsPageBg: RGBA(r: 255, g: 255, b: 255),
        settingsSeparator: RGBA(r: 0, g: 0, b: 0, alpha: 0.07),
        settingsSidebarEdge: RGBA(r: 0, g: 0, b: 0, alpha: 0.06),
        settingsSidebarSelection: RGBA(r: 0, g: 0, b: 0, alpha: 0.085),
        shadowLg: [ShadowLayer(x: 0, y: 12, blur: 32, color: RGBA(r: 30, g: 32, b: 48, alpha: 0.18))],
        sidebarBg: RGBA(r: 236, g: 236, b: 240),
        textDim: RGBA(r: 161, g: 161, b: 166),
        textPlaceholder: RGBA(r: 0, g: 0, b: 0, alpha: 0.26),
        textPrimary: RGBA(r: 29, g: 29, b: 31),
        textSecondary: RGBA(r: 0, g: 0, b: 0, alpha: 0.5),
        textTertiary: RGBA(r: 0, g: 0, b: 0, alpha: 0.26),
        toolbarBg: RGBA(r: 251, g: 251, b: 253),
        toolbarToggleIconActive: RGBA(r: 29, g: 29, b: 31),
        warningGlyphFill: RGBA(r: 255, g: 204, b: 0),
        warningGlyphMark: RGBA(r: 29, g: 29, b: 31),
        warningGlyphStroke: RGBA(r: 163, g: 123, b: 0)
    )

    public static let dark = ThemePalette(
        bgActiveInactive: RGBA(r: 42, g: 45, b: 54),
        bgBase: RGBA(r: 30, g: 30, b: 32),
        bgElevated: RGBA(r: 42, g: 42, b: 45),
        bgHover: RGBA(r: 242, g: 242, b: 245, alpha: 0.05),
        bgInput: RGBA(r: 51, g: 54, b: 63),
        bgSurface: RGBA(r: 41, g: 41, b: 44),
        border: RGBA(r: 56, g: 56, b: 59),
        borderActive: RGBA(r: 255, g: 255, b: 255, alpha: 0.1),
        borderLight: RGBA(r: 255, g: 255, b: 255, alpha: 0.07),
        checkBorder: RGBA(r: 255, g: 255, b: 255, alpha: 0.25),
        checkOffBg: RGBA(r: 255, g: 255, b: 255, alpha: 0.06),
        contextMenuBg: RGBA(r: 44, g: 44, b: 48),
        contextMenuBorder: RGBA(r: 255, g: 255, b: 255, alpha: 0.12),
        contextMenuDestructive: RGBA(r: 255, g: 69, b: 58),
        contextMenuSeparator: RGBA(r: 255, g: 255, b: 255, alpha: 0.1),
        contextMenuShadow: [
            ShadowLayer(x: 0, y: 8, blur: 40, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.45)),
            ShadowLayer(x: 0, y: 2, blur: 8, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.25)),
        ],
        contextMenuShortcut: RGBA(r: 121, g: 121, b: 126),
        contextMenuText: RGBA(r: 242, g: 242, b: 245),
        danger: RGBA(r: 240, g: 128, b: 128),
        dangerText: RGBA(r: 240, g: 128, b: 128),
        dropdownBg: RGBA(r: 44, g: 44, b: 48),
        elevationDialog: [
            ShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 255, g: 255, b: 255, alpha: 0.14)),
            ShadowLayer(x: 0, y: 20, blur: 50, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.5)),
        ],
        fieldBg: RGBA(r: 51, g: 54, b: 63),
        fieldEdge: [
            ShadowLayer(inset: true, x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 255, g: 255, b: 255, alpha: 0.1))
        ],
        getInfoCloseIcon: RGBA(r: 95, g: 95, b: 100),
        getInfoCloseIconHover: RGBA(r: 199, g: 199, b: 204),
        getInfoMetaValue: RGBA(r: 242, g: 242, b: 245),
        getInfoMetaValueMuted: RGBA(r: 110, g: 110, b: 115),
        iconNeutral: RGBA(r: 161, g: 161, b: 166),
        neutralInk: RGBA(r: 255, g: 255, b: 255),
        pushButtonBezel: [
            ShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 255, g: 255, b: 255, alpha: 0.04)),
            ShadowLayer(x: 0, y: 0.5, blur: 1.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.1)),
        ],
        pushButtonBg: RGBA(r: 242, g: 242, b: 245, alpha: 0.17),
        pushButtonPressed: 1.25,
        scrim: RGBA(r: 0, g: 0, b: 0, alpha: 0.32),
        segmentedSelectedText: RGBA(r: 242, g: 242, b: 245),
        settingsCardBg: RGBA(r: 255, g: 255, b: 255, alpha: 0.035),
        settingsCardBorder: RGBA(r: 255, g: 255, b: 255, alpha: 0.06),
        settingsKeycap: RGBA(r: 255, g: 255, b: 255, alpha: 0.08),
        settingsLabelSecondary: RGBA(r: 255, g: 255, b: 255, alpha: 0.55),
        settingsPageBg: RGBA(r: 30, g: 30, b: 32),
        settingsSeparator: RGBA(r: 255, g: 255, b: 255, alpha: 0.07),
        settingsSidebarEdge: RGBA(r: 0, g: 0, b: 0, alpha: 0.35),
        settingsSidebarSelection: RGBA(r: 255, g: 255, b: 255, alpha: 0.1),
        shadowLg: [ShadowLayer(x: 0, y: 18, blur: 44, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.34))],
        sidebarBg: RGBA(r: 41, g: 41, b: 44),
        textDim: RGBA(r: 110, g: 110, b: 115),
        textPlaceholder: RGBA(r: 255, g: 255, b: 255, alpha: 0.25),
        textPrimary: RGBA(r: 242, g: 242, b: 245),
        textSecondary: RGBA(r: 255, g: 255, b: 255, alpha: 0.55),
        textTertiary: RGBA(r: 255, g: 255, b: 255, alpha: 0.25),
        toolbarBg: RGBA(r: 37, g: 37, b: 40),
        toolbarToggleIconActive: RGBA(r: 242, g: 242, b: 245),
        warningGlyphFill: RGBA(r: 255, g: 214, b: 10),
        warningGlyphMark: RGBA(r: 29, g: 29, b: 31),
        warningGlyphStroke: RGBA(r: 179, g: 143, b: 0)
    )

    public static func palette(for appearance: ThemeAppearance) -> ThemePalette {
        switch appearance {
        case .light: light
        case .dark: dark
        }
    }
}
