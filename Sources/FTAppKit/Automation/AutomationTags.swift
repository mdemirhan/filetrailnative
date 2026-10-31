// Port of the element names of tools/capture/elements.json; no TypeScript source.
#if DEBUG
    import AppKit

    /// Names the views AppKit makes itself (title bar, toolbar items), which the app's code can't
    /// name where it creates them. The app's own views are named where they are made
    /// (`accessibilityIdentifier`, see `tools/capture/elements.json`).
    @MainActor
    enum AutomationTags {
        static let statusBar = "statusBar"

        static func apply(in window: NSWindow) {
            // The system's customizing sheet has no view of ours: its content is the panel the scenarios wait for.
            if window.sheetParent?.toolbar?.customizationPaletteIsRunning == true {
                window.contentView?.setAccessibilityIdentifier("toolbar.customize")
            }
            guard let frameView = window.contentView?.superview else { return }
            for view in Views.all(NSView.self, in: frameView) where view.accessibilityIdentifier().isEmpty {
                if let id = systemName(of: view) { view.setAccessibilityIdentifier(id) }
            }
        }

        /// AppKit's box around a toolbar item answers with its button's identifier: the button is the element.
        static func mirrorsItsItem(_ view: NSView) -> Bool {
            String(describing: type(of: view)) == "NSToolbarItemViewer"
        }

        /// AppKit's private view classes, matched by name: they have no public type to test against.
        static func systemName(of view: NSView) -> String? {
            // The Shortcuts page's card is a plain view of its group, the same card as the original's `.settings-card`.
            if let group = view.superview as? ShortcutGroupView, group.card === view { return "settings.card" }
            switch String(describing: type(of: view)) {
            case "NSToolbarView": return "toolbar"
            case "_NSToolbarTitleField": return "toolbar.title"
            case "NSToolbarItemGroupPickerView": return "toolbar.viewSwitch"
            case "NSToolbarClippedItemsIndicator": return "toolbar.overflow"
            // A tab of the window's native tab bar (P4-02).
            case "NSTabButton": return "tabBar.tab"
            case "NSToolbarButton":
                switch (view as? NSButton)?.image?.accessibilityDescription {
                case "Back": return "toolbar.back"
                case "Forward": return "toolbar.forward"
                default: return nil
                }
            default: return nil
            }
        }
    }
#endif
