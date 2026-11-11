#if DEBUG
    import AppKit
    import FTFoundation

    /// The `prefs` keys of search: the five options (a Settings edit, which the tab's search takes without running
    /// again), the results' order, their view, and their List columns.
    @MainActor
    enum AutomationSearchPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            for key: PreferenceKey in [
                .searchPatternMode, .searchMatchScope, .searchRecursive, .searchSkipGitFolders, .searchSkipGitIgnored,
            ] {
                AutomationPrefs.register(key) { value, context in
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    AutomationPrefs.set(key, value, on: controller)
                    controller.search.session.applyDefaults(controller.preferences, keys: [key])
                    return .applied
                }
            }
            AutomationPrefs.register(.searchResultsSortBy) { value, context in
                guard let name = value.string, let sortBy = SearchResultsSortByPreference(rawValue: name) else {
                    return .failed("searchResultsSortBy \(value)")
                }
                guard let controller = context.controller else { return .unsupported("searchResultsSortBy") }
                let direction =
                    context.prefs["searchResultsSortDirection"]?.string == "desc" ? SortDirectionPreference.desc : .asc
                controller.search.session.setSort(sortBy, direction)
                controller.updatePreferences {
                    $0.searchResultsSortBy = sortBy
                    $0.searchResultsSortDirection = direction
                }
                return .applied
            }
            AutomationPrefs.register(.searchResultsSortDirection) { value, context in
                guard let name = value.string, let direction = SortDirectionPreference(rawValue: name) else {
                    return .failed("searchResultsSortDirection \(value)")
                }
                if context.prefs["searchResultsSortBy"] != nil { return .applied }
                guard let controller = context.controller else { return .unsupported("searchResultsSortDirection") }
                let session = controller.search.session
                session.setSort(session.sortBy, direction)
                controller.updatePreferences { $0.searchResultsSortDirection = direction }
                return .applied
            }
            AutomationPrefs.register(.searchViewMode) { value, context in
                guard let controller = context.controller else { return .unsupported("searchViewMode") }
                guard let name = value.string, let mode = ExplorerViewMode(rawValue: name) else {
                    return .failed("searchViewMode \(value)")
                }
                controller.setSearchViewMode(mode)
                return .applied
            }
            for key: PreferenceKey in [.searchColumns, .searchColumnOrder, .searchColumnWidths] {
                AutomationPrefs.register(key) { value, context in
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    AutomationPrefs.set(key, value, on: controller)
                    // The window's session keeps its widths and writes them back whenever it saves.
                    if key == .searchColumnWidths {
                        let widths = controller.preferences.searchColumnWidths
                        controller.updatePanels { $0.searchColumnWidths = widths }
                    }
                    controller.refreshColumns()
                    return .applied
                }
            }
        }
    }
#endif
