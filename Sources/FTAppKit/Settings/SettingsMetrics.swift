// Port of the Settings rules of apps/desktop/src/renderer/styles.css (3701-3810, 4884-5043, 5245-6211) and the window of
// openSettingsWindow in apps/desktop/src/main/main.ts
import AppKit
import FTFoundation

/// The sizes of the Settings window, each from the stylesheet line that sets it. Root tokens (type scale, radii,
/// control heights, colors) come from `DesignTokens`.
enum SettingsMetrics {
    // MARK: Window (main.ts:488-498)

    static let windowSize = NSSize(width: 720, height: 540)
    static let windowMinSize = NSSize(width: 680, height: 420)
    static let trafficLights = NSPoint(x: 14, y: 16)

    // MARK: Sidebar (styles.css:4897-4983)

    /// `--settings-sidebar-width` (styles.css:5271).
    static var sidebarWidth: CGFloat { CGFloat(DesignTokens.settingsSidebarWidth) }
    /// `.settings-sidebar` padding 52 10 10 (:4901).
    static let sidebarPaddingTop: CGFloat = 52
    static let sidebarPaddingSide: CGFloat = 10
    /// `.settings-sidebar` gap (:4900).
    static let sidebarItemGap: CGFloat = 2
    /// `.settings-sidebar-item` height, padding 0 8, gap 8 (:4911-4914).
    static let sidebarItemHeight: CGFloat = 30
    static let sidebarItemPadding: CGFloat = 8
    static let sidebarItemGapInside: CGFloat = 8
    /// `.settings-sidebar-icon` 20 by 20, radius 5 (:4943-4946).
    static let tileSize: CGFloat = 20
    static let tileRadius: CGFloat = 5
    /// `.settings-sidebar-icon svg` 13 by 13, stroke 2.1 (:4976-4983).
    static let tileGlyphSize: CGFloat = 13
    static let tileGlyphStroke: CGFloat = 2.1
    /// The tile's inner edge and top highlight (:4948).
    static let tileEdge = RGBA(r: 0, g: 0, b: 0, alpha: 0.12)
    static let tileEdgeWidth: CGFloat = 0.5
    static let tileHighlight = RGBA(r: 255, g: 255, b: 255, alpha: 0.18)

    // MARK: Pane (styles.css:4994-5047)

    /// `.settings-pane-header` height 52, padding 0 20, gap 12 (:4996-5000).
    static let headerHeight: CGFloat = 52
    static let headerPadding: CGFloat = 20
    static let headerGap: CGFloat = 12
    /// The Shortcuts search field beside the title (:5257-5260).
    static let headerSearchWidth: CGFloat = 200
    /// `.settings-window-notice` padding 8 20, gap 12 (:5030-5037).
    static let noticePaddingVertical: CGFloat = 8
    static let noticePaddingHorizontal: CGFloat = 20
    static let noticeGap: CGFloat = 12
    /// `--danger` at 10% (:5035).
    static let noticeFillPercent = 0.10
    /// `scrollbar-gutter: stable` (:5046): the scroll bar's room is kept on every page.
    static var scrollGutter: CGFloat { CGFloat(DesignTokens.scrollbarWidth) }

    // MARK: Page (styles.css:5301-5352)

    /// `.settings-window .settings-view` padding 4 12 20 20 (:5304).
    static let pagePaddingTop: CGFloat = 4
    static let pagePaddingRight: CGFloat = 12
    static let pagePaddingBottom: CGFloat = 20
    static let pagePaddingLeft: CGFloat = 20
    /// `.settings-window .settings-page` width min(560px, 100%), centered (:3714, :5308).
    static let pageMaxWidth: CGFloat = 560
    /// `.settings-section` margin-bottom 20 (:5312).
    static let sectionGap: CGFloat = 20
    /// `.settings-section-header` min-height 22, padding 0 2 5 (:5321-5322).
    static let sectionHeaderMinHeight: CGFloat = 22
    static let sectionHeaderPaddingSide: CGFloat = 2
    static let sectionHeaderPaddingBottom: CGFloat = 5
    /// `.settings-section-note` margin 6 2 0, line-height 1.4 (:5336-5339).
    static let sectionNoteMarginTop: CGFloat = 6
    static let sectionNoteMarginSide: CGFloat = 2
    static let noteLineHeight = 1.4
    /// `.settings-section-footer` margin-top 10 (:5345).
    static let sectionFooterGap: CGFloat = 10

    // MARK: Cards and rows (styles.css:5352-5418)

    /// `.settings-card` padding 0 12, radius `--radius-menu` (:5354-5356).
    static let cardPadding: CGFloat = 12
    static var cardRadius: CGFloat { CGFloat(DesignTokens.radii.menu) }
    /// `.settings-card::after` 1 px inner edge (:5364).
    static let cardEdgeWidth: CGFloat = 1
    /// `.settings-row` gap 16, min-height 40, padding 8 0, 1 px line under (:5373-5376).
    static let rowGap: CGFloat = 16
    static let rowMinHeight: CGFloat = 40
    static let rowPadding: CGFloat = 8
    static let separatorWidth: CGFloat = 1
    /// `.settings-row-desc` margin-top 1, line-height 14 (:5393-5396).
    static let rowDescGap: CGFloat = 1
    static let rowDescLineHeight: CGFloat = 14

    // MARK: Controls (styles.css:5423-5560)

    /// `.settings-popup select` padding 0 26 0 8 (:5476-5478).
    static let popupPaddingLeading: CGFloat = 8
    static let popupPaddingTrailing: CGFloat = 26
    static var popupMinWidth: CGFloat { CGFloat(DesignTokens.settingsPopupMinWidth) }
    /// `.settings-popup-chevron` 11 by 11, 8 from the right, stroke 2.4 (:5486-5496).
    static let chevronSize: CGFloat = 11
    static let chevronInset: CGFloat = 8
    static let chevronStroke: CGFloat = 2.4
    static let chevronPath = "M8 9.5l4-4 4 4M8 14.5l4 4 4-4"
    /// `.settings-field` padding 0 8 (:5503); `.settings-number-field` 48 wide (:5508).
    static let fieldPadding: CGFloat = 8
    static let numberFieldWidth: CGFloat = 48
    /// What an editable field's cell keeps between its frame and its text on each side.
    static let fieldCellInset: CGFloat = 2
    /// The room Chromium keeps at the end of an `<input type="number">` for its stepper, shown or not: the
    /// right-aligned number ends this far before the padding.
    static let numberStepperWidth: CGFloat = 15
    /// `.settings-field-with-unit` gap 6 (:5514).
    static let unitGap: CGFloat = 6
    /// The system's mini switch, in place of `.settings-switch` (28 by 16, D-020).
    static let switchSize = NSSize(width: 36, height: 16)
    /// `.settings-checkbox input` 14 by 14, radius `--radius-xs` (:5563-5566); gap 6 (:5556).
    static let checkboxSize: CGFloat = 14
    static let checkboxGap: CGFloat = 6
    static let checkPath = "M3.5 7.2l2.3 2.3 4.7-5"
    static let checkStroke: CGFloat = 1.8

    // MARK: Appearance (styles.css:5588-5701)

    /// `.settings-appearance-picker` gap 12 (:5590); option gap 4 (:5597).
    static let appearanceGap: CGFloat = 12
    static let appearanceLabelGap: CGFloat = 4
    /// `.settings-appearance-ring` padding 2, radius 8; the selected ring 2 px (:5611-5617).
    static let appearanceRingPadding: CGFloat = 2
    static let appearanceRingRadius: CGFloat = 8
    static let appearanceRingWidth: CGFloat = 2
    /// `.settings-appearance-thumb` 56 by 36, radius 6, edge 0.5 (:5628-5634).
    static let thumbSize = NSSize(width: 56, height: 36)
    static let thumbRadius: CGFloat = 6
    static let thumbEdge = RGBA(r: 0, g: 0, b: 0, alpha: 0.25)
    /// The window in the thumbnail: a 15 wide side, bars 3 tall (radius 2) 4 apart, padding 7 5 (:5655-5681).
    static let thumbSideWidth: CGFloat = 15
    static let thumbPaddingVertical: CGFloat = 7
    static let thumbPaddingHorizontal: CGFloat = 5
    static let thumbBarHeight: CGFloat = 3
    static let thumbBarRadius: CGFloat = 2
    static let thumbBarGap: CGFloat = 4
    static let thumbBarWidths: [CGFloat] = [0.7, 0.9, 0.55]
    /// Light and dark thumbnails: side, window, bar (:5637-5650).
    static let thumbLight = (
        side: RGBA(r: 0xe4, g: 0xe4, b: 0xe9), main: RGBA(r: 255, g: 255, b: 255),
        bar: RGBA(r: 0xd4, g: 0xd4, b: 0xda)
    )
    static let thumbDark = (
        side: RGBA(r: 0x2c, g: 0x2c, b: 0x30), main: RGBA(r: 0x1e, g: 0x1e, b: 0x20),
        bar: RGBA(r: 0x3c, g: 0x3c, b: 0x41)
    )

    /// `.settings-accent-swatches` gap 7; swatches 15 across (:5694-5705).
    static let swatchGap: CGFloat = 7
    static let swatchSize: CGFloat = 15
    /// The swatch's edge, and the ring of the chosen one: the page color to 2, the accent to 3.5 (:5707-5716).
    static let swatchEdge = RGBA(r: 0, g: 0, b: 0, alpha: 0.2)
    static let swatchRingGap: CGFloat = 2
    static let swatchRingOuter: CGFloat = 3.5
    /// The custom swatch's conic gradient, from 210 degrees (:5723-5725), and its fill 3.5 in (:5727-5731).
    static let customSwatchStops: [RGBA] = [
        RGBA(r: 0xd8, g: 0x4a, b: 0x4a), RGBA(r: 0xf0, g: 0xb2, b: 0x36), RGBA(r: 0x23, g: 0xc7, b: 0xd9),
        RGBA(r: 0x95, g: 0x80, b: 0xff), RGBA(r: 0xe8, g: 0x72, b: 0x9a), RGBA(r: 0xd8, g: 0x4a, b: 0x4a),
    ]
    static let customSwatchStartDegrees: CGFloat = 210
    static let customFillInset: CGFloat = 3.5

    // MARK: Lists (styles.css:5742-5908)

    /// `.settings-list-row` gap 9, min-height 40, padding 0 12 (:5743-5747); column rows 30 (:5758).
    static let listRowGap: CGFloat = 9
    static let listRowHeight: CGFloat = 40
    static let columnRowHeight: CGFloat = 30
    static let listRowPadding: CGFloat = 12
    /// `.settings-drag-handle` 12 by 8, stroke 1.4 (:5762-5770).
    static let dragHandleSize = NSSize(width: 12, height: 8)
    static let dragHandleStroke: CGFloat = 1.4
    static let dragHandlePath = "M1 1h10M1 4h10M1 7h10"
    /// The drop line, 2 px of accent (:5823-5830).
    static let dropLineWidth: CGFloat = 2
    /// `.settings-list-row .file-icon` 20 by 20 (:5790).
    static let listIconSize: CGFloat = 20
    /// `.settings-list-bar` 28 tall, padding 0 6 (:5851-5854).
    static let listBarHeight: CGFloat = 28
    static let listBarPadding: CGFloat = 6
    /// `.settings-list-bar-button` 24 by 20, icon 14, stroke 1.5 (:5858-5881).
    static let listBarButtonSize = NSSize(width: 24, height: 20)
    static let listBarIconSize: CGFloat = 14
    static let listBarIconStroke: CGFloat = 1.5
    /// `.settings-list-bar-text-button` padding 0 8 (:5884).
    static let listBarTextPadding: CGFloat = 8
    /// `.settings-list-bar-divider` 1 by 14, margin 0 4 (:5899-5903).
    static let listBarDividerHeight: CGFloat = 14
    static let listBarDividerMargin: CGFloat = 4
    static let addPath = "M8 3.5v9M3.5 8h9"
    static let removePath = "M3.5 8h9"
    static let moveUpPath = "M4 10l4-4 4 4"
    static let moveDownPath = "M4 6l4 4 4-4"

    // MARK: Favorite icons (styles.css:5910-5976; SettingsView.tsx:278-282)

    /// `.settings-favorite-icon-button` 26 by 26 (:5918-5919).
    static let favoriteButtonSize: CGFloat = 26
    /// The grid: 6 columns of 30, 4 apart, 6 of padding; kept 12 from the window's edges and 4 from its button.
    static let iconGridColumns = 6
    static let iconGridCell: CGFloat = 30
    static let iconGridGap: CGFloat = 4
    static let iconGridPadding: CGFloat = 6
    /// The grid's 0.5 border (`--context-menu-border`) is drawn outside the padding: the grid is 1 wider and taller
    /// than the size its placement is worked out with.
    static var iconGridBorder: CGFloat { CGFloat(DesignTokens.menu.borderWidth) }
    static let iconGridMargin: CGFloat = 12
    static let iconGridOffset: CGFloat = 4
    /// The favorite icon in a cell of the grid (`.file-icon.favorite` 18 by 18, styles.css:3061); in a list row it is
    /// `listIconSize`.
    static let gridIconSize: CGFloat = 18

    // MARK: App pop-ups and menus (styles.css:5981-6010; SettingsView.tsx:900)

    /// `.settings-app-popup` gap 6, max 240, padding 0 26 0 6 (:5984-5988). The icons are 18: the rule for 16 (:5993)
    /// loses to the later `.file-icon.native-file-icon` (:6218), which has the same weight.
    static let appPopupGap: CGFloat = 6
    static let appPopupMaxWidth: CGFloat = 240
    static let appPopupPaddingLeading: CGFloat = 6
    static let appIconSize: CGFloat = 18
    /// The menu hangs 4 under its control.
    static let menuOffset: CGFloat = 4

    // MARK: Shortcuts (styles.css:6049-6215)

    /// `.shortcut-settings-intro` margin 0 2 12 (:6052).
    static let introMarginSide: CGFloat = 2
    static let introMarginBottom: CGFloat = 12
    /// `.shortcut-row` padding 5 0 (:6065); `.shortcut-row-line` gap 12, min-height 22 (:6075-6077).
    static let shortcutRowPadding: CGFloat = 5
    static let shortcutLineGap: CGFloat = 12
    static let shortcutLineMinHeight: CGFloat = 22
    /// `.shortcut-group-note` margin 8 0 (:6097).
    static let groupNoteMargin: CGFloat = 8
    /// `.shortcut-row-keys` gap 6 (:6105).
    static let slotGap: CGFloat = 6
    /// `.shortcut-slot-key` min 52 by 20, padding 0 8, radius 5, 1 px border (:6117-6122).
    static let slotMinWidth: CGFloat = 52
    static let slotHeight: CGFloat = 20
    static let slotPadding: CGFloat = 8
    static let slotRadius: CGFloat = 5
    static let slotBorder: CGFloat = 1
    /// The key's hover fill: text at 10% (:6131).
    static let slotHoverPercent = 0.10
    static let slotDash: [CGFloat] = [3, 2]
    /// `.shortcut-slot-clear` on the key's corner, 6 out (:6178-6181).
    static let slotClearOffset: CGFloat = 6
    /// `.shortcut-row-note` gap 10, margin-top 6 (:6193-6195); its buttons 6 apart (:6214).
    static let noteGap: CGFloat = 10
    static let noteMarginTop: CGFloat = 6
    static let noteButtonGap: CGFloat = 6
    /// `.push-button.is-small` padding 0 10 (:1297).
    static let smallButtonPadding: CGFloat = 10

    // MARK: Hairlines, shadows and motion

    /// The 0.5 px edges of swatches (:5711), thumbnails (:5634), checkboxes (:5568) and
    /// the push button's bezel.
    static let hairline: CGFloat = 0.5
    /// The tick of a menu's checked item (`MenuCheck`).
    static let menuCheckSize: CGFloat = 11
    /// A pop-up's menu opens with its checked item over the button's text.
    static let popupMenuInset: CGFloat = 3
    /// A row starts to drag 3 points from where it was pressed, and is dimmed to 0.4 while dragged (:5818).
    static let dragThreshold: CGFloat = 3
    static let draggingOpacity: CGFloat = 0.4
    /// The list bar's icons are drawn in a 16 by 16 box (SettingsView.tsx:589-607).
    static let listBarIconBox: CGFloat = 16
    /// The custom swatch's conic gradient is drawn in this many wedges.
    static let conicSteps = 120
    /// `--focus-ring`: the accent at 50%.
    static let focusRingAlpha = 0.5
}
