#if DEBUG
    import AppKit
    import FTFoundation

    /// What a scenario's `prefs` step does here. Each preference has a handler; the code that
    /// builds a preference registers one (`AutomationPrefs.register`). A key with no handler yet is
    /// reported as unsupported, key by key, and the run goes on.
    @MainActor
    enum AutomationPrefs {
        enum Result: Equatable {
            case applied
            /// This app can't apply the value yet; the text says what.
            case unsupported(String)
            /// The key or value is not one the preferences have.
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

        private static var handlers: [PreferenceKey: Handler] = defaultHandlers

        /// Registers (or replaces) the handler of a preference key.
        static func register(_ key: PreferenceKey, _ handler: @escaping Handler) {
            handlers[key] = handler
        }

        static func hasHandler(_ key: PreferenceKey) -> Bool { handlers[key] != nil }

        /// Takes back a handler registered for a while (a test's).
        static func unregister(_ key: PreferenceKey) {
            handlers[key] = defaultHandlers[key]
        }

        /// Sets the preference `key` of the window's to `value`. Every key goes by its name (`PreferenceKey`).
        static func set(_ key: PreferenceKey, _ value: Scenario.PrefValue, on controller: MainWindowController) {
            let read = read(key, value)
            controller.updatePreferences { $0.take(key, from: read) }
        }

        /// The defaults with `value` for `key`, read as the file's reader reads it: a value that isn't valid takes the
        /// key's default.
        static func read(_ key: PreferenceKey, _ value: Scenario.PrefValue) -> AppPreferences {
            PreferencesSanitizer.sanitize(.object([key.rawValue: node(value)]), defaults: .defaults())
        }

        /// Applies a `prefs` step: ok when every key took, partial listing the keys this app can't set
        /// yet, failed for a key or value the preferences don't have.
        static func apply(_ prefs: [String: Scenario.PrefValue], context: Context) -> AutomationRunner.Outcome {
            var unsupported: [String] = []
            var failed: [String] = []
            for name in prefs.keys.sorted() {
                guard let value = prefs[name] else { continue }
                guard let key = PreferenceKey(rawValue: name) else {
                    failed.append("\(name) is not a preference")
                    continue
                }
                guard let handler = handlers[key] else {
                    // The keys the whole app shares with no handler of their own go out as Settings sends them.
                    if let controller = context.controller, !key.isWindowSessionKey {
                        set(key, value, on: controller)
                    } else {
                        unsupported.append(name)
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

        /// The handlers the runner starts with.
        private static let defaultHandlers: [PreferenceKey: Handler] = [
            .theme: { value, _ in
                switch value.string {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "auto": NSApp.appearance = nil
                default: return .failed("theme \(describe(value))")
                }
                return .applied
            },
            .viewMode: { value, context in
                guard let controller = context.controller else { return .unsupported("viewMode outside an explorer") }
                switch value.string {
                case "icons": controller.showAsIcons(nil)
                case "details": controller.showAsList(nil)
                case "list": controller.perform(.viewAsList)
                default: return .failed("viewMode \(describe(value))")
                }
                return .applied
            },
            .sortBy: { value, context in
                guard let key = value.string else { return .failed("sortBy \(describe(value))") }
                guard let controller = context.controller else { return .unsupported("sortBy outside an explorer") }
                let ascending = (context.prefs["sortDirection"]?.string ?? "asc") != "desc"
                return AutomationCommands.sort(
                    by: key, ascending: ascending, controller: controller, window: context.window)
                    ? .applied : .unsupported("sortBy \(key)")
            },
            .sortDirection: { value, context in
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
            .density: { value, _ in
                switch value.string {
                case "standard": .applied
                case "finder": .unsupported("density finder")
                default: .failed("density \(describe(value))")
                }
            },
            .accent: { value, _ in
                // Only the system accent color applies here.
                value.string?.lowercased() == "#007aff" ? .applied : .unsupported("accent \(describe(value))")
            },
            .favoritesPlacement: { value, _ in
                // Only the separate layout applies here: Favorites and Locations lists.
                value.string == "separate" ? .applied : .unsupported("favoritesPlacement \(describe(value))")
            },
        ]
    }
#endif
