// Port of the preference keys of apps/desktop/src/shared/appPreferences.ts, as scenario `prefs` steps set them.
#if DEBUG
    import AppKit
    import FTFoundation

    /// What a scenario's `prefs` step does here. Each preference has a handler; the work package that
    /// builds a preference registers one (`AutomationPrefs.register`). A key with no handler yet is
    /// reported as unsupported, key by key, and the run goes on.
    @MainActor
    enum AutomationPrefs {
        enum Result: Equatable {
            case applied
            /// This app can't apply the value yet; the text says what.
            case unsupported(String)
            /// The value is not one the original takes.
            case failed(String)
        }

        struct Context {
            /// The explorer window's controller; nil when the window steps act on is another one.
            var controller: MainWindowController?
            var window: NSWindow
            /// Every value of the step, for keys that go together (sortBy and sortDirection).
            var prefs: [String: Scenario.PrefValue]
        }

        typealias Handler = @MainActor (Scenario.PrefValue, Context) -> Result

        /// Every preference key of the original (`DEFAULT_APP_PREFERENCES`, appPreferences.ts:390-448).
        static let originalKeys: Set<String> = [
            "theme", "accent", "zoomPercent", "viewMode", "searchViewMode", "sortBy", "sortDirection", "foldersFirst",
            "compactListView", "compactDetailsView", "compactIconView", "compactTreeView",
            "singleClickExpandTreeItems", "detailColumns", "detailColumnOrder", "detailColumnWidths", "searchColumns",
            "searchColumnOrder", "searchColumnWidths", "notificationsEnabled", "markClipboardItems",
            "autoCalculateFolderSizes", "folderTreeOpen", "propertiesOpen", "detailRowOpen", "topToolbarItems",
            "terminalApp", "defaultTextEditor", "openWithApplications", "fileActivationAction", "diskImageOpensIn",
            "returnKeyAction", "shortcutOverrides", "openItemLimit", "includeHidden", "searchPatternMode",
            "searchMatchScope", "searchRecursive", "searchSkipGitFolders", "searchSkipGitIgnored",
            "searchResultsSortBy", "searchResultsSortDirection", "treeWidth", "inspectorWidth",
            "restoreSessionOnStartup", "openTabs", "activeTabIndex", "treeRootPath", "lastVisitedPath",
            "lastVisitedFavoritePath", "favorites", "favoritesPlacement", "favoritesExpanded", "locationsExpanded",
            "favoritesInitialized", "batchRenameSettings", "batchRenamePresets",
        ]

        /// The window session keys (appPreferences.ts:357-380). The rest the whole app
        /// shares: a key of those with no handler of its own goes out as Settings sends it, as the original's driver
        /// sends it.
        static let sessionKeys: Set<String> = [
            "openTabs", "activeTabIndex", "treeRootPath", "lastVisitedPath", "lastVisitedFavoritePath", "viewMode",
            "searchViewMode", "sortBy", "sortDirection", "searchResultsSortBy", "searchResultsSortDirection",
            "includeHidden", "foldersFirst", "favoritesExpanded", "locationsExpanded", "folderTreeOpen",
            "propertiesOpen", "detailRowOpen", "treeWidth", "inspectorWidth", "detailColumnWidths",
            "searchColumnWidths",
        ]

        /// Capture shorthands: `density` sets the four compact switches together, as the driver does.
        static let shorthandKeys: Set<String> = ["density"]

        private static var handlers: [String: Handler] = defaultHandlers

        /// Registers (or replaces) the handler of a preference key.
        static func register(_ key: String, _ handler: @escaping Handler) {
            handlers[key] = handler
        }

        static func hasHandler(_ key: String) -> Bool { handlers[key] != nil }

        /// Applies a `prefs` step: ok when every key took, partial listing the keys this app can't set
        /// yet, failed for a key or value the original doesn't have.
        static func apply(_ prefs: [String: Scenario.PrefValue], context: Context) -> AutomationRunner.Outcome {
            var unsupported: [String] = []
            var failed: [String] = []
            for key in prefs.keys.sorted() {
                guard let value = prefs[key] else { continue }
                guard originalKeys.contains(key) || shorthandKeys.contains(key) else {
                    failed.append("\(key) is not a preference of the original")
                    continue
                }
                guard let handler = handlers[key] else {
                    if let controller = context.controller, originalKeys.contains(key), !sessionKeys.contains(key) {
                        controller.updatePreferences([key: node(value)])
                    } else {
                        unsupported.append(key)
                    }
                    continue
                }
                switch handler(value, context) {
                case .applied: break
                case .unsupported(let what): unsupported.append(what)
                case .failed(let what): failed.append(what)
                }
            }
            if !failed.isEmpty { return .init(.failed, "bad values: " + failed.joined(separator: ", ")) }
            if !unsupported.isEmpty { return .init(.partial, "unsupported: " + unsupported.joined(separator: ", ")) }
            return .init(.ok)
        }

        static func node(_ value: Scenario.PrefValue) -> JSONNode {
            switch value {
            case .string(let text): .string(text)
            case .number(let number): .number(number)
            case .bool(let flag): .bool(flag)
            case .null: .null
            case .array(let items): .array(items.map(node))
            case .object(let members): .object(members.mapValues(node))
            }
        }

        private static func describe(_ value: Scenario.PrefValue) -> String {
            switch value {
            case .string(let text): text
            case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
            case .bool(let flag): String(flag)
            case .null: "null"
            case .array: "[…]"
            case .object: "{…}"
            }
        }

        /// What the spike can show so far.
        private static let defaultHandlers: [String: Handler] = [
            "theme": { value, _ in
                switch value.string {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "auto": NSApp.appearance = nil
                default: return .failed("theme \(describe(value))")
                }
                return .applied
            },
            "viewMode": { value, context in
                guard let controller = context.controller else { return .unsupported("viewMode outside an explorer") }
                switch value.string {
                case "icons": controller.showAsIcons(nil)
                case "details": controller.showAsList(nil)
                case "list": controller.perform(.viewAsList)
                default: return .failed("viewMode \(describe(value))")
                }
                return .applied
            },
            "sortBy": { value, context in
                guard let key = value.string else { return .failed("sortBy \(describe(value))") }
                guard let controller = context.controller else { return .unsupported("sortBy outside an explorer") }
                let ascending = (context.prefs["sortDirection"]?.string ?? "asc") != "desc"
                return AutomationCommands.sort(
                    by: key, ascending: ascending, controller: controller, window: context.window)
                    ? .applied : .unsupported("sortBy \(key)")
            },
            "sortDirection": { value, context in
                guard let direction = value.string, ["asc", "desc"].contains(direction) else {
                    return .failed("sortDirection \(describe(value))")
                }
                // Applied with sortBy when the step has both.
                if context.prefs["sortBy"] != nil { return .applied }
                guard let controller = context.controller else {
                    return .unsupported("sortDirection outside an explorer")
                }
                return AutomationCommands.sort(
                    by: "name", ascending: direction == "asc", controller: controller, window: context.window)
                    ? .applied : .unsupported("sortDirection")
            },
            "zoomPercent": { value, _ in
                value.number == 100 ? .applied : .unsupported("zoomPercent \(describe(value))")
            },
            "density": { value, _ in
                switch value.string {
                case "comfortable": .applied
                case "compact": .unsupported("density compact")
                default: .failed("density \(describe(value))")
                }
            },
            "accent": { value, _ in
                // The spike draws with the system accent color.
                value.string?.lowercased() == "#007aff" ? .applied : .unsupported("accent \(describe(value))")
            },
            "favoritesPlacement": { value, _ in
                // The spike's sidebar is the separate layout: Favorites and Locations lists.
                value.string == "separate" ? .applied : .unsupported("favoritesPlacement \(describe(value))")
            },
        ]
    }
#endif
