// Port of the content pane's preference keys of apps/desktop/src/shared/appPreferences.ts, as capture scenarios set them
// (`prefs` steps)
#if DEBUG
    import AppKit
    import FTFoundation

    /// The `prefs` keys of the List view: the order, the columns and their widths, the density and the view.
    @MainActor
    enum AutomationContentPrefs {
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
            AutomationPrefs.register("sortBy") { value, context in
                guard let name = value.string, let field = SortByPreference(rawValue: name) else {
                    return .failed("sortBy \(value)")
                }
                guard let controller = context.controller else { return .unsupported("sortBy outside an explorer") }
                let direction = context.prefs["sortDirection"]?.string == "desc" ? SortDirectionPreference.desc : .asc
                controller.setSort(field, direction)
                return .applied
            }
            AutomationPrefs.register("sortDirection") { value, context in
                guard let name = value.string, let direction = SortDirectionPreference(rawValue: name) else {
                    return .failed("sortDirection \(value)")
                }
                // Applied with sortBy when the step has both.
                if context.prefs["sortBy"] != nil { return .applied }
                guard let controller = context.controller else { return .unsupported("sortDirection") }
                controller.setSort(controller.viewState.sortBy, direction)
                return .applied
            }
            AutomationPrefs.register("viewMode") { value, context in
                guard let controller = context.controller else { return .unsupported("viewMode outside an explorer") }
                switch value.string {
                case "icons": controller.perform(.viewAsIcons)
                case "details": controller.perform(.viewAsDetails)
                case "list": controller.perform(.viewAsList)
                default: return .failed("viewMode \(value)")
                }
                return .applied
            }
            for key in ["detailColumns", "detailColumnOrder", "detailColumnWidths", "compactDetailsView"] {
                AutomationPrefs.register(key) { value, context in
                    guard let controller = context.controller else { return .unsupported(key) }
                    controller.updatePreferences([key: node(value)])
                    controller.refreshColumns()
                    return .applied
                }
            }
            AutomationPrefs.register("density") { value, context in
                guard let controller = context.controller else { return .unsupported("density") }
                guard let name = value.string, ["comfortable", "compact"].contains(name) else {
                    return .failed("density \(value)")
                }
                controller.updatePreferences([
                    "compactListView": .bool(name == "compact"), "compactDetailsView": .bool(name == "compact"),
                    "compactIconView": .bool(name == "compact"), "compactTreeView": .bool(name == "compact"),
                ])
                controller.refreshColumns()
                return .applied
            }
        }
    }
#endif
