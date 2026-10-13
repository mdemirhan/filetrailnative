// Port of the preference keys of apps/desktop/src/shared/appPreferences.ts, as scenario `prefs` steps set them.
#if DEBUG
    import AppKit

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
            var controller: MainWindowController
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
                    unsupported.append(key)
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
                switch value.string {
                case "icons": context.controller.showAsIcons(nil)
                case "details": context.controller.showAsList(nil)
                case "list": return .unsupported("viewMode list")
                default: return .failed("viewMode \(describe(value))")
                }
                return .applied
            },
            "sortBy": { value, context in
                guard let key = value.string else { return .failed("sortBy \(describe(value))") }
                let ascending = (context.prefs["sortDirection"]?.string ?? "asc") != "desc"
                return AutomationCommands.sort(
                    by: key, ascending: ascending, controller: context.controller, window: context.window)
                    ? .applied : .unsupported("sortBy \(key)")
            },
            "sortDirection": { value, context in
                guard let direction = value.string, ["asc", "desc"].contains(direction) else {
                    return .failed("sortDirection \(describe(value))")
                }
                // Applied with sortBy when the step has both.
                if context.prefs["sortBy"] != nil { return .applied }
                return AutomationCommands.sort(
                    by: "name", ascending: direction == "asc", controller: context.controller, window: context.window)
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
