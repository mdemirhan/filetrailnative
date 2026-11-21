import Foundation

/// How the room of the content column is shared between two panes.
public enum PaneSplit {
    /// The left pane's share when they share it evenly.
    public static let even = 0.5
    public static let minimum = 0.2
    public static let maximum = 0.8
    /// The narrowest a pane gets; the window is kept wide enough for two.
    public static let minimumPaneWidth = 280.0
    /// The divider's room: a hairline in the middle of a band the pointer can take.
    public static let dividerWidth = 9.0

    public static func clamp(_ split: Double) -> Double {
        guard split.isFinite else { return even }
        return min(maximum, max(minimum, split))
    }

    /// The left pane's share that shows it `leftWidth` wide in a column `columnWidth` wide, within the shares a drag
    /// of the divider allows. A column with no room shares it evenly.
    public static func share(leftWidth: Double, columnWidth: Double) -> Double {
        let room = columnWidth - dividerWidth
        guard room > 0, leftWidth.isFinite else { return even }
        return clamp(leftWidth / room)
    }

    /// The left pane's width in a column `columnWidth` wide, kept so that neither pane is narrower than the minimum
    /// while there is room for both.
    public static func leftWidth(_ split: Double, columnWidth: Double) -> Double {
        let room = max(0, columnWidth - dividerWidth)
        let wanted = (room * clamp(split)).rounded()
        guard room >= minimumPaneWidth * 2 else { return (room / 2).rounded() }
        return min(room - minimumPaneWidth, max(minimumPaneWidth, wanted))
    }
}
