// Port of the per-window state of apps/desktop/src/renderer/hooks/useExplorerTabs.ts (closedTabsRef) and the window
// session keys of apps/desktop/src/shared/appPreferences.ts that belong to a window rather than to a tab
import FTFoundation
import Foundation

/// What the tabs of one window share (the original's per-window state): which panels are shown, how wide the panes
/// and the columns are, and the tabs Reopen Closed Tab can bring back. Changing it in one tab changes it in all.
@MainActor
public final class TabGroupSession {
    /// The panels and widths of a window, as its session keeps them.
    public struct Panels: Equatable, Sendable {
        public var folderTreeOpen: Bool
        public var propertiesOpen: Bool
        public var detailRowOpen: Bool
        public var treeWidth: Int
        public var inspectorWidth: Int
        public var detailColumnWidths: DetailColumnWidths
        public var searchColumnWidths: SearchColumnWidths

        public init(_ session: WindowSession) {
            folderTreeOpen = session.folderTreeOpen
            propertiesOpen = session.propertiesOpen
            detailRowOpen = session.detailRowOpen
            treeWidth = session.treeWidth
            inspectorWidth = session.inspectorWidth
            detailColumnWidths = session.detailColumnWidths
            searchColumnWidths = session.searchColumnWidths
        }

        /// The session keys these are.
        public var patch: [String: JSONNode] {
            func node<T: Encodable>(_ value: T) -> JSONNode { (try? JSONNode.of(value)) ?? .null }
            return [
                "folderTreeOpen": .bool(folderTreeOpen), "propertiesOpen": .bool(propertiesOpen),
                "detailRowOpen": .bool(detailRowOpen), "treeWidth": .number(Double(treeWidth)),
                "inspectorWidth": .number(Double(inspectorWidth)), "detailColumnWidths": node(detailColumnWidths),
                "searchColumnWidths": node(searchColumnWidths),
            ]
        }
    }

    public private(set) var panels: Panels
    /// The tabs that were closed, most recent last. They are not kept between launches.
    public private(set) var closedTabs: [TabSnapshot] = []
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

    /// `rememberClosedTab`: a tab with no folder is not remembered; only the last `closedTabsLimit` are.
    public func rememberClosedTab(_ snapshot: TabSnapshot?) {
        guard let snapshot, !snapshot.currentPath.isEmpty else { return }
        closedTabs = Array(closedTabs.suffix(ExplorerTabs.closedTabsLimit - 1)) + [ExplorerTabs.reopenable(snapshot)]
    }

    /// The tab closed last, which Reopen Closed Tab brings back; nil with none.
    public func takeClosedTab() -> TabSnapshot? {
        closedTabs.popLast()
    }
}
