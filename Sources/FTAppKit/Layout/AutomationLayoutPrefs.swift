// Port of the window-layout and toolbar keys of apps/desktop/src/shared/appPreferences.ts, as capture scenarios set
// them (`prefs` steps)
#if DEBUG
    import AppKit
    import FTFoundation

    /// The `prefs` keys of the window's layout and toolbar: which panels are open and how wide, the toolbar's items,
    /// Folders First, hidden files and the theme.
    @MainActor
    enum AutomationLayoutPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            func panel(_ key: String, _ apply: @escaping (inout TabGroupSession.Panels, Bool) -> Void) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key) }
                    controller.updatePanels { apply(&$0, on) }
                    return .applied
                }
            }
            panel("folderTreeOpen") { $0.folderTreeOpen = $1 }
            panel("propertiesOpen") { $0.propertiesOpen = $1 }
            panel("detailRowOpen") { $0.detailRowOpen = $1 }
            func width(_ key: String, _ apply: @escaping (inout TabGroupSession.Panels, Int) -> Void) {
                AutomationPrefs.register(key) { value, context in
                    guard let number = value.number else { return .failed("\(key) is not a number") }
                    guard let controller = context.controller else { return .unsupported(key) }
                    controller.updatePanels { apply(&$0, Int(number)) }
                    return .applied
                }
            }
            width("treeWidth") {
                $0.treeWidth = AppPreferenceLimits.clampPaneWidth(Double($1), AppPreferenceLimits.treeWidthRange)
            }
            width("inspectorWidth") {
                $0.inspectorWidth = AppPreferenceLimits.clampPaneWidth(
                    Double($1), AppPreferenceLimits.inspectorWidthRange)
            }
            AutomationPrefs.register("topToolbarItems") { value, context in
                guard case .array(let entries) = value else { return .failed("topToolbarItems is not a list") }
                guard let controller = context.controller else {
                    return .unsupported("topToolbarItems")
                }
                let items = entries.compactMap(\.string).map { JSONNode.string($0) }
                controller.updatePreferences(["topToolbarItems": .array(items)])
                return .applied
            }
            func toggle(_ key: String, _ command: RendererCommand, _ current: @escaping (ExplorerViewState) -> Bool) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key) }
                    if current(controller.viewState) != on { controller.perform(command) }
                    return .applied
                }
            }
            toggle("foldersFirst", .toggleFoldersFirst) { $0.foldersFirst }
            toggle("includeHidden", .toggleHiddenFiles) { $0.includeHidden }
            AutomationPrefs.register("theme") { value, context in
                guard let name = value.string, let theme = ThemePreference(rawValue: name) else {
                    return .failed("theme \(value.string ?? "?")")
                }
                switch theme {
                case .light: NSApp.appearance = NSAppearance(named: .aqua)
                case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                case .auto: NSApp.appearance = nil
                }
                context.controller?.updatePreferences(["theme": .string(theme.rawValue)])
                return .applied
            }
        }
    }
#endif
