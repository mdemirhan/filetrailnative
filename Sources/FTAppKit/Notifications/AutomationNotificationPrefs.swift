#if DEBUG
    import FTFoundation

    /// The `prefs` key of the notifications: "Show notifications".
    @MainActor
    enum AutomationNotificationPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            AutomationPrefs.register(.notificationsEnabled) { value, context in
                guard let controller = context.controller else { return .unsupported("notificationsEnabled") }
                guard case .bool(let enabled) = value else { return .failed("notificationsEnabled \(value)") }
                controller.updatePreferences { $0.notificationsEnabled = enabled }
                controller.notificationsSettingChanged()
                return .applied
            }
        }
    }
#endif
