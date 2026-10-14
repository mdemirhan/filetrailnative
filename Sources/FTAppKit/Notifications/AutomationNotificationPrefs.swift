// Port of the notifications preference of apps/desktop/src/shared/appPreferences.ts, as capture scenarios set it
// (`prefs` steps)
#if DEBUG
    import FTFoundation

    /// The `prefs` key of the notifications: "Show notifications".
    @MainActor
    enum AutomationNotificationPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            AutomationPrefs.register("notificationsEnabled") { value, context in
                guard let controller = context.controller else { return .unsupported("notificationsEnabled") }
                guard case .bool(let enabled) = value else { return .failed("notificationsEnabled \(value)") }
                controller.updatePreferences(["notificationsEnabled": .bool(enabled)])
                controller.notificationsSettingChanged()
                return .applied
            }
        }
    }
#endif
