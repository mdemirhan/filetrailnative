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
            guard let frameView = window.contentView?.superview else { return }
            for view in Views.all(NSView.self, in: frameView) where view.accessibilityIdentifier().isEmpty {
                if let id = systemName(of: view) { view.setAccessibilityIdentifier(id) }
            }
        }

        /// AppKit's private view classes, matched by name: they have no public type to test against.
        static func systemName(of view: NSView) -> String? {
            switch String(describing: type(of: view)) {
            case "NSToolbarView": return "toolbar"
            case "_NSToolbarTitleField": return "toolbar.title"
            case "NSToolbarItemGroupPickerView": return "toolbar.viewSwitch"
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
