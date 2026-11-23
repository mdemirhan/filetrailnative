// A pane and the folder's view it shows (View ▸ Folder View)
import AppKit
import FTFoundation

/// What a pane carried as it came into a folder: its view, order, Folders First and sizes; and what it has changed
/// since, in that folder, of the columns and sizes every folder without its own shares.
struct PaneSettingsOnArrival {
    var viewMode: ExplorerViewMode
    var sortBy: SortByPreference
    var sortDirection: SortDirectionPreference
    var foldersFirst: Bool
    var groupBy: GroupByPreference
    var groupReversed: Bool
    var viewSizes: PaneViewSizes?
    var shared = SharedSettingChanges()
    /// The pane is changing the app's columns or sizes itself, now: the change it hears of meanwhile is its own.
    var isChangingShared = false

    @MainActor
    init(_ pane: BrowserPane) {
        viewMode = pane.viewMode
        sortBy = pane.sortBy
        sortDirection = pane.sortDirection
        foldersFirst = pane.foldersFirst
        groupBy = pane.groupBy
        groupReversed = pane.groupReversed
        viewSizes = pane.viewSizes
    }
}

/// The columns and sizes every folder without its own shares (the app's), as one pane changed them in the folder it
/// shows: each as it was before the pane's first change of it there, and as the pane last left it. Only these go back
/// once the folder keeps the setting, and only where they are still as the pane left them, so a column shown or a size
/// set from another tab or window meanwhile stays. One changed elsewhere is forgotten as the pane hears of it
/// (`forgetWhatChangedElsewhere`), so it stays as well when it was set back to what the pane had left.
struct SharedSettingChanges: Equatable {
    struct Change<Value: Equatable>: Equatable {
        var before: Value
        var after: Value
    }

    var columns: [OptionalDetailColumnKey: Change<Bool>] = [:]
    var columnOrder: Change<[OptionalDetailColumnKey]>?
    var columnWidths: [DetailColumnKey: Change<Int>] = [:]
    var iconSizes: [Density: Change<Int>] = [:]
    var compactListWidths: [Density: Change<Int>] = [:]
    var previewCounts: [Density: Change<Int>] = [:]

    /// The value before the first change stays; one changed back to it is no change.
    private static func noted<Value: Equatable>(_ change: Change<Value>?, _ before: Value, _ after: Value)
        -> Change<Value>?
    {
        guard before != after else { return change }
        let first = change?.before ?? before
        return first == after ? nil : Change(before: first, after: after)
    }

    /// The pane changed the app's settings from `before` to `after`.
    mutating func note(from before: AppPreferences, to after: AppPreferences) {
        for key in OptionalDetailColumnKey.allCases {
            columns[key] = Self.noted(columns[key], before.detailColumns[key], after.detailColumns[key])
        }
        columnOrder = Self.noted(columnOrder, before.detailColumnOrder, after.detailColumnOrder)
        for key in DetailColumnKey.allCases {
            columnWidths[key] = Self.noted(
                columnWidths[key], before.detailColumnWidths[key], after.detailColumnWidths[key])
        }
        for density in Density.allCases {
            iconSizes[density] = Self.noted(iconSizes[density], before.iconSizes[density], after.iconSizes[density])
            compactListWidths[density] = Self.noted(
                compactListWidths[density], before.compactListWidths[density], after.compactListWidths[density])
            previewCounts[density] = Self.noted(
                previewCounts[density], before.previewCounts[density], after.previewCounts[density])
        }
    }

    /// `now` with the columns the pane changed as they were before, where they are still as it left them.
    func columnsPutBack(in now: AppPreferences) -> AppPreferences {
        var next = now
        for (key, change) in columns where now.detailColumns[key] == change.after {
            next.detailColumns[key] = change.before
        }
        if let columnOrder, now.detailColumnOrder == columnOrder.after { next.detailColumnOrder = columnOrder.before }
        for (key, change) in columnWidths where now.detailColumnWidths[key] == change.after {
            next.detailColumnWidths[key] = change.before
        }
        return next
    }

    /// `now` with the sizes the pane changed as they were before, where they are still as it left them.
    func sizesPutBack(in now: AppPreferences) -> AppPreferences {
        var next = now
        for (density, change) in iconSizes where now.iconSizes[density] == change.after {
            next.iconSizes[density] = change.before
        }
        for (density, change) in compactListWidths where now.compactListWidths[density] == change.after {
            next.compactListWidths[density] = change.before
        }
        for (density, change) in previewCounts where now.previewCounts[density] == change.after {
            next.previewCounts[density] = change.before
        }
        return next
    }

    /// What isn't as the pane left it any more was changed elsewhere since, and is no longer the pane's to put back:
    /// not even once it is set as the pane had left it again (a column hidden in another tab, then shown there).
    mutating func forgetWhatChangedElsewhere(now: AppPreferences) {
        columns = columns.filter { now.detailColumns[$0.key] == $0.value.after }
        if let columnOrder, now.detailColumnOrder != columnOrder.after { self.columnOrder = nil }
        columnWidths = columnWidths.filter { now.detailColumnWidths[$0.key] == $0.value.after }
        iconSizes = iconSizes.filter { now.iconSizes[$0.key] == $0.value.after }
        compactListWidths = compactListWidths.filter { now.compactListWidths[$0.key] == $0.value.after }
        previewCounts = previewCounts.filter { now.previewCounts[$0.key] == $0.value.after }
    }

    mutating func forgetColumns() {
        columns = [:]
        columnOrder = nil
        columnWidths = [:]
    }

    mutating func forgetSizes() {
        iconSizes = [:]
        compactListWidths = [:]
        previewCounts = [:]
    }
}

extension BrowserPane {
    var folderViews: SharedFolderViews { tab.services.folderViews }

    /// The folder's view as the status bar and the menus show it; nil with no view, or while search results show.
    var shownFolderView: FolderViewOnScreen? {
        guard searchStore?.showsResults != true, !folderLetGo else { return nil }
        return folderView
    }

    /// The view the folder at `path` uses, found by the path as it is: a look in memory, with no call to the disk.
    func folderViewUse(for path: String) -> FolderViewUse? {
        tab?.services.folderViews.use(for: path)
    }

    // MARK: Showing it

    /// The content shows the folder's view over what the pane carries: the view, the order, the columns and sizes.
    func showFolderView() {
        content.setView(
            sortBy: shownSortBy, direction: shownSortDirection, foldersFirst: shownFoldersFirst,
            includeHidden: includeHidden, groupBy: shownGroupBy, groupReversed: shownGroupReversed)
        refreshColumns()
        if searchStore?.showsResults != true { content.setMode(shownMode) }
        folderViewChanged()
    }

    /// What the status bar's symbol and the menus show of the folder's view changed.
    func folderViewChanged() {
        let bar = content.contentShell.pathBarRow
        if searchStore?.showsResults == true || folderLetGo {
            bar.folderViewMark = nil
            // No folder is on screen to customize: Folder View Options, open on this pane, closes with its symbol,
            // as its Keep boxes would go on changing a view that isn't shown.
            if let tab, tab.folderViewPopover?.pane === self { tab.closeFolderViewPopover() }
        } else if let view = folderView {
            bar.folderViewMark = PathBarRowView.FolderViewMark(
                whose: view.isDraft ? .noView : view.use.own ? .own : .above, changed: view.hasUnsavedChanges,
                tooltip: FolderViewText.tooltip(view, tabView: tabViewOverrideHolds ? tabViewOverride?.choice : nil))
        } else {
            // Always there, so Folder View Options opens from it, and anything opened from the menu comes from it.
            bar.folderViewMark = PathBarRowView.FolderViewMark(
                whose: .noView, changed: false, tooltip: "No view of its own \u{00B7} Folder View Options")
        }
        // Folder View Options, open on this pane, shows the change: most aren't saved, so nothing else tells it.
        if let popover = tab?.folderViewPopover, popover.pane === self { popover.refresh() }
        tab?.paneChanged(.view, in: self)
    }

    /// The folders' views changed (saved here or in another window, or a folder moved): the folder on screen shows the
    /// view it now uses, keeping what is changed of it and not saved yet.
    func refreshFolderView() {
        guard loaded, !folderLetGo else { return }
        let use = folderViewUse(for: folderPath)
        // A folder with no view, given one on screen that waits for Save: while it still has none to use, the change
        // was some other folder's, and what waits here stays.
        if use == nil, let draft = folderView, draft.isDraft, draft.hasUnsavedChanges { return }
        let next = use.map { folderView?.taking($0) ?? FolderViewOnScreen($0) }
        guard next != folderView else { return }
        let before = shownOrder
        folderView = next
        showFolderView()
        // Another order is a new read of the folder.
        if before != shownOrder { viewChanged() }
    }

    // MARK: What is on screen

    /// The preferences with the pane's sizes and the folder's view laid over them: what the List and the sizes show.
    func shownPreferences(_ preferences: AppPreferences) -> AppPreferences {
        var shown = viewSizes?.applied(to: preferences) ?? preferences
        if let columns = folderViewShown(.columns)?.columns {
            shown.detailColumns = columns.visibility
            shown.detailColumnOrder = columns.order
            shown.detailColumnWidths = columns.widths
        }
        // Each view's size apart: a tab view may hold one view's and leave the others to the folder's view.
        for size in ViewSizeKind.allCases {
            guard let sizes = folderViewShown(size) else { continue }
            switch size {
            case .icons: shown.iconSizes = sizes.iconSizes
            case .compactList: shown.compactListWidths = sizes.compactListWidths
            case .previews: shown.previewCounts = sizes.previewCounts
            }
        }
        return shown
    }

    /// The six settings as on screen now.
    var shownKeeps: FolderViewKeeps {
        let preferences = shownPreferences(tab.preferences)
        return FolderViewKeeps(
            view: shownMode, groupBy: shownGroupBy, groupReversed: shownGroupReversed,
            sort: FolderViewSort(by: shownSortBy, direction: shownSortDirection),
            foldersFirst: shownFoldersFirst,
            columns: FolderViewColumns(
                visibility: preferences.detailColumns, order: preferences.detailColumnOrder,
                widths: preferences.detailColumnWidths),
            size: FolderViewSizes(
                iconSizes: preferences.iconSizes, compactListWidths: preferences.compactListWidths,
                previewCounts: preferences.previewCounts))
    }

    /// Whether the folder's view keeps `setting`, so a change of it is a change of the view, unsaved until Update.
    func folderViewKeeps(_ setting: FolderViewSetting) -> Bool {
        searchStore?.showsResults != true && folderView?.shown.keeps(setting) == true
    }

    /// A change of a kept setting, on screen only.
    func changeShownFolderView(_ change: (inout FolderViewKeeps) -> Void) {
        guard var view = folderView else { return }
        change(&view.shown)
        folderView = view
        refreshColumns()
        folderViewChanged()
    }

    /// A change in Folder View Options, on screen until Save, as any change is: in a folder with no view, a view
    /// not saved yet, let go of again once nothing is changed.
    private func changeOnScreen(_ change: (inout FolderViewOnScreen) -> Void) {
        let path = folderPath
        var view = folderView ?? .draft(FolderView(path: path, keeps: FolderViewKeeps()))
        let before = shownOrder
        change(&view)
        // Covering the folders inside with nothing kept, where they would look no different, is no change: it goes
        // off with the last setting unchecked.
        if view.shown.isEmpty, viewStoppedForSubfolders == nil { view.shownSubfolders = false }
        folderView = view.isDraft && !view.hasUnsavedChanges ? nil : view
        showFolderView()
        if before != shownOrder { viewChanged() }
    }

    /// The view from a folder above that the folders inside this one would stop using if this folder covered them
    /// while keeping nothing: the nearest covering view above, when it keeps something. Nil where covering them with
    /// nothing kept would change nothing, as they show the pane's settings already.
    var viewStoppedForSubfolders: FolderView? {
        guard let above = folderViews.views.covering(folderPath), !above.keeps.isEmpty else { return nil }
        return above
    }

    /// Whether Apply to Subfolders can be turned on: there is something to apply, or a view from above to stop.
    var canApplyToSubfolders: Bool {
        folderView?.shown.isEmpty == false || viewStoppedForSubfolders != nil
    }

    // MARK: Saving it

    /// A new view for this folder, as `change` makes it from the one it has (or an empty one), saved at once.
    private func saveOwnView(refresh: Bool = true, _ change: (inout FolderView) -> Void) {
        let path = folderPath
        let before = folderViews.views.own(path)?.keeps ?? FolderViewKeeps()
        var view =
            folderViews.views.own(path)
            ?? FolderView(
                path: path,
                // A folder using a view from above starts from a copy of it, as on screen.
                keeps: folderView?.shown ?? FolderViewKeeps())
        change(&view)
        folderViews.update(from: tab.windowID) { views in
            if view.isEmpty { views.remove(path) } else { views.set(view) }
        }
        // A setting the pane carried until now, and the folder keeps from now: what was changed of it here belongs
        // to the folder, and the pane goes back to what it had as it came in.
        restoreArrivalSettings(view.keeps.kept.filter { !before.keeps($0) })
        if refresh { refreshFolderView() }
    }

    /// A change the pane makes to the columns or sizes every folder without its own shares (the app's): noted, so
    /// it can go back if the folder on screen comes to keep that setting.
    func changeSharedSettings(_ change: (inout EditedPreferences) -> Void) {
        guard let tab else { return }
        guard settingsOnArrival != nil else {
            tab.updatePreferences(change)
            return
        }
        let before = tab.preferences
        settingsOnArrival?.isChangingShared = true
        tab.updatePreferences(change)
        settingsOnArrival?.isChangingShared = false
        settingsOnArrival?.shared.note(from: before, to: tab.preferences)
    }

    /// The app's settings changed, here or in another pane, tab or window. What this pane noted of a column or a size
    /// that was changed elsewhere since is forgotten, so a later Remember or Save here leaves it as it was set there.
    func sharedSettingsChanged() {
        guard let arrival = settingsOnArrival, !arrival.isChangingShared, arrival.shared != SharedSettingChanges(),
            let tab
        else { return }
        settingsOnArrival?.shared.forgetWhatChangedElsewhere(now: tab.preferences)
    }

    /// The pane's own `settings` as they were when it came into the folder on screen; for the columns and sizes,
    /// what the pane changed here of every folder's (the app's) too, as a change here went to them. What was changed
    /// of them elsewhere meanwhile, in another tab or window, is not the pane's to put back.
    func restoreArrivalSettings(_ settings: [FolderViewSetting]) {
        guard let arrival = settingsOnArrival, let tab, !settings.isEmpty else { return }
        for setting in settings {
            switch setting {
            case .view:
                viewMode = arrival.viewMode
            case .sort:
                sortBy = arrival.sortBy
                sortDirection = arrival.sortDirection
            case .foldersFirst:
                foldersFirst = arrival.foldersFirst
            case .groupBy:
                groupBy = arrival.groupBy
                groupReversed = arrival.groupReversed
            case .size:
                if let sizes = arrival.viewSizes {
                    setViewSize {
                        $0.iconSizes = sizes.iconSizes
                        $0.compactListWidths = sizes.compactListWidths
                        $0.previewCounts = sizes.previewCounts
                    }
                }
                let now = tab.preferences
                let back = arrival.shared.sizesPutBack(in: now)
                if back != now {
                    tab.updatePreferences {
                        if back.iconSizes != now.iconSizes { $0.iconSizes = back.iconSizes }
                        if back.compactListWidths != now.compactListWidths {
                            $0.compactListWidths = back.compactListWidths
                        }
                        if back.previewCounts != now.previewCounts { $0.previewCounts = back.previewCounts }
                    }
                }
                settingsOnArrival?.shared.forgetSizes()
            case .columns:
                if let sizes = arrival.viewSizes {
                    setViewSize {
                        $0.detailColumns = sizes.detailColumns
                        $0.detailColumnOrder = sizes.detailColumnOrder
                        $0.detailColumnWidths = sizes.detailColumnWidths
                    }
                }
                let now = tab.preferences
                let back = arrival.shared.columnsPutBack(in: now)
                if back != now {
                    tab.updatePreferences {
                        if back.detailColumns != now.detailColumns { $0.detailColumns = back.detailColumns }
                        if back.detailColumnOrder != now.detailColumnOrder {
                            $0.detailColumnOrder = back.detailColumnOrder
                        }
                        if back.detailColumnWidths != now.detailColumnWidths {
                            $0.detailColumnWidths = back.detailColumnWidths
                        }
                    }
                }
                settingsOnArrival?.shared.forgetColumns()
            }
        }
        tab.group?.tabChanged(tab)
    }

    /// View ▸ Folder View ▸ Remember View for This Folder: the folder keeps all five settings as they are on screen,
    /// saved at once.
    func rememberFolderView() {
        let keeps = shownKeeps
        let subfolders = folderView?.shownSubfolders
        saveOwnView {
            $0.keeps = keeps
            if let subfolders { $0.subfolders = subfolders }
        }
        // What is on screen is what is saved now.
        if let use = folderViewUse(for: folderPath) { folderView = FolderViewOnScreen(use) }
        showFolderView()
    }

    /// Save (Update Folder View): what is changed on screen is saved as this folder's view. In a folder using a view
    /// from above, that gives it one of its own: the one it used, with the changes. A folder's own view left keeping
    /// nothing, and covering nothing, is removed.
    func updateFolderView() {
        // With no folder on screen there is none to save a view for: the one let go of keeps what it has saved.
        guard !folderLetGo, let view = folderView, view.hasUnsavedChanges else { return }
        let keeps = view.shown
        let subfolders = view.shownSubfolders
        saveOwnView(refresh: false) {
            $0.keeps = keeps
            $0.subfolders = subfolders
        }
        folderView = folderViewUse(for: folderPath).map(FolderViewOnScreen.init)
        showFolderView()
    }

    /// Revert: what is changed on screen goes back to what is saved; a view not saved yet goes.
    func revertFolderView() {
        guard !folderLetGo, folderView?.hasUnsavedChanges == true else { return }
        changeOnScreen { view in
            view.shown = view.saved
            view.shownSubfolders = view.savedSubfolders
        }
    }

    /// Reset Folder View: the folder's own view is removed; it uses the one above it, if one covers it, or the pane's.
    func resetFolderView() {
        guard !folderLetGo, folderViews.views.own(folderPath) != nil else { return }
        let before = shownOrder
        folderViews.update(from: tab.windowID) { $0.remove(folderPath) }
        folderView = folderViewUse(for: folderPath).map(FolderViewOnScreen.init)
        showFolderView()
        if before != shownOrder { viewChanged() }
    }

    /// Reset in Folder View Options: nothing kept and Apply to Subfolders off, on screen until Save, which removes the
    /// folder's customization. (View ▸ Folder View ▸ Reset Folder View removes it at once.)
    func clearFolderViewOnScreen() {
        guard folderView?.isOwnSaved == true else { return }
        changeOnScreen { view in
            view.shown = FolderViewKeeps()
            view.shownSubfolders = false
        }
    }

    /// A Keep box in Folder View Options: the setting is kept, with its value on screen, or not kept any more; on
    /// screen until Save.
    func setFolderViewKeeps(_ setting: FolderViewSetting, _ keeps: Bool) {
        let current = shownKeeps
        changeOnScreen { view in
            if keeps {
                view.shown.take(setting, from: current)
            } else {
                view.shown.forget(setting)
            }
        }
    }

    /// A value changed in Folder View Options: kept, with that value, on screen until Save.
    /// The value already on screen, chosen again, is no change: it doesn't start keeping the setting, and Save stays
    /// dimmed, as a setting changed back by hand is no change (a Keep box checked does keep it).
    func setFolderViewValue(_ setting: FolderViewSetting, _ change: (inout FolderViewKeeps) -> Void) {
        let current = shownKeeps
        var keeps = current
        change(&keeps)
        guard keeps != current else { return }
        changeOnScreen { $0.shown.take(setting, from: keeps) }
    }

    /// Apply to Subfolders, on screen until Save.
    func setFolderViewSubfolders(_ on: Bool) {
        changeOnScreen { $0.shownSubfolders = on }
    }
}

/// The words the folder view's symbol, popovers and menus use.
enum FolderViewText {
    /// The folder's last name, or the path for the disk.
    static func name(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    static func tooltip(_ view: FolderViewOnScreen, tabView: FolderViewsChoice? = nil) -> String {
        if view.isDraft { return "No view of its own \u{00B7} Unsaved changes" }
        switch tabView {
        case .tabViewFirst?: return tooltip(view) + " \u{00B7} The tab view comes first here"
        case .notUsed?: return tooltip(view) + " \u{00B7} Not used by the tab view here"
        case .folderFirst?, nil: break
        }
        let whose =
            view.use.own ? "This folder's view" : "Folder view from “\(name(view.use.view.path))”"
        let keeps = view.saved.isEmpty ? " (keeps nothing)" : ""
        return whose + keeps + (view.hasUnsavedChanges ? " · Unsaved changes" : "")
    }

    /// A setting's value, as the menus and tooltips say it.
    static func value(_ setting: FolderViewSetting, of keeps: FolderViewKeeps, mode: ExplorerViewMode, density: Density)
        -> String
    {
        switch setting {
        case .view:
            return keeps.view?.menuName ?? ""
        case .groupBy:
            guard let groupBy = keeps.groupBy else { return "" }
            return keeps.groupReversed == true ? "\(groupBy.title), reversed" : groupBy.title
        case .sort:
            guard let sort = keeps.sort else { return "" }
            return "\(sort.by.title), \(sort.direction == .asc ? "ascending" : "descending")"
        case .foldersFirst:
            return keeps.foldersFirst == false ? "Mixed with Files" : "Before Files"
        case .columns:
            guard let columns = keeps.columns else { return "" }
            let shown = DetailsColumns.visible(visibility: columns.visibility, order: columns.order)
            return shown.map(DetailsColumns.title).joined(separator: ", ")
        case .size:
            guard let size = keeps.size else { return "" }
            return sizeParts(size, density: density).map { "\($0.name) \($0.value)" }.joined(separator: ", ")
        }
    }

    /// The three sizes a folder's size keeps, each named, at `density`.
    static func sizeParts(_ size: FolderViewSizes, density: Density) -> [(name: String, value: String)] {
        [
            ("Icon size", "\(size.iconSizes[density]) pt"),
            ("Column width", "\(size.compactListWidths[density]) pt"),
            ("Previews", "\(size.previewCounts[density]) at a time"),
        ]
    }

    /// What is saved of a setting changed on screen, for the tooltip of its mark: only the sizes that differ.
    static func saved(
        _ setting: FolderViewSetting, of view: FolderViewOnScreen, mode: ExplorerViewMode, density: Density
    )
        -> String
    {
        let (shown, saved) = (view.shown, view.saved)
        if !saved.keeps(setting) { return "Saved: not kept" }
        if !shown.keeps(setting) {
            return "Saved: kept, \(value(setting, of: saved, mode: mode, density: density))"
        }
        if setting == .size, let now = shown.size, let was = saved.size {
            let differ = zip(sizeParts(now, density: density), sizeParts(was, density: density))
                .filter { $0.0.value != $0.1.value }
                .map { "\($0.1.name) \($0.1.value)" }
            if !differ.isEmpty { return "Saved: " + differ.joined(separator: ", ") }
            return "Saved: another size at the other density"
        }
        return "Saved: " + value(setting, of: saved, mode: mode, density: density)
    }
}
