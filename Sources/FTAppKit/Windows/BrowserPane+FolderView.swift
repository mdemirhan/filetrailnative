// A pane and the folder's view it shows (View ▸ Folder View)
import AppKit
import FTFileSystem
import FTFoundation

/// What a pane carried as it came into a folder: its view, order, Folders First and sizes, and the app's columns and
/// sizes (what a change in a folder with no view of its own goes to).
struct PaneSettingsOnArrival {
    var viewMode: ExplorerViewMode
    var sortBy: SortByPreference
    var sortDirection: SortDirectionPreference
    var foldersFirst: Bool
    var viewSizes: PaneViewSizes?
    var app: AppPreferences

    @MainActor
    init(_ pane: BrowserPane) {
        viewMode = pane.viewMode
        sortBy = pane.sortBy
        sortDirection = pane.sortDirection
        foldersFirst = pane.foldersFirst
        viewSizes = pane.viewSizes
        app = pane.tab?.preferences ?? .defaults()
    }
}

extension BrowserPane {
    var folderViews: SharedFolderViews { tab.services.folderViews }

    /// The folder's view as the status bar and the menus show it; nil with no view, or while search results show.
    var shownFolderView: FolderViewOnScreen? {
        guard searchStore?.showsResults != true, !folderLetGo else { return nil }
        return folderView
    }

    /// The view the folder at `path` uses, found by its canonical path.
    func folderViewUse(for path: String) -> FolderViewUse? {
        guard let tab, !tab.services.folderViews.views.isEmpty else { return nil }
        return tab.services.folderViews.use(for: FolderIdentity.canonicalPath(path))
    }

    // MARK: Showing it

    /// The content shows the folder's view over what the pane carries: the view, the order, the columns and sizes.
    func showFolderView() {
        content.setView(
            sortBy: shownSortBy, direction: shownSortDirection, foldersFirst: shownFoldersFirst,
            includeHidden: includeHidden)
        refreshColumns()
        if searchStore?.showsResults != true { content.setMode(shownMode) }
        folderViewChanged()
    }

    /// What the status bar's symbol and the menus show of the folder's view changed.
    func folderViewChanged() {
        let bar = content.contentShell.pathBarRow
        if searchStore?.showsResults == true || folderLetGo {
            bar.folderViewMark = nil
        } else if let view = folderView {
            bar.folderViewMark = PathBarRowView.FolderViewMark(
                whose: view.isDraft ? .noView : view.use.own ? .own : .above, changed: view.hasUnsavedChanges,
                tooltip: FolderViewText.tooltip(view))
        } else {
            // Always there, so Folder View Options opens from it, and anything opened from the menu comes from it.
            bar.folderViewMark = PathBarRowView.FolderViewMark(
                whose: .noView, changed: false, tooltip: "No view of its own \u{00B7} Folder View Options")
        }
        // Folder Customization, open on this pane, shows the change: most aren't saved, so nothing else tells it.
        if let popover = tab?.folderViewPopover, popover.pane === self { popover.refresh() }
        tab?.paneChanged(.view, in: self)
    }

    /// The folders' views changed (saved here or in another window, or a folder moved): the folder on screen shows the
    /// view it now uses, keeping what is changed of it and not saved yet.
    func refreshFolderView() {
        guard loaded, !folderLetGo else { return }
        let use = folderViewUse(for: folder.path)
        let next = use.map { folderView?.taking($0) ?? FolderViewOnScreen($0) }
        guard next != folderView else { return }
        let before = (shownSortBy, shownSortDirection, shownFoldersFirst)
        folderView = next
        showFolderView()
        // Another order is a new read of the folder.
        if before != (shownSortBy, shownSortDirection, shownFoldersFirst) { viewChanged() }
    }

    // MARK: What is on screen

    /// The preferences with the pane's sizes and the folder's view laid over them: what the List and the sizes show.
    func shownPreferences(_ preferences: AppPreferences) -> AppPreferences {
        var shown = viewSizes?.applied(to: preferences) ?? preferences
        if let columns = folderView?.shown.columns {
            shown.detailColumns = columns.visibility
            shown.detailColumnOrder = columns.order
            shown.detailColumnWidths = columns.widths
        }
        if let sizes = folderView?.shown.size {
            shown.iconSizes = sizes.iconSizes
            shown.compactListWidths = sizes.compactListWidths
            shown.previewCounts = sizes.previewCounts
        }
        return shown
    }

    /// The five settings as on screen now.
    var shownKeeps: FolderViewKeeps {
        let preferences = shownPreferences(tab.preferences)
        return FolderViewKeeps(
            view: shownMode, sort: FolderViewSort(by: shownSortBy, direction: shownSortDirection),
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

    /// A change in Folder Customization, on screen until Save, as any change is: in a folder with no view, a view
    /// not saved yet, let go of again once nothing is changed.
    private func changeOnScreen(_ change: (inout FolderViewOnScreen) -> Void) {
        let path = folder.path
        var view =
            folderView
            ?? .draft(
                FolderView(
                    path: path, volume: FolderIdentity.volume(of: path), fileID: FolderIdentity.fileID(of: path),
                    keeps: FolderViewKeeps()))
        let before = (shownSortBy, shownSortDirection, shownFoldersFirst)
        change(&view)
        folderView = view.isDraft && !view.hasUnsavedChanges ? nil : view
        showFolderView()
        if before != (shownSortBy, shownSortDirection, shownFoldersFirst) { viewChanged() }
    }

    // MARK: Saving it

    /// A new view for this folder, as `change` makes it from the one it has (or an empty one), saved at once.
    private func saveOwnView(refresh: Bool = true, _ change: (inout FolderView) -> Void) {
        let path = folder.path
        let before = folderViews.views.own(path)?.keeps ?? FolderViewKeeps()
        var view =
            folderViews.views.own(path)
            ?? FolderView(
                path: path, volume: FolderIdentity.volume(of: path), fileID: FolderIdentity.fileID(of: path),
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

    /// The pane's own `settings` as they were when it came into the folder on screen; for the columns and sizes,
    /// every folder's (the app's) too, as a change here went to them.
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
            case .size:
                if let sizes = arrival.viewSizes {
                    setViewSize {
                        $0.iconSizes = sizes.iconSizes
                        $0.compactListWidths = sizes.compactListWidths
                        $0.previewCounts = sizes.previewCounts
                    }
                }
                tab.updatePreferences {
                    $0.iconSizes = arrival.app.iconSizes
                    $0.compactListWidths = arrival.app.compactListWidths
                    $0.previewCounts = arrival.app.previewCounts
                }
            case .columns:
                if let sizes = arrival.viewSizes { setViewSize { $0.detailColumnWidths = sizes.detailColumnWidths } }
                tab.updatePreferences {
                    $0.detailColumns = arrival.app.detailColumns
                    $0.detailColumnOrder = arrival.app.detailColumnOrder
                    $0.detailColumnWidths = arrival.app.detailColumnWidths
                }
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
        if let use = folderViewUse(for: folder.path) { folderView = FolderViewOnScreen(use) }
        showFolderView()
    }

    /// Save (Update Folder View): what is changed on screen is saved as this folder's view. In a folder using a view
    /// from above, that gives it one of its own: the one it used, with the changes. A folder's own view left keeping
    /// nothing, and covering nothing, is removed.
    func updateFolderView() {
        guard let view = folderView, view.hasUnsavedChanges else { return }
        let keeps = view.shown
        let subfolders = view.shownSubfolders
        saveOwnView(refresh: false) {
            $0.keeps = keeps
            $0.subfolders = subfolders
        }
        folderView = folderViewUse(for: folder.path).map(FolderViewOnScreen.init)
        showFolderView()
    }

    /// Revert: what is changed on screen goes back to what is saved; a view not saved yet goes.
    func revertFolderView() {
        guard folderView?.hasUnsavedChanges == true else { return }
        changeOnScreen { view in
            view.shown = view.saved
            view.shownSubfolders = view.savedSubfolders
        }
    }

    /// Reset Folder View: the folder's own view is removed; it uses the one above it, if one covers it, or the pane's.
    func resetFolderView() {
        guard folderViews.views.own(folder.path) != nil else { return }
        let before = (shownSortBy, shownSortDirection, shownFoldersFirst)
        folderViews.update(from: tab.windowID) { $0.remove(folder.path) }
        folderView = folderViewUse(for: folder.path).map(FolderViewOnScreen.init)
        showFolderView()
        if before != (shownSortBy, shownSortDirection, shownFoldersFirst) { viewChanged() }
    }

    /// Reset in Folder Customization: nothing kept and Apply to Subfolders off, on screen until Save, which removes the
    /// folder's customization. (View ▸ Folder View ▸ Reset Folder View removes it at once.)
    func clearFolderViewOnScreen() {
        guard folderView?.isOwnSaved == true else { return }
        changeOnScreen { view in
            view.shown = FolderViewKeeps()
            view.shownSubfolders = false
        }
    }

    /// A Keep box in Folder Customization: the setting is kept, with its value on screen, or not kept any more; on
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

    /// A value changed in Folder Customization: kept, with that value, on screen until Save.
    func setFolderViewValue(_ setting: FolderViewSetting, _ change: (inout FolderViewKeeps) -> Void) {
        var keeps = shownKeeps
        change(&keeps)
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

    static func tooltip(_ view: FolderViewOnScreen) -> String {
        if view.isDraft { return "No view of its own \u{00B7} Unsaved changes" }
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
