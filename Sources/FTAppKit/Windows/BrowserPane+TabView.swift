// A tab view in a pane: the settings it gives the pane, and the override it leaves on the folder it opened
import AppKit
import FTFoundation

extension BrowserPane {
    // MARK: What the folder's view decides

    /// The folder's view as on screen where it decides `setting` (`PaneViewResolution`): it keeps the setting, and no
    /// tab view's override holds for it here. Nil where the pane's own setting shows.
    func folderViewShown(_ setting: FolderViewSetting) -> FolderViewKeeps? {
        PaneViewResolution.folderViewDecides(
            setting, onScreen: folderView, override: tabViewOverride, folder: folderPath)
            ? folderView?.shown : nil
    }

    /// Whether a tab view's override holds in the folder on screen.
    var tabViewOverrideHolds: Bool {
        tabViewOverride?.holds(in: folderPath) == true && !folderLetGo
    }

    /// A setting is changed by hand in the folder on screen: it is no longer the tab view's, and the change goes where
    /// it would with no tab view (the folder's view where it keeps it, else the pane). "Not Used" lets go whole. True,
    /// so it reads as the first condition of the branch it decides.
    @discardableResult
    func changedByHand(_ setting: FolderViewSetting) -> Bool {
        guard let override = tabViewOverride, override.holds(in: folderPath), override.covers(setting) else {
            return true
        }
        tabViewOverride = override.without(setting)
        return true
    }

    /// A Folder View command or Folder View Options in this pane: the override ends first, so what they show and save
    /// is the folder's view, not the tab view laid over it.
    func endTabViewOverride() {
        guard tabViewOverride != nil || arrivingTabViewOverride != nil else { return }
        let before = shownOrder
        tabViewOverride = nil
        arrivingTabViewOverride = nil
        showFolderView()
        if before != shownOrder { viewChanged() }
    }

    // MARK: Arriving and following

    /// Another folder arrived: an override waiting for it takes its place there (the folder by the path its listing
    /// gives, a link's target), and any other ends.
    func arriveWithTabViewOverride(in path: String) {
        if var arriving = arrivingTabViewOverride {
            arriving.folder = path
            tabViewOverride = arriving
        } else {
            tabViewOverride = nil
        }
        arrivingTabViewOverride = nil
    }

    /// The folder on screen was renamed or moved and the pane follows it: the override goes with it.
    func followTabViewOverride(to path: String) {
        guard var override = tabViewOverride, override.holds(in: folderPath) else { return }
        override.folder = path
        if loaded {
            arrivingTabViewOverride = override
        } else {
            tabViewOverride = override
        }
    }

    // MARK: What a tab view sees and gives

    /// The pane as a tab view sees it: its folder and what it carries, its sizes and the app's columns included.
    var tabViewState: PaneState {
        let preferences = viewSizes?.applied(to: tab.preferences) ?? tab.preferences
        let settings = FolderViewKeeps(
            view: viewMode, groupBy: groupBy, groupReversed: groupReversed,
            sort: FolderViewSort(by: sortBy, direction: sortDirection), foldersFirst: foldersFirst,
            columns: FolderViewColumns(
                visibility: preferences.detailColumns, order: preferences.detailColumnOrder,
                widths: preferences.detailColumnWidths),
            size: FolderViewSizes(
                iconSizes: preferences.iconSizes, compactListWidths: preferences.compactListWidths,
                previewCounts: preferences.previewCounts))
        // A viewer beside the other pane's list; a file in place of the folder is the folder's, for a tab view.
        let viewer = self.viewer.flatMap { viewer in
            viewer.mode == .inPlace
                ? nil : PaneViewer(follows: viewer.mode == .following, editing: viewer.isEditing)
        }
        return PaneState(folder: folderLetGo ? nil : folderPath, settings: settings, viewer: viewer)
    }

    /// The settings a tab view keeps of this pane, taken as a change by hand would take them, but into what the pane
    /// carries whatever the folder's view keeps: the view, order, grouping and Folders First are the pane's; sizes and
    /// column widths the pane's own and the app's from now on, as a size set by hand is; the columns shown and their
    /// order the app's, as the List's header sets them for every folder without columns of its own.
    func takeTabViewSettings(_ keeps: FolderViewKeeps) {
        if let view = keeps.view { viewMode = view }
        if let field = keeps.groupBy {
            groupBy = field
            groupReversed = keeps.groupReversed == true
        }
        if let sort = keeps.sort {
            sortBy = sort.by
            sortDirection = sort.direction
        }
        if let first = keeps.foldersFirst { foldersFirst = first }
        if let columns = keeps.columns {
            setViewSize { $0.detailColumnWidths = columns.widths }
            changeSharedSettings {
                $0.detailColumns = columns.visibility
                $0.detailColumnOrder = columns.order
                $0.detailColumnWidths = columns.widths
            }
        }
        if let size = keeps.size {
            setViewSize {
                $0.iconSizes = size.iconSizes
                $0.compactListWidths = size.compactListWidths
                $0.previewCounts = size.previewCounts
            }
            changeSharedSettings {
                $0.iconSizes = size.iconSizes
                $0.compactListWidths = size.compactListWidths
                $0.previewCounts = size.previewCounts
            }
        }
    }

    /// The pane shows what it now carries and what the override decides, reading its folder again where the order
    /// changed.
    func showTabViewSettings(orderBefore: ShownOrder) {
        refreshColumns()
        showFolderView()
        if orderBefore != shownOrder { viewChanged() }
        tab.paneChanged(.view, in: self)
    }
}
