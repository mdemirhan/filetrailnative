#if DEBUG
    import AppKit
    import FTFoundation

    /// The `prefs` keys of the views of the folder: the order, the List's columns and their widths, each view's density, and
    /// the view.
    @MainActor
    enum AutomationContentPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            AutomationPrefs.register(.sortBy) { value, context in
                guard let name = value.string, let field = SortByPreference(rawValue: name) else {
                    return .failed("sortBy \(value)")
                }
                guard let controller = context.controller else { return .unsupported("sortBy outside an explorer") }
                let direction = context.prefs["sortDirection"]?.string == "desc" ? SortDirectionPreference.desc : .asc
                controller.setSort(field, direction)
                return .applied
            }
            AutomationPrefs.register(.sortDirection) { value, context in
                guard let name = value.string, let direction = SortDirectionPreference(rawValue: name) else {
                    return .failed("sortDirection \(value)")
                }
                // Applied with sortBy when the step has both.
                if context.prefs["sortBy"] != nil { return .applied }
                guard let controller = context.controller else { return .unsupported("sortDirection") }
                controller.setSort(controller.viewState.sortBy, direction)
                return .applied
            }
            AutomationPrefs.register(.viewMode) { value, context in
                guard let controller = context.controller else { return .unsupported("viewMode outside an explorer") }
                switch value.string {
                case "icons": controller.perform(.viewAsIcons)
                case "details": controller.perform(.viewAsDetails)
                case "list": controller.perform(.viewAsList)
                default: return .failed("viewMode \(value)")
                }
                return .applied
            }
            for key: PreferenceKey in [.detailColumns, .detailColumnOrder, .detailColumnWidths] {
                AutomationPrefs.register(key) { value, context in
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    AutomationPrefs.set(key, value, on: controller)
                    // The window's session keeps its widths and writes them back whenever it saves.
                    if key == .detailColumnWidths {
                        let widths = controller.preferences.detailColumnWidths
                        controller.updatePanels { $0.detailColumnWidths = widths }
                    }
                    controller.refreshColumns()
                    return .applied
                }
            }
            AutomationPrefs.register(.density) { value, context in
                guard let controller = context.controller else { return .unsupported("density") }
                guard let density = value.string.flatMap(Density.init(rawValue:)) else {
                    return .failed("density \(value)")
                }
                controller.updatePreferences { $0.density = density }
                controller.refreshColumns()
                controller.sidebarController.revealSelectionFromTheTop()
                return .applied
            }
        }
    }
#endif
