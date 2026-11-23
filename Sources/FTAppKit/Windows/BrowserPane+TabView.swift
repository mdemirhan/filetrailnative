// A tab view in a pane: what it sees of the pane, and the settings it gives it
import AppKit
import FTFoundation

extension BrowserPane {
    // MARK: The viewer's own

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

    // MARK: What a tab view sees and gives

    /// The pane as a tab view sees it: its folder and its settings as on screen, the folder's view laid over what the
    /// pane carries, its sizes and columns included. Tab View Options starts from these,
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
