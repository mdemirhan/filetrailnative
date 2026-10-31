// Port of the "Mark copied and cut items" preference of apps/desktop/src/shared/appPreferences.ts, as capture scenarios
// set it (`prefs` steps)
#if DEBUG
    import FTFoundation

    /// The `prefs` key of the clipboard's marks.
    @MainActor
    enum AutomationClipboardPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            AutomationPrefs.register("markClipboardItems") { value, context in
                guard let controller = context.controller else { return .unsupported("markClipboardItems") }
                guard case .bool(let enabled) = value else { return .failed("markClipboardItems \(value)") }
                controller.updatePreferences(["markClipboardItems": .bool(enabled)])
                controller.clipboardMarksChanged()
                return .applied
            }
        }
    }
#endif
