#if DEBUG
    import FTFoundation

    /// The `prefs` key of the Info panel.
    @MainActor
    enum AutomationInfoPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            func flag(_ key: PreferenceKey, _ apply: @escaping @MainActor (MainWindowController, Bool) -> Void) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key.rawValue) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    apply(controller, on)
                    return .applied
                }
            }
            flag(.propertiesOpen) { controller, on in controller.updatePanels { $0.propertiesOpen = on } }
        }
    }
#endif
