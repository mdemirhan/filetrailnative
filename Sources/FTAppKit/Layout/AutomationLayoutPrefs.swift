#if DEBUG
    import AppKit
    import FTFoundation

    /// The `prefs` keys of the window's layout and toolbar: which panels are open and how wide, the toolbar's items,
    /// Folders First, hidden files, the theme and the accent.
    @MainActor
    enum AutomationLayoutPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            func panel(_ key: PreferenceKey, _ apply: @escaping (inout TabGroupSession.Panels, Bool) -> Void) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key.rawValue) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    controller.updatePanels { apply(&$0, on) }
                    return .applied
                }
            }
            panel(.folderTreeOpen) { $0.folderTreeOpen = $1 }
            panel(.propertiesOpen) { $0.propertiesOpen = $1 }
            panel(.detailRowOpen) { $0.detailRowOpen = $1 }
            func width(_ key: PreferenceKey, _ apply: @escaping (inout TabGroupSession.Panels, Int) -> Void) {
                AutomationPrefs.register(key) { value, context in
                    guard let number = value.number else { return .failed("\(key.rawValue) is not a number") }
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    controller.updatePanels { apply(&$0, Int(number)) }
                    return .applied
                }
            }
            width(.treeWidth) {
                $0.treeWidth = AppPreferenceLimits.clampPaneWidth(Double($1), AppPreferenceLimits.treeWidthRange)
            }
            width(.inspectorWidth) {
                $0.inspectorWidth = AppPreferenceLimits.clampPaneWidth(
                    Double($1), AppPreferenceLimits.inspectorWidthRange)
            }
            AutomationPrefs.register(.topToolbarItems) { value, context in
                guard case .array(let entries) = value else { return .failed("topToolbarItems is not a list") }
                guard let controller = context.controller else {
                    return .unsupported("topToolbarItems")
                }
                let items = entries.compactMap(\.string).map { Scenario.PrefValue.string($0) }
                AutomationPrefs.set(.topToolbarItems, .array(items), on: controller)
                return .applied
            }
            func toggle(
                _ key: PreferenceKey, _ command: AppCommand, _ current: @escaping (ExplorerViewState) -> Bool
            ) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key.rawValue) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    if current(controller.viewState) != on { controller.perform(command) }
                    return .applied
                }
            }
            toggle(.foldersFirst, .toggleFoldersFirst) { $0.foldersFirst }
            toggle(.includeHidden, .toggleHiddenFiles) { $0.includeHidden }
            // The accent is stored with the other preferences, as Settings stores it: a theme set afterwards takes the
            // look from the stored preferences, accent included.
            AutomationPrefs.register(.accent) { value, context in
                guard let accent = value.string.flatMap(AppPreferenceLimits.normalizeAccentColor) else {
                    return .failed("accent \(value.string ?? "?")")
                }
                AppearanceModel.shared.apply(accent: accent)
                context.controller?.updatePreferences { $0.accent = accent }
                return .applied
            }
            AutomationPrefs.register(.theme) { value, context in
                guard let name = value.string, let theme = ThemePreference(rawValue: name) else {
                    return .failed("theme \(value.string ?? "?")")
                }
                switch theme {
                case .light: NSApp.appearance = NSAppearance(named: .aqua)
                case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                case .auto: NSApp.appearance = nil
                }
                context.controller?.updatePreferences { $0.theme = theme }
                return .applied
            }
        }
    }
#endif
