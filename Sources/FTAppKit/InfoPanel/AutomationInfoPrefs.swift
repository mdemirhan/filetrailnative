// Port of the preference keys propertiesOpen, detailRowOpen and autoCalculateFolderSizes of apps/desktop/src/shared/appPreferences.ts,
// as capture scenarios set them (`prefs` steps)
#if DEBUG
    import FTFoundation

    /// The `prefs` keys of the Info panel and the Info Row.
    @MainActor
    enum AutomationInfoPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            func flag(_ key: String, _ apply: @escaping @MainActor (MainWindowController, Bool) -> Void) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key) }
                    apply(controller, on)
                    return .applied
                }
            }
            flag("propertiesOpen") { controller, on in controller.updatePanels { $0.propertiesOpen = on } }
            flag("detailRowOpen") { controller, on in controller.updatePanels { $0.detailRowOpen = on } }
            flag("autoCalculateFolderSizes") { controller, on in
                controller.updatePreferences(["autoCalculateFolderSizes": .bool(on)])
            }
        }
    }
#endif
