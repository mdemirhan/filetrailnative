// Port of the menu, toast and progress card rules of apps/desktop/src/renderer/styles.css (973-1205, 1560-1740)
import Foundation

/// The look every app-drawn menu shares (`.toolbar-menu`, `.context-menu`, `.context-submenu`): the toolbar menus, the
/// history and path-bar menus, and the right-click menu's submenu rows.
public struct MenuLayout: Equatable, Sendable {
    public var minWidth: Double
    public var submenuMinWidth: Double
    public var padding: Double
    public var borderWidth: Double
    public var rowHeight: Double
    public var rowPaddingLeading: Double
    public var rowPaddingTrailing: Double
    /// The leading column for a checkmark or an icon; labels of every menu start 30 points in from the edge.
    public var checkColumn: Double
    public var rowGap: Double
    public var shortcutGap: Double
    public var separatorHeight: Double
    public var separatorMarginVertical: Double
    public var separatorMarginHorizontal: Double
    /// A line icon of the right-click menu, and its chevron.
    public var iconSize: Double
    public var iconStrokeWidth: Double
    public var chevronSize: Double
    /// The menu is kept this far inside the window (`menuPlacement.ts`).
    public var viewportMargin: Double
    public var historyMaxWidth: Double
    public var historyNameMaxWidth: Double

    static func make() -> MenuLayout {
        MenuLayout(
            minWidth: 220, submenuMinWidth: 180, padding: 5, borderWidth: 0.5, rowHeight: 24, rowPaddingLeading: 8,
            rowPaddingTrailing: 10, checkColumn: 16, rowGap: 6, shortcutGap: 14, separatorHeight: 1,
            separatorMarginVertical: 5, separatorMarginHorizontal: 10, iconSize: 14, iconStrokeWidth: 1.8,
            chevronSize: 10, viewportMargin: 8, historyMaxWidth: 420, historyNameMaxWidth: 220)
    }
}

/// `.toast-viewport` and `.toast-card`.
public struct ToastLayout: Equatable, Sendable {
    public var rightInset: Double
    public var maxWidth: Double
    /// The window's width less this is the widest a card gets in a narrow window (`calc(100vw - 24px)`).
    public var windowMargin: Double
    public var stackGap: Double
    public var paddingTop: Double
    public var paddingLeading: Double
    public var paddingBottom: Double
    public var paddingTrailing: Double
    public var bodyGap: Double
    public var iconSize: Double
    public var borderWidth: Double
    /// The slide-in rises this far.
    public var slideDistance: Double
    public var iconSignStrokeWidth: Double

    static func make() -> ToastLayout {
        ToastLayout(
            rightInset: 12, maxWidth: 420, windowMargin: 24, stackGap: 6,
            paddingTop: 6, paddingLeading: 10, paddingBottom: 6, paddingTrailing: 14, bodyGap: 8, iconSize: 18,
            borderWidth: 0.5,
            slideDistance: 8, iconSignStrokeWidth: 1.6)
    }
}

/// `.copy-paste-progress-card`.
public struct ProgressCardLayout: Equatable, Sendable {
    public var rightInset: Double
    public var width: Double
    public var windowMargin: Double
    public var paddingTop: Double
    public var paddingHorizontal: Double
    public var paddingBottom: Double
    public var rowGap: Double
    public var headerGap: Double
    public var trackHeight: Double
    public var detailGap: Double
    public var footerGap: Double
    public var borderWidth: Double
    /// The small Stop button (`.push-button.is-small`).
    public var stopHeight: Double
    public var stopMinWidth: Double
    public var stopPaddingHorizontal: Double
    public var stopFontSize: Double

    static func make() -> ProgressCardLayout {
        ProgressCardLayout(
            rightInset: 12, width: 320, windowMargin: 24, paddingTop: 10, paddingHorizontal: 12, paddingBottom: 10,
            rowGap: 6, headerGap: 12, trackHeight: 4, detailGap: 4, footerGap: 12, borderWidth: 0.5, stopHeight: 22,
            stopMinWidth: 76, stopPaddingHorizontal: 12, stopFontSize: 12)
    }
}

/// `.toolbar-customize-panel` (styles.css) and its push buttons.
public struct CustomizePanelLayout: Equatable, Sendable {
    public var maxWidth: Double
    public var sideMargin: Double
    public var gapBelowToolbar: Double
    public var paddingTop: Double
    public var paddingLeading: Double
    public var paddingBottom: Double
    public var paddingTrailing: Double
    public var columnMin: Double
    public var rowGap: Double
    public var columnGap: Double
    public var chip: Double
    public var itemPaddingVertical: Double
    public var itemPaddingHorizontal: Double
    public var itemGap: Double
    public var labelLineHeight: Double
    public var buttonHeight: Double
    public var buttonMinWidth: Double
    public var buttonPaddingInline: Double

    static func make() -> CustomizePanelLayout {
        CustomizePanelLayout(
            maxWidth: 760, sideMargin: 16, gapBelowToolbar: 8, paddingTop: 16, paddingLeading: 18, paddingBottom: 14,
            paddingTrailing: 18, columnMin: 76, rowGap: 8, columnGap: 4, chip: 32, itemPaddingVertical: 4,
            itemPaddingHorizontal: 2, itemGap: 4, labelLineHeight: 1.2, buttonHeight: 24, buttonMinWidth: 76,
            buttonPaddingInline: 12)
    }
}

/// `.app-tooltip` (styles.css).
public struct TooltipLayout: Equatable, Sendable {
    public var paddingTop: Double
    public var paddingLeading: Double
    public var paddingBottom: Double
    public var paddingTrailing: Double
    public var maxWidth: Double
    public var lineHeight: Double

    static func make() -> TooltipLayout {
        TooltipLayout(
            paddingTop: 3, paddingLeading: 8, paddingBottom: 3, paddingTrailing: 8, maxWidth: 420, lineHeight: 1.35)
    }
}

extension DesignTokens {
    public static let customizePanel = CustomizePanelLayout.make()
    public static let tooltip = TooltipLayout.make()
    public static let menu = MenuLayout.make()
    public static let toast = ToastLayout.make()
    public static let progressCard = ProgressCardLayout.make()
}
