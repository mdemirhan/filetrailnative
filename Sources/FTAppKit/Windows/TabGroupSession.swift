import FTFoundation
import Foundation

/// What the tabs of one window share: which panels are shown and how wide, and the tabs
/// Reopen Closed Tab can bring back. Changing it in one tab changes it in all.
@MainActor
public final class TabGroupSession {
    /// The panels and widths of a window, as its session keeps them.
    public struct Panels: Equatable, Sendable {
        public var folderTreeOpen: Bool
        public var propertiesOpen: Bool
        public var detailRowOpen: Bool
        public var treeWidth: Int
        public var inspectorWidth: Int

        public init(_ session: WindowSession) {
            folderTreeOpen = session.folderTreeOpen
            propertiesOpen = session.propertiesOpen
            detailRowOpen = session.detailRowOpen
            treeWidth = session.treeWidth
            inspectorWidth = session.inspectorWidth
        }

        /// Sets the session keys these are.
        public func write(to preferences: inout EditedPreferences) {
            preferences.folderTreeOpen = folderTreeOpen
            preferences.propertiesOpen = propertiesOpen
            preferences.detailRowOpen = detailRowOpen
            preferences.treeWidth = treeWidth
            preferences.inspectorWidth = inspectorWidth
        }
    }

    /// A tab that was closed, and where it was in the row.
    public struct ClosedTab: Equatable, Sendable {
        public var snapshot: TabSnapshot
        /// Its place in the row as it went, where Reopen Closed Tab puts it back; nil to put it after the tab on screen.
        public var index: Int?
        /// The tab while it is still closing (`tabLeft`), for its place to be the one it leaves.
        var tab: ObjectIdentifier?
    }

    public private(set) var panels: Panels
    /// The tabs that were closed, most recent last. They are not kept between launches.
    public private(set) var closedTabs: [ClosedTab] = []
    /// Told when the panels change, so every tab shows them alike.
    public var onPanelsChanged: (Panels) -> Void = { _ in }

    public init(_ session: WindowSession) {
        panels = Panels(session)
    }

    public func update(_ change: (inout Panels) -> Void) {
        var next = panels
        change(&next)
        guard next != panels else { return }
        panels = next
        onPanelsChanged(next)
    }

    /// `rememberClosedTab`: a tab with no folder is not remembered; only the last `closedTabsLimit` are. `index` is
    /// its place in the row, which `tabLeft` sets again as it goes.
    public func rememberClosedTab(_ snapshot: TabSnapshot?, at index: Int? = nil, tab: ObjectIdentifier? = nil) {
        guard let snapshot, !snapshot.currentPath.isEmpty else { return }
        let closed = ClosedTab(snapshot: ExplorerTabs.reopenable(snapshot), index: index, tab: tab)
        closedTabs = Array(closedTabs.suffix(ExplorerTabs.closedTabsLimit - 1)) + [closed]
    }

    /// The tab left the row from `index`: that is the place it comes back to. Tabs closed together (Close Other Tabs)
    /// leave one after another, so each place is counted among the tabs still there, and reopened in turn they come
    /// back in their order.
    public func tabLeft(_ tab: ObjectIdentifier, at index: Int) {
        guard let found = closedTabs.lastIndex(where: { $0.tab == tab }) else { return }
        closedTabs[found].index = index
        closedTabs[found].tab = nil
    }

    /// The tab closed last, which Reopen Closed Tab brings back; nil with none.
    public func takeClosedTab() -> ClosedTab? {
        closedTabs.popLast()
    }
}
