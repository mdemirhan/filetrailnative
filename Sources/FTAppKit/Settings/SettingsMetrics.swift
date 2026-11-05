import AppKit
import FTFoundation

/// The sizes of the Settings window. Root tokens (type scale, radii, control heights, colors) come from
/// `DesignTokens`.
enum SettingsMetrics {
    // MARK: Window

    static let windowSize = NSSize(width: 720, height: 540)
    static let windowMinSize = NSSize(width: 680, height: 420)
    static let trafficLights = NSPoint(x: 14, y: 16)

    // MARK: Sidebar

    /// The sidebar's width.
    static var sidebarWidth: CGFloat { CGFloat(DesignTokens.settingsSidebarWidth) }
    /// The sidebar's padding: 52 at the top, 10 on the other sides.
    static let sidebarPaddingTop: CGFloat = 52
    static let sidebarPaddingSide: CGFloat = 10
    /// The gap between sidebar items.
    static let sidebarItemGap: CGFloat = 2
    /// A sidebar item: its height, 8 of padding each side and 8 between its icon and title.
    static let sidebarItemHeight: CGFloat = 30
    static let sidebarItemPadding: CGFloat = 8
    static let sidebarItemGapInside: CGFloat = 8
    /// A sidebar item's icon tile: 20 by 20, radius 5.
    static let tileSize: CGFloat = 20
    static let tileRadius: CGFloat = 5
    /// The tile's glyph: 13 by 13, stroke 2.1.
    static let tileGlyphSize: CGFloat = 13
    static let tileGlyphStroke: CGFloat = 2.1
    /// The tile's inner edge and top highlight.
    static let tileEdge = RGBA(r: 0, g: 0, b: 0, alpha: 0.12)
    static let tileEdgeWidth: CGFloat = 0.5
    static let tileHighlight = RGBA(r: 255, g: 255, b: 255, alpha: 0.18)

    // MARK: Pane

    /// The pane's header: 52 tall, 20 of padding each side, 12 between its parts.
    static let headerHeight: CGFloat = 52
    static let headerPadding: CGFloat = 20
    static let headerGap: CGFloat = 12
    /// The Shortcuts search field beside the title.
    static let headerSearchWidth: CGFloat = 200
    /// The window's notice: 8 above and below, 20 each side, 12 between its parts.
    static let noticePaddingVertical: CGFloat = 8
    static let noticePaddingHorizontal: CGFloat = 20
    static let noticeGap: CGFloat = 12
    /// The danger color at 10%.
    static let noticeFillPercent = 0.10
    /// The scroll bar's room is kept on every page.
    static var scrollGutter: CGFloat { CGFloat(DesignTokens.scrollbarWidth) }

    // MARK: Page

    /// The page's padding: 4 at the top, 12 right, 20 at the bottom, 20 left.
    static let pagePaddingTop: CGFloat = 4
    static let pagePaddingRight: CGFloat = 12
    static let pagePaddingBottom: CGFloat = 20
    static let pagePaddingLeft: CGFloat = 20
    /// The page is at most 560 wide, centered.
    static let pageMaxWidth: CGFloat = 560
    /// The room under a section.
    static let sectionGap: CGFloat = 20
    /// A section's header: at least 22 tall, 2 each side and 5 below.
    static let sectionHeaderMinHeight: CGFloat = 22
    static let sectionHeaderPaddingSide: CGFloat = 2
    static let sectionHeaderPaddingBottom: CGFloat = 5
    /// A section's note: 6 above it, 2 each side, line height 1.4.
    static let sectionNoteMarginTop: CGFloat = 6
    static let sectionNoteMarginSide: CGFloat = 2
    static let noteLineHeight = 1.4
    /// The room above a section's footer.
    static let sectionFooterGap: CGFloat = 10

    // MARK: Cards and rows

    /// A card: 12 of padding each side, the menu's corner radius.
    static let cardPadding: CGFloat = 12
    static var cardRadius: CGFloat { CGFloat(DesignTokens.radii.menu) }
    /// The card's 1 px inner edge.
    static let cardEdgeWidth: CGFloat = 1
    /// A row: 16 between its parts, at least 40 tall, 8 above and below, a 1 px line under it.
    static let rowGap: CGFloat = 16
    static let rowMinHeight: CGFloat = 40
    static let rowPadding: CGFloat = 8
    static let separatorWidth: CGFloat = 1
    /// A row's description: 1 under the title, line height 14.
    static let rowDescGap: CGFloat = 1
    static let rowDescLineHeight: CGFloat = 14

    // MARK: Controls

    /// A pop-up's padding: 8 before its title and 26 after it, for the chevron.
    static let popupPaddingLeading: CGFloat = 8
    static let popupPaddingTrailing: CGFloat = 26
    static var popupMinWidth: CGFloat { CGFloat(DesignTokens.settingsPopupMinWidth) }
    /// A pop-up's chevron: 11 by 11, 8 from the right, stroke 2.4.
    static let chevronSize: CGFloat = 11
    static let chevronInset: CGFloat = 8
    static let chevronStroke: CGFloat = 2.4
    static let chevronPath = "M8 9.5l4-4 4 4M8 14.5l4 4 4-4"
    /// A field's padding of 8 each side; a number field is 48 wide.
    static let fieldPadding: CGFloat = 8
    static let numberFieldWidth: CGFloat = 48
    /// What an editable field's cell keeps between its frame and its text on each side.
    static let fieldCellInset: CGFloat = 2
    /// The room kept at the end of a number field for a stepper, shown or not: the right-aligned number ends this far
    /// before the padding.
    static let numberStepperWidth: CGFloat = 15
    /// The gap between a field and its unit.
    static let unitGap: CGFloat = 6
    /// The system's mini switch.
    static let switchSize = NSSize(width: 36, height: 16)
    /// A checkbox: 14 by 14, the extra-small corner radius, 6 from its label.
    static let checkboxSize: CGFloat = 14
    static let checkboxGap: CGFloat = 6
    static let checkPath = "M3.5 7.2l2.3 2.3 4.7-5"
    static let checkStroke: CGFloat = 1.8

    // MARK: Appearance

    /// The appearance picker: 12 between options, 4 between an option's picture and its label.
    static let appearanceGap: CGFloat = 12
    static let appearanceLabelGap: CGFloat = 4
    /// The ring around an appearance option: padding 2, radius 8; the selected one's ring is 2 px.
    static let appearanceRingPadding: CGFloat = 2
    static let appearanceRingRadius: CGFloat = 8
    static let appearanceRingWidth: CGFloat = 2
    /// An appearance thumbnail: 56 by 36, radius 6, edge 0.5.
    static let thumbSize = NSSize(width: 56, height: 36)
    static let thumbRadius: CGFloat = 6
    static let thumbEdge = RGBA(r: 0, g: 0, b: 0, alpha: 0.25)
    /// The window in the thumbnail: a 15 wide side, bars 3 tall (radius 2) 4 apart, padding 7 5.
    static let thumbSideWidth: CGFloat = 15
    static let thumbPaddingVertical: CGFloat = 7
    static let thumbPaddingHorizontal: CGFloat = 5
    static let thumbBarHeight: CGFloat = 3
    static let thumbBarRadius: CGFloat = 2
    static let thumbBarGap: CGFloat = 4
    static let thumbBarWidths: [CGFloat] = [0.7, 0.9, 0.55]
    /// Light and dark thumbnails: side, window, bar.
    static let thumbLight = (
        side: RGBA(r: 0xe4, g: 0xe4, b: 0xe9), main: RGBA(r: 255, g: 255, b: 255),
        bar: RGBA(r: 0xd4, g: 0xd4, b: 0xda)
    )
    static let thumbDark = (
        side: RGBA(r: 0x2c, g: 0x2c, b: 0x30), main: RGBA(r: 0x1e, g: 0x1e, b: 0x20),
        bar: RGBA(r: 0x3c, g: 0x3c, b: 0x41)
    )

    /// The accent swatches: 7 apart, 15 across.
    static let swatchGap: CGFloat = 7
    static let swatchSize: CGFloat = 15
    /// The swatch's edge, and the ring of the chosen one: the page color to 2, the accent to 3.5.
    static let swatchEdge = RGBA(r: 0, g: 0, b: 0, alpha: 0.2)
    static let swatchRingGap: CGFloat = 2
    static let swatchRingOuter: CGFloat = 3.5
    /// The custom swatch's conic gradient, from 210 degrees, and its fill 3.5 in.
    static let customSwatchStops: [RGBA] = [
        RGBA(r: 0xd8, g: 0x4a, b: 0x4a), RGBA(r: 0xf0, g: 0xb2, b: 0x36), RGBA(r: 0x23, g: 0xc7, b: 0xd9),
        RGBA(r: 0x95, g: 0x80, b: 0xff), RGBA(r: 0xe8, g: 0x72, b: 0x9a), RGBA(r: 0xd8, g: 0x4a, b: 0x4a),
    ]
    static let customSwatchStartDegrees: CGFloat = 210
    static let customFillInset: CGFloat = 3.5

    // MARK: Lists

    /// A list row: 9 between its parts, at least 40 tall, 12 of padding each side; column rows are 30.
    static let listRowGap: CGFloat = 9
    static let listRowHeight: CGFloat = 40
    static let columnRowHeight: CGFloat = 30
    static let listRowPadding: CGFloat = 12
    /// The drag handle: 12 by 8, stroke 1.4.
    static let dragHandleSize = NSSize(width: 12, height: 8)
    static let dragHandleStroke: CGFloat = 1.4
    static let dragHandlePath = "M1 1h10M1 4h10M1 7h10"
    /// The drop line, 2 px of accent.
    static let dropLineWidth: CGFloat = 2
    /// A list row's icon, 20 by 20.
    static let listIconSize: CGFloat = 20
    /// The bar under a list: 28 tall, 6 of padding each side.
    static let listBarHeight: CGFloat = 28
    static let listBarPadding: CGFloat = 6
    /// A button of the list bar: 24 by 20, its icon 14 with a 1.5 stroke.
    static let listBarButtonSize = NSSize(width: 24, height: 20)
    static let listBarIconSize: CGFloat = 14
    static let listBarIconStroke: CGFloat = 1.5
    /// A text button of the list bar: 8 of padding each side.
    static let listBarTextPadding: CGFloat = 8
    /// The list bar's divider: 1 by 14, 4 each side.
    static let listBarDividerHeight: CGFloat = 14
    static let listBarDividerMargin: CGFloat = 4
    static let addPath = "M8 3.5v9M3.5 8h9"
    static let removePath = "M3.5 8h9"
    static let moveUpPath = "M4 10l4-4 4 4"
    static let moveDownPath = "M4 6l4 4 4-4"

    // MARK: Favorite icons

    /// The button that picks a favorite's icon, 26 by 26.
    static let favoriteButtonSize: CGFloat = 26
    /// The grid: 6 columns of 30, 4 apart, 6 of padding; kept 12 from the window's edges and 4 from its button.
    static let iconGridColumns = 6
    static let iconGridCell: CGFloat = 30
    static let iconGridGap: CGFloat = 4
    static let iconGridPadding: CGFloat = 6
    /// The grid's 0.5 border, the context menu's, is drawn outside the padding: the grid is 1 wider and taller
    /// than the size its placement is worked out with.
    static var iconGridBorder: CGFloat { CGFloat(DesignTokens.menu.borderWidth) }
    static let iconGridMargin: CGFloat = 12
    static let iconGridOffset: CGFloat = 4
    /// The favorite icon in a cell of the grid; in a list row it is
    /// `listIconSize`.
    static let gridIconSize: CGFloat = 18

    // MARK: App pop-ups and menus

    /// An app pop-up: 6 between icon and name, at most 240 wide, 6 of padding before and 26 after. The icons
    /// are 18.
    static let appPopupGap: CGFloat = 6
    static let appPopupMaxWidth: CGFloat = 240
    static let appPopupPaddingLeading: CGFloat = 6
    static let appIconSize: CGFloat = 18
    /// The menu hangs 4 under its control.
    static let menuOffset: CGFloat = 4

    // MARK: Shortcuts

    /// The Shortcuts intro: 2 each side and 12 below.
    static let introMarginSide: CGFloat = 2
    static let introMarginBottom: CGFloat = 12
    /// A shortcut row: 5 above and below; its line 12 between its parts and at least 22 tall.
    static let shortcutRowPadding: CGFloat = 5
    static let shortcutLineGap: CGFloat = 12
    static let shortcutLineMinHeight: CGFloat = 22
    /// A group's note: 8 above and below.
    static let groupNoteMargin: CGFloat = 8
    /// The gap between a row's keys.
    static let slotGap: CGFloat = 6
    /// A shortcut key: at least 52 by 20, 8 of padding each side, radius 5, a 1 px border.
    static let slotMinWidth: CGFloat = 52
    static let slotHeight: CGFloat = 20
    static let slotPadding: CGFloat = 8
    static let slotRadius: CGFloat = 5
    static let slotBorder: CGFloat = 1
    /// The key's hover fill: text at 10%.
    static let slotHoverPercent = 0.10
    static let slotDash: [CGFloat] = [3, 2]
    /// A key's clear button sits on its corner, 6 out.
    static let slotClearOffset: CGFloat = 6
    /// A row's note: 10 between its parts, 6 above it; its buttons 6 apart.
    static let noteGap: CGFloat = 10
    static let noteMarginTop: CGFloat = 6
    static let noteButtonGap: CGFloat = 6
    /// A small push button's padding of 10 each side.
    static let smallButtonPadding: CGFloat = 10

    // MARK: Hairlines, shadows and motion

    /// The 0.5 px edges of swatches, thumbnails, checkboxes and
    /// the push button's bezel.
    static let hairline: CGFloat = 0.5
    /// The tick of a menu's checked item.
    static let menuCheckSize: CGFloat = 11
    /// A pop-up's menu opens with its checked item over the button's text.
    static let popupMenuInset: CGFloat = 3
    /// A row starts to drag 3 points from where it was pressed, and is dimmed to 0.4 while dragged.
    static let dragThreshold: CGFloat = 3
    static let draggingOpacity: CGFloat = 0.4
    /// The list bar's icons are drawn in a 16 by 16 box.
    static let listBarIconBox: CGFloat = 16
    /// The custom swatch's conic gradient is drawn in this many wedges.
    static let conicSteps = 120
    /// The focus ring: the accent at 50%.
    static let focusRingAlpha = 0.5
}
