// Port of the search preference keys of apps/desktop/src/shared/appPreferences.ts, as capture scenarios set them
// (`prefs` steps)
#if DEBUG
    import AppKit
    import FTFoundation

    /// The `prefs` keys of search: the five options (a Settings edit, which the tab's search takes without running
    /// again), the results' order, their view, and their List columns.
    @MainActor
    enum AutomationSearchPrefs {
        private static var registered = false

        private static func node(_ value: Scenario.PrefValue) -> JSONNode {
            switch value {
            case .string(let text): .string(text)
            case .number(let number): .number(number)
            case .bool(let flag): .bool(flag)
            case .null: .null
            case .array(let items): .array(items.map(node))
            case .object(let members): .object(members.mapValues(node))
            }
        }

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            for key in [
                "searchPatternMode", "searchMatchScope", "searchRecursive", "searchSkipGitFolders",
                "searchSkipGitIgnored",
            ] {
                AutomationPrefs.register(key) { value, context in
                    guard let controller = context.controller else { return .unsupported(key) }
                    controller.updatePreferences([key: node(value)])
                    controller.search.session.applyDefaults(controller.preferences, keys: [key])
                    return .applied
                }
            }
            AutomationPrefs.register("searchResultsSortBy") { value, context in
                guard let name = value.string, let sortBy = SearchResultsSortByPreference(rawValue: name) else {
                    return .failed("searchResultsSortBy \(value)")
                }
                guard let controller = context.controller else { return .unsupported("searchResultsSortBy") }
                let direction =
                    context.prefs["searchResultsSortDirection"]?.string == "desc" ? SortDirectionPreference.desc : .asc
                controller.search.session.setSort(sortBy, direction)
                controller.updatePreferences([
                    "searchResultsSortBy": .string(name), "searchResultsSortDirection": .string(direction.rawValue),
                ])
                return .applied
            }
            AutomationPrefs.register("searchResultsSortDirection") { value, context in
                guard let name = value.string, let direction = SortDirectionPreference(rawValue: name) else {
                    return .failed("searchResultsSortDirection \(value)")
                }
                if context.prefs["searchResultsSortBy"] != nil { return .applied }
                guard let controller = context.controller else { return .unsupported("searchResultsSortDirection") }
                let session = controller.search.session
                session.setSort(session.sortBy, direction)
                controller.updatePreferences(["searchResultsSortDirection": .string(name)])
                return .applied
            }
            AutomationPrefs.register("searchViewMode") { value, context in
                guard let controller = context.controller else { return .unsupported("searchViewMode") }
                guard let name = value.string, let mode = ExplorerViewMode(rawValue: name) else {
                    return .failed("searchViewMode \(value)")
                }
                controller.setSearchViewMode(mode)
                return .applied
            }
            for key in ["searchColumns", "searchColumnOrder", "searchColumnWidths"] {
                AutomationPrefs.register(key) { value, context in
                    guard let controller = context.controller else { return .unsupported(key) }
                    controller.updatePreferences([key: node(value)])
                    // The window's session keeps its widths and writes them back whenever it saves.
                    if key == "searchColumnWidths" {
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
