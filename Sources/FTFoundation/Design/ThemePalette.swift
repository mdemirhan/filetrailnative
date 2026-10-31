// Generated once from Tests/Golden/css-tokens.json; now edited by hand, with CSSTokenTests checking it against that file.
// Port of the light and dark blocks of apps/desktop/src/renderer/styles.css

/// Every theme-dependent colour and shadow of the reference stylesheet. Tokens that follow the
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

    /// `--bg-panel`
    public let bgPanel: RGBA

    /// `--bg-surface`
    public let bgSurface: RGBA

    /// `--border`
    public let border: RGBA

    /// `--border-active`
    public let borderActive: RGBA

    /// `--border-light`
    public let borderLight: RGBA

    /// `--border-strong`
    public let borderStrong: RGBA

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

    /// `--context-menu-disabled`
    public let contextMenuDisabled: RGBA

    /// `--context-menu-icon`
    public let contextMenuIcon: RGBA

    /// `--context-menu-separator`
    public let contextMenuSeparator: RGBA

    /// `--context-menu-shadow`
    public let contextMenuShadow: [ShadowLayer]

    /// `--context-menu-shortcut`
    public let contextMenuShortcut: RGBA

    /// `--context-menu-submenu-arrow`
    public let contextMenuSubmenuArrow: RGBA

    /// `--context-menu-text`
    public let contextMenuText: RGBA

    /// `--danger`
    public let danger: RGBA

    /// `--danger-text`
    public let dangerText: RGBA

    /// `--dialog-edge`
    public let dialogEdge: RGBA

    /// `--dropdown-bg`
    public let dropdownBg: RGBA

    /// `--elevation-dialog`
    public let elevationDialog: [ShadowLayer]

    /// `--field-bg`
    public let fieldBg: RGBA

    /// `--field-edge`
    public let fieldEdge: [ShadowLayer]

    /// `--get-info-action-bg`
    public let getInfoActionBg: RGBA

    /// `--get-info-action-icon`
    public let getInfoActionIcon: RGBA

    /// `--get-info-action-text`
    public let getInfoActionText: RGBA

    /// `--get-info-close-icon`
    public let getInfoCloseIcon: RGBA

    /// `--get-info-close-icon-hover`
    public let getInfoCloseIconHover: RGBA

    /// `--get-info-header-text`
    public let getInfoHeaderText: RGBA

    /// `--get-info-hero-name`
    public let getInfoHeroName: RGBA

    /// `--get-info-meta-label`
    public let getInfoMetaLabel: RGBA

    /// `--get-info-meta-separator`
    public let getInfoMetaSeparator: RGBA

    /// `--get-info-meta-value`
    public let getInfoMetaValue: RGBA

    /// `--get-info-meta-value-muted`
    public let getInfoMetaValueMuted: RGBA

    /// `--get-info-panel-bg`
    public let getInfoPanelBg: RGBA

    /// `--get-info-panel-border`
    public let getInfoPanelBorder: RGBA

    /// `--help-muted`
    public let helpMuted: RGBA

    /// `--icon-neutral`
    public let iconNeutral: RGBA

    /// `--neutral-ink`
    public let neutralInk: RGBA

    /// `--push-button-bezel`
    public let pushButtonBezel: [ShadowLayer]

    /// `--push-button-bg`
    public let pushButtonBg: RGBA

    /// `--push-button-edge`
    public let pushButtonEdge: RGBA

    /// `--push-button-pressed`
    public let pushButtonPressed: Double

    /// `--scrim`
    public let scrim: RGBA

    /// `--scroll-thumb`
    public let scrollThumb: RGBA

    /// `--scroll-thumb-hover`
    public let scrollThumbHover: RGBA

    /// `--search-border`
    public let searchBorder: RGBA

    /// `--search-icon`
    public let searchIcon: RGBA

    /// `--search-shadow`
    public let searchShadow: [ShadowLayer]

    /// `--search-surface`
    public let searchSurface: RGBA

    /// `--search-text`
    public let searchText: RGBA

    /// `--segmented-selected-bg`
    public let segmentedSelectedBg: RGBA

    /// `--segmented-selected-shadow`
    public let segmentedSelectedShadow: [ShadowLayer]

    /// `--segmented-selected-text`
    public let segmentedSelectedText: RGBA

    /// `--segmented-track-bg`
    public let segmentedTrackBg: RGBA

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

    /// `--settings-switch-off`
    public let settingsSwitchOff: RGBA

    /// `--shadow-lg`
    public let shadowLg: [ShadowLayer]

    /// `--shadow-sm`
    public let shadowSm: [ShadowLayer]

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

    /// `--toolbar-border`
    public let toolbarBorder: RGBA

    /// `--toolbar-nav-icon`
    public let toolbarNavIcon: RGBA

    /// `--toolbar-nav-icon-active`
    public let toolbarNavIconActive: RGBA

    /// `--toolbar-toggle-active-bg`
    public let toolbarToggleActiveBg: RGBA

    /// `--toolbar-toggle-bg`
    public let toolbarToggleBg: RGBA

    /// `--toolbar-toggle-icon-active`
    public let toolbarToggleIconActive: RGBA

    /// `--toolbar-toggle-on-bg`
    public let toolbarToggleOnBg: RGBA

    /// `--toolbar-toggle-on-hover-bg`
    public let toolbarToggleOnHoverBg: RGBA

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
        bgPanel: RGBA(r: 255, g: 255, b: 255),
        bgSurface: RGBA(r: 236, g: 236, b: 240),
        border: RGBA(r: 220, g: 220, b: 225),
        borderActive: RGBA(r: 0, g: 0, b: 0, alpha: 0.12),
        borderLight: RGBA(r: 0, g: 0, b: 0, alpha: 0.07),
        borderStrong: RGBA(r: 0, g: 0, b: 0, alpha: 0.16),
        checkBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0.25),
        checkOffBg: RGBA(r: 255, g: 255, b: 255),
        contextMenuBg: RGBA(r: 246, g: 246, b: 248),
        contextMenuBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0.16),
        contextMenuDestructive: RGBA(r: 224, g: 56, b: 62),
        contextMenuDisabled: RGBA(r: 167, g: 167, b: 171),
        contextMenuIcon: RGBA(r: 110, g: 110, b: 115),
        contextMenuSeparator: RGBA(r: 0, g: 0, b: 0, alpha: 0.1),
        contextMenuShadow: [
            ShadowLayer(x: 0, y: 8, blur: 32, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.12)),
            ShadowLayer(x: 0, y: 2, blur: 8, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.06)),
        ],
        contextMenuShortcut: RGBA(r: 137, g: 137, b: 141),
        contextMenuSubmenuArrow: RGBA(r: 137, g: 137, b: 141),
        contextMenuText: RGBA(r: 29, g: 29, b: 31),
        danger: RGBA(r: 180, g: 35, b: 24),
        dangerText: RGBA(r: 180, g: 35, b: 24),
        dialogEdge: RGBA(r: 0, g: 0, b: 0, alpha: 0.12),
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
        getInfoActionBg: RGBA(r: 0, g: 0, b: 0, alpha: 0.03),
        getInfoActionIcon: RGBA(r: 100, g: 103, b: 117),
        getInfoActionText: RGBA(r: 94, g: 97, b: 112),
        getInfoCloseIcon: RGBA(r: 176, g: 176, b: 181),
        getInfoCloseIconHover: RGBA(r: 74, g: 74, b: 80),
        getInfoHeaderText: RGBA(r: 161, g: 161, b: 166),
        getInfoHeroName: RGBA(r: 29, g: 29, b: 31),
        getInfoMetaLabel: RGBA(r: 134, g: 134, b: 139),
        getInfoMetaSeparator: RGBA(r: 0, g: 0, b: 0, alpha: 0.07),
        getInfoMetaValue: RGBA(r: 29, g: 29, b: 31),
        getInfoMetaValueMuted: RGBA(r: 161, g: 161, b: 166),
        getInfoPanelBg: RGBA(r: 255, g: 255, b: 255),
        getInfoPanelBorder: RGBA(r: 220, g: 220, b: 225),
        helpMuted: RGBA(r: 134, g: 134, b: 139),
        iconNeutral: RGBA(r: 110, g: 110, b: 115),
        neutralInk: RGBA(r: 0, g: 0, b: 0),
        pushButtonBezel: [
            ShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.14)),
            ShadowLayer(x: 0, y: 0.5, blur: 1.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.1)),
        ],
        pushButtonBg: RGBA(r: 255, g: 255, b: 255),
        pushButtonEdge: RGBA(r: 0, g: 0, b: 0, alpha: 0.14),
        pushButtonPressed: 0.94,
        scrim: RGBA(r: 0, g: 0, b: 0, alpha: 0.12),
        scrollThumb: RGBA(r: 110, g: 110, b: 115, alpha: 0.22),
        scrollThumbHover: RGBA(r: 110, g: 110, b: 115, alpha: 0.34),
        searchBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0),
        searchIcon: RGBA(r: 134, g: 134, b: 139),
        searchShadow: [],
        searchSurface: RGBA(r: 236, g: 236, b: 240),
        searchText: RGBA(r: 74, g: 74, b: 80),
        segmentedSelectedBg: RGBA(r: 255, g: 255, b: 255),
        segmentedSelectedShadow: [ShadowLayer(x: 0, y: 0.5, blur: 1.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.2))],
        segmentedSelectedText: RGBA(r: 29, g: 29, b: 31),
        segmentedTrackBg: RGBA(r: 236, g: 236, b: 240),
        settingsCardBg: RGBA(r: 0, g: 0, b: 0, alpha: 0.028),
        settingsCardBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0.055),
        settingsKeycap: RGBA(r: 0, g: 0, b: 0, alpha: 0.055),
        settingsLabelSecondary: RGBA(r: 0, g: 0, b: 0, alpha: 0.5),
        settingsPageBg: RGBA(r: 255, g: 255, b: 255),
        settingsSeparator: RGBA(r: 0, g: 0, b: 0, alpha: 0.07),
        settingsSidebarEdge: RGBA(r: 0, g: 0, b: 0, alpha: 0.06),
        settingsSidebarSelection: RGBA(r: 0, g: 0, b: 0, alpha: 0.085),
        settingsSwitchOff: RGBA(r: 0, g: 0, b: 0, alpha: 0.09),
        shadowLg: [ShadowLayer(x: 0, y: 12, blur: 32, color: RGBA(r: 30, g: 32, b: 48, alpha: 0.18))],
        shadowSm: [ShadowLayer(x: 0, y: 1, blur: 2, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.04))],
        sidebarBg: RGBA(r: 236, g: 236, b: 240),
        textDim: RGBA(r: 161, g: 161, b: 166),
        textPlaceholder: RGBA(r: 0, g: 0, b: 0, alpha: 0.26),
        textPrimary: RGBA(r: 29, g: 29, b: 31),
        textSecondary: RGBA(r: 0, g: 0, b: 0, alpha: 0.5),
        textTertiary: RGBA(r: 0, g: 0, b: 0, alpha: 0.26),
        toolbarBg: RGBA(r: 251, g: 251, b: 253),
        toolbarBorder: RGBA(r: 227, g: 227, b: 232),
        toolbarNavIcon: RGBA(r: 199, g: 199, b: 204),
        toolbarNavIconActive: RGBA(r: 110, g: 110, b: 115),
        toolbarToggleActiveBg: RGBA(r: 255, g: 255, b: 255),
        toolbarToggleBg: RGBA(r: 236, g: 236, b: 240),
        toolbarToggleIconActive: RGBA(r: 29, g: 29, b: 31),
        toolbarToggleOnBg: RGBA(r: 29, g: 29, b: 31, alpha: 0.16),
        toolbarToggleOnHoverBg: RGBA(r: 29, g: 29, b: 31, alpha: 0.21),
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
        bgPanel: RGBA(r: 30, g: 30, b: 32),
        bgSurface: RGBA(r: 41, g: 41, b: 44),
        border: RGBA(r: 56, g: 56, b: 59),
        borderActive: RGBA(r: 255, g: 255, b: 255, alpha: 0.1),
        borderLight: RGBA(r: 255, g: 255, b: 255, alpha: 0.07),
        borderStrong: RGBA(r: 255, g: 255, b: 255, alpha: 0.16),
        checkBorder: RGBA(r: 255, g: 255, b: 255, alpha: 0.25),
        checkOffBg: RGBA(r: 255, g: 255, b: 255, alpha: 0.06),
        contextMenuBg: RGBA(r: 44, g: 44, b: 48),
        contextMenuBorder: RGBA(r: 255, g: 255, b: 255, alpha: 0.12),
        contextMenuDestructive: RGBA(r: 255, g: 69, b: 58),
        contextMenuDisabled: RGBA(r: 96, g: 96, b: 98),
        contextMenuIcon: RGBA(r: 161, g: 161, b: 166),
        contextMenuSeparator: RGBA(r: 255, g: 255, b: 255, alpha: 0.1),
        contextMenuShadow: [
            ShadowLayer(x: 0, y: 8, blur: 40, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.45)),
            ShadowLayer(x: 0, y: 2, blur: 8, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.25)),
        ],
        contextMenuShortcut: RGBA(r: 121, g: 121, b: 126),
        contextMenuSubmenuArrow: RGBA(r: 121, g: 121, b: 126),
        contextMenuText: RGBA(r: 242, g: 242, b: 245),
        danger: RGBA(r: 240, g: 128, b: 128),
        dangerText: RGBA(r: 240, g: 128, b: 128),
        dialogEdge: RGBA(r: 255, g: 255, b: 255, alpha: 0.14),
        dropdownBg: RGBA(r: 44, g: 44, b: 48),
        elevationDialog: [
            ShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 255, g: 255, b: 255, alpha: 0.14)),
            ShadowLayer(x: 0, y: 20, blur: 50, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.5)),
        ],
        fieldBg: RGBA(r: 51, g: 54, b: 63),
        fieldEdge: [
            ShadowLayer(inset: true, x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 255, g: 255, b: 255, alpha: 0.1))
        ],
        getInfoActionBg: RGBA(r: 255, g: 255, b: 255, alpha: 0.03),
        getInfoActionIcon: RGBA(r: 143, g: 148, b: 163),
        getInfoActionText: RGBA(r: 180, g: 185, b: 199),
        getInfoCloseIcon: RGBA(r: 95, g: 95, b: 100),
        getInfoCloseIconHover: RGBA(r: 199, g: 199, b: 204),
        getInfoHeaderText: RGBA(r: 110, g: 110, b: 115),
        getInfoHeroName: RGBA(r: 242, g: 242, b: 245),
        getInfoMetaLabel: RGBA(r: 152, g: 152, b: 157),
        getInfoMetaSeparator: RGBA(r: 255, g: 255, b: 255, alpha: 0.07),
        getInfoMetaValue: RGBA(r: 242, g: 242, b: 245),
        getInfoMetaValueMuted: RGBA(r: 110, g: 110, b: 115),
        getInfoPanelBg: RGBA(r: 30, g: 30, b: 32),
        getInfoPanelBorder: RGBA(r: 56, g: 56, b: 59),
        helpMuted: RGBA(r: 152, g: 152, b: 157),
        iconNeutral: RGBA(r: 161, g: 161, b: 166),
        neutralInk: RGBA(r: 255, g: 255, b: 255),
        pushButtonBezel: [
            ShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: RGBA(r: 255, g: 255, b: 255, alpha: 0.04)),
            ShadowLayer(x: 0, y: 0.5, blur: 1.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.1)),
        ],
        pushButtonBg: RGBA(r: 242, g: 242, b: 245, alpha: 0.17),
        pushButtonEdge: RGBA(r: 255, g: 255, b: 255, alpha: 0.04),
        pushButtonPressed: 1.25,
        scrim: RGBA(r: 0, g: 0, b: 0, alpha: 0.32),
        scrollThumb: RGBA(r: 161, g: 161, b: 166, alpha: 0.3),
        scrollThumbHover: RGBA(r: 161, g: 161, b: 166, alpha: 0.42),
        searchBorder: RGBA(r: 0, g: 0, b: 0, alpha: 0),
        searchIcon: RGBA(r: 152, g: 152, b: 157),
        searchShadow: [],
        searchSurface: RGBA(r: 50, g: 50, b: 53),
        searchText: RGBA(r: 199, g: 199, b: 204),
        segmentedSelectedBg: RGBA(r: 90, g: 90, b: 94),
        segmentedSelectedShadow: [ShadowLayer(x: 0, y: 0.5, blur: 1.5, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.2))],
        segmentedSelectedText: RGBA(r: 242, g: 242, b: 245),
        segmentedTrackBg: RGBA(r: 50, g: 50, b: 53),
        settingsCardBg: RGBA(r: 255, g: 255, b: 255, alpha: 0.035),
        settingsCardBorder: RGBA(r: 255, g: 255, b: 255, alpha: 0.06),
        settingsKeycap: RGBA(r: 255, g: 255, b: 255, alpha: 0.08),
        settingsLabelSecondary: RGBA(r: 255, g: 255, b: 255, alpha: 0.55),
        settingsPageBg: RGBA(r: 30, g: 30, b: 32),
        settingsSeparator: RGBA(r: 255, g: 255, b: 255, alpha: 0.07),
        settingsSidebarEdge: RGBA(r: 0, g: 0, b: 0, alpha: 0.35),
        settingsSidebarSelection: RGBA(r: 255, g: 255, b: 255, alpha: 0.1),
        settingsSwitchOff: RGBA(r: 255, g: 255, b: 255, alpha: 0.14),
        shadowLg: [ShadowLayer(x: 0, y: 18, blur: 44, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.34))],
        shadowSm: [ShadowLayer(x: 0, y: 1, blur: 2, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.2))],
        sidebarBg: RGBA(r: 41, g: 41, b: 44),
        textDim: RGBA(r: 110, g: 110, b: 115),
        textPlaceholder: RGBA(r: 255, g: 255, b: 255, alpha: 0.25),
        textPrimary: RGBA(r: 242, g: 242, b: 245),
        textSecondary: RGBA(r: 255, g: 255, b: 255, alpha: 0.55),
        textTertiary: RGBA(r: 255, g: 255, b: 255, alpha: 0.25),
        toolbarBg: RGBA(r: 37, g: 37, b: 40),
        toolbarBorder: RGBA(r: 56, g: 56, b: 59),
        toolbarNavIcon: RGBA(r: 95, g: 95, b: 100),
        toolbarNavIconActive: RGBA(r: 161, g: 161, b: 166),
        toolbarToggleActiveBg: RGBA(r: 90, g: 90, b: 94),
        toolbarToggleBg: RGBA(r: 50, g: 50, b: 53),
        toolbarToggleIconActive: RGBA(r: 242, g: 242, b: 245),
        toolbarToggleOnBg: RGBA(r: 242, g: 242, b: 245, alpha: 0.16),
        toolbarToggleOnHoverBg: RGBA(r: 242, g: 242, b: 245, alpha: 0.21),
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
