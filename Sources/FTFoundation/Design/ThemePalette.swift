// Every theme colour the app draws with, light and dark.

/// Every theme-dependent colour and shadow, light and dark. Tokens that follow the
/// accent colour live in `AccentPalette`.
public struct ThemePalette: Equatable, Sendable {
    /// A selected row's fill while its list doesn't have the keyboard (the file list, Help's and Settings' lists).
    public let bgActiveInactive: RGBA

    /// The background of the content: Help, About, Acknowledgements, the rename field.
    public let bgBase: RGBA

    /// Cards above the window and what sits on them: alerts, sheets, Go To, the list filter's pill.
    public let bgElevated: RGBA

    /// A row or button under the pointer.
    public let bgHover: RGBA

    /// Code in Help, and the box of licence texts in Acknowledgements.
    public let bgInput: RGBA

    /// The Rename sheet's preview.
    public let bgSurface: RGBA

    /// Lines between panes, bars and columns, and the edges of boxes.
    public let border: RGBA

    /// The edge of a field: the rename field, the search fields, the Rename sheet's preview.
    public let borderActive: RGBA

    /// Faint lines: under headers, between a sheet's parts, in the Info panel.
    public let borderLight: RGBA

    /// The edge of a checkbox that is off.
    public let checkBorder: RGBA

    /// The fill of a checkbox that is off.
    public let checkOffBg: RGBA

    /// The sign in a notification's icon, and the fill behind a refused name's message in the rename field.
    public let contextMenuBg: RGBA

    /// A notification's edge.
    public let contextMenuBorder: RGBA

    /// A context menu item that deletes (Delete Immediately).
    public let contextMenuDestructive: RGBA

    /// The clipboard menu's separators.
    public let contextMenuSeparator: RGBA

    /// A notification's shadow.
    public let contextMenuShadow: [ShadowLayer]

    /// The clipboard menu's shortcuts.
    public let contextMenuShortcut: RGBA

    /// The clipboard menu's text.
    public let contextMenuText: RGBA

    /// Errors and destructive choices: a refused name, Replace, an item that failed.
    public let danger: RGBA

    /// An error's text under a field or in a list.
    public let dangerText: RGBA

    /// The path bar's list of suggestions.
    public let dropdownBg: RGBA

    /// The edge and the drop shadows of alerts, sheets and Go To.
    public let elevationDialog: [ShadowLayer]

    /// The fill of a text field.
    public let fieldBg: RGBA

    /// The thin edge of a text field.
    public let fieldEdge: [ShadowLayer]

    /// The Info panel's close button.
    public let getInfoCloseIcon: RGBA

    /// The Info panel's close button under the pointer.
    public let getInfoCloseIconHover: RGBA

    /// A value in the Info panel's rows.
    public let getInfoMetaValue: RGBA

    /// A value the Info panel doesn't have (yet).
    public let getInfoMetaValueMuted: RGBA

    /// An icon in Settings' choice of favorite icons, not selected.
    public let iconNeutral: RGBA

    /// The ink of stripes and bars, drawn at a low alpha: the List's odd rows, the paste review's bars.
    public let neutralInk: RGBA

    /// The edge and shadow of a push button.
    public let pushButtonBezel: [ShadowLayer]

    /// A push button's fill.
    public let pushButtonBg: RGBA

    /// How bright a pressed push button stays: black at one minus this is drawn over it.
    public let pushButtonPressed: Double

    /// The dimming over a window behind an alert or a sheet.
    public let scrim: RGBA

    /// The selected segment's label.
    public let segmentedSelectedText: RGBA

    /// The fill of Settings' grouped boxes.
    public let settingsCardBg: RGBA

    /// The edge of Settings' grouped boxes.
    public let settingsCardBorder: RGBA

    /// A key's cap in Settings' Shortcuts.
    public let settingsKeycap: RGBA

    /// Secondary text in Settings.
    public let settingsLabelSecondary: RGBA

    /// The background of Settings' pages.
    public let settingsPageBg: RGBA

    /// Lines between rows in Settings.
    public let settingsSeparator: RGBA

    /// The line between Settings' sidebar and its page.
    public let settingsSidebarEdge: RGBA

    /// The selected section in Settings' sidebar.
    public let settingsSidebarSelection: RGBA

    /// The shadow of the path bar's list of suggestions.
    public let shadowLg: [ShadowLayer]

    /// The sidebar of Help and of Settings.
    public let sidebarBg: RGBA

    /// The faintest text: the Info Row's separating dot, a folder size's refresh button.
    public let textDim: RGBA

    /// Placeholder text in Go To's field.
    public let textPlaceholder: RGBA

    /// Text, and icons drawn as text.
    public let textPrimary: RGBA

    /// Secondary text: labels, hints, icons that are not selected.
    public let textSecondary: RGBA

    /// Text fainter than secondary: an empty or fixed shortcut, a hint in the Rename sheet's preview.
    public let textTertiary: RGBA

    /// Acknowledgements' bar.
    public let toolbarBg: RGBA

    /// A search option's toggle while it is on.
    public let toolbarToggleIconActive: RGBA

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
        toolbarToggleIconActive: RGBA(r: 29, g: 29, b: 31)
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
        toolbarToggleIconActive: RGBA(r: 242, g: 242, b: 245)
    )

    public static func palette(for appearance: ThemeAppearance) -> ThemePalette {
        switch appearance {
        case .light: light
        case .dark: dark
        }
    }
}
