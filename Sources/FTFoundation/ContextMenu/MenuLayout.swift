import Foundation

/// The look every app-drawn menu shares: the toolbar menus, the history and path-bar menus, and the right-click
/// menu's submenu rows.
public struct MenuLayout: Equatable, Sendable {
    public var minWidth: Double
    public var padding: Double
    public var borderWidth: Double
    public var rowHeight: Double
    public var rowPaddingTrailing: Double
    public var rowGap: Double
    public var separatorHeight: Double
    public var separatorMarginVertical: Double
    public var separatorMarginHorizontal: Double
    public var historyNameMaxWidth: Double

    static func make() -> MenuLayout {
        MenuLayout(
            minWidth: 220, padding: 5, borderWidth: 0.5, rowHeight: 24,
            rowPaddingTrailing: 10, rowGap: 6, separatorHeight: 1,
            separatorMarginVertical: 5, separatorMarginHorizontal: 10,
            historyNameMaxWidth: 220)
    }
}

/// The notifications and where they stack.
public struct ToastLayout: Equatable, Sendable {
    public var rightInset: Double
    public var maxWidth: Double
    /// The window's width less this is the widest a card gets in a narrow window.
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

/// The progress card of a running operation.
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
    /// The small Stop button.
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

extension DesignTokens {
    public static let menu = MenuLayout.make()
    public static let toast = ToastLayout.make()
    public static let progressCard = ProgressCardLayout.make()
}
