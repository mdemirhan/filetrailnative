// Port of the menu steps of tools/capture/electron/driver.ts (the original's Menu item clicks); no TypeScript source.
#if DEBUG
    import AppKit

    /// Choosing menu items by their titles, for the `menu` and `contextMenu` steps. Actions go to the
    /// window the step acts on, not to whichever window is key: a run started from a terminal may leave
    /// the app inactive.
    @MainActor
    enum AutomationMenus {
        /// The item at `path` of the menu bar (`["File", "New Folder"]`), carried out.
        static func choose(_ path: [String], window: NSWindow) -> AutomationRunner.Outcome {
            guard let bar = NSApp.mainMenu else { return .init(.failed, "no menu bar") }
            switch find(path, in: bar, appMenuFirst: true) {
            case .failure(let failure): return .init(.failed, failure.message)
            case .success(let (menu, item)): return perform(item, in: menu, window: window)
            }
        }

        /// The item at `path` below `menu`. Titles match exactly, or without a trailing ellipsis.
        static func find(
            _ path: [String], in menu: NSMenu, appMenuFirst: Bool = false
        ) -> Result<(NSMenu, NSMenuItem), AutomationRunner.Failure> {
            var menu = menu
            for (depth, title) in path.enumerated() {
                menu.delegate?.menuNeedsUpdate?(menu)
                var item = menu.items.first { matches($0, title) }
                // The application menu's title is the app's name, whatever the scenario calls it.
                if item == nil, depth == 0, appMenuFirst, title == "File Trail" { item = menu.items.first }
                guard let item, !item.isHidden else {
                    return .failure(.init("no menu item \(path[...depth].joined(separator: " › "))"))
                }
                if depth == path.count - 1 { return .success((menu, item)) }
                guard let submenu = item.submenu else {
                    return .failure(.init("\(path[...depth].joined(separator: " › ")) has no submenu"))
                }
                menu = submenu
            }
            return .failure(.init("empty menu path"))
        }

        private static func matches(_ item: NSMenuItem, _ title: String) -> Bool {
            func plain(_ text: String) -> String {
                var text = text
                while text.hasSuffix("…") || text.hasSuffix(".") { text.removeLast() }
                return text
            }
            return item.title == title || plain(item.title) == plain(title)
        }

        /// Validates the item as AppKit would and sends its action.
        static func perform(_ item: NSMenuItem, in menu: NSMenu, window: NSWindow) -> AutomationRunner.Outcome {
            guard let action = item.action else {
                return .init(.failed, "“\(item.title)” has no action")
            }
            guard let target = target(for: action, explicit: item.target, window: window) else {
                return .init(.failed, "nothing takes “\(item.title)” (\(NSStringFromSelector(action)))")
            }
            if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
                return .init(.failed, "“\(item.title)” is disabled")
            }
            guard NSApp.sendAction(action, to: target, from: item) else {
                return .init(.failed, "“\(item.title)” was not carried out")
            }
            menu.delegate?.menuDidClose?(menu)
            return .init(.ok)
        }

        /// Where an action goes: the item's own target, else the window's responder chain, the window's
        /// delegate, the app and the app delegate (AppKit's order for the key window).
        static func target(for action: Selector, explicit: AnyObject?, window: NSWindow) -> AnyObject? {
            if let explicit { return explicit }
            var responder: NSResponder? = window.firstResponder ?? window
            while let candidate = responder {
                if candidate.responds(to: action) { return candidate }
                responder = candidate.nextResponder
            }
            let others: [AnyObject?] = [window, window.delegate, window.windowController, NSApp, NSApp.delegate]
            for case let candidate? in others where candidate.responds(to: action) { return candidate }
            return nil
        }
    }
#endif
