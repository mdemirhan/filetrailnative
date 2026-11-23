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

    /// One view's size is changed by hand in the folder on screen: as `changedByHand(.size)`, but only that view's
    /// size is no longer the tab view's.
    @discardableResult
    func changedByHand(_ size: ViewSizeKind) -> Bool {
        guard let override = tabViewOverride, override.holds(in: folderPath), override.covers(size) else {
            return true
        }
        tabViewOverride = override.without(size)
        return true
    }

    /// The folder's view as on screen where it decides `size`: it keeps the sizes, and no tab view's override holds
    /// for that view's size here. Nil where the pane's own size shows.
    func folderViewShown(_ size: ViewSizeKind) -> FolderViewSizes? {
        guard let shown = folderView?.shown, let sizes = shown.size else { return nil }
        if tabViewOverrideHolds, let override = tabViewOverride, override.covers(size) { return nil }
        return sizes
    }

    /// How a viewer in this pane starts: its own Follow and Read or Edit, or, before it has its own, the app's.
    var viewerDefaults: PaneViewer {
        guard let own = viewSizes ?? tab.map({ PaneViewSizes($0.preferences) }) else { return PaneViewer() }
        return PaneViewer(follows: own.viewerFollows, editing: own.viewerEditing)
    }

    /// A tab view's Follow and Read or Edit for this pane: its own from then on, and the app's Read or Edit, as one
    /// chosen by hand is.
    func takeViewerDefaults(_ keeps: PaneKeeps) {
        if let editing = keeps.viewerEditing { changeOwnSettings { $0.viewerEditing = editing } }
        if let follows = keeps.viewerFollows { setViewSize { $0.viewerFollows = follows } }
        if let editing = keeps.viewerEditing, let viewer, viewer.mode != .inPlace { viewer.opensForEditing = editing }
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

    /// The pane as a tab view sees it: its folder and its settings as on screen, the folder's view (and a tab view's
    /// over it) laid over what the pane carries, its sizes and columns included. Tab View Options starts from these,
    /// so a setting checked there keeps what the folder shows.
    var tabViewState: PaneState {
        let settings = shownKeeps
        // A viewer beside the other pane's list; a file in place of the folder is the folder's, for a tab view.
        let viewer = self.viewer.flatMap { viewer in
            viewer.mode == .inPlace
                ? nil : PaneViewer(follows: viewer.mode == .following, editing: viewer.isEditing)
        }
        return PaneState(
            folder: folderLetGo ? nil : folderPath, settings: settings, viewer: viewer,
            viewerInPlace: self.viewer?.mode == .inPlace, viewerDefaults: viewerDefaults,
            searchResults: searchResultsState)
    }

    /// How the pane shows search results now, whether they show or not.
    var searchResultsState: SearchResultsKeeps {
        SearchResultsKeeps(
            shownPreferences(tab.preferences), view: searchViewMode, groupBy: searchGroupBy,
            groupReversed: searchGroupReversed)
    }

    /// How a tab view shows search results in this pane, taken whole: the pane's own from now on, and the app's, as
    /// a change by hand over them is. Results on screen show it at once.
    func takeSearchResultsView(_ keeps: SearchResultsKeeps) {
        // Only what it changes goes to the app's, as with the rest below.
        let before = (searchViewMode, searchGroupBy, searchGroupReversed)
        searchViewMode = keeps.view
        searchGroupBy = keeps.groupBy
        searchGroupReversed = keeps.groupReversed
        tab?.updatePreferences {
            if before.0 != keeps.view { $0.searchViewMode = keeps.view }
            if before.1 != keeps.groupBy { $0.searchGroupBy = keeps.groupBy }
            if before.2 != keeps.groupReversed { $0.searchGroupReversed = keeps.groupReversed }
        }
        changeOwnSettings { $0 = keeps.applied(to: $0) }
        guard let search = searchStore else { return }
        search.session.setSort(keeps.sortBy, keeps.sortDirection)
        guard search.showsResults else { return }
        content.setMode(keeps.view)
        content.setSearchGroupBy(keeps.groupBy)
        content.setSearchGroupReversed(keeps.groupReversed)
        refreshColumns()
    }

    /// The settings a tab view keeps of this pane, taken as a change by hand would take them, but into what the pane
    /// carries whatever the folder's view keeps: the view, order, grouping and Folders First are the pane's; columns
    /// and each view's size kept the pane's own and the app's from now on, as ones set by hand are.
    func takeTabViewSettings(_ keeps: FolderViewKeeps, sizes: ViewSizesKeeps?) {
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
            changeOwnSettings {
                $0.detailColumns = columns.visibility
                $0.detailColumnOrder = columns.order
                $0.detailColumnWidths = columns.widths
            }
        }
        if let sizes {
            changeOwnSettings {
                if let icons = sizes.iconSizes { $0.iconSizes = icons }
                if let widths = sizes.compactListWidths { $0.compactListWidths = widths }
                if let counts = sizes.previewCounts { $0.previewCounts = counts }
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
