// Port of apps/desktop/src/shared/rendererCommands.ts (the command ids), mapped to what the spike has.
#if DEBUG
    import AppKit
    import FTFoundation

    /// Runs a scenario's `command` step. Ids are the original's renderer command types
    /// (`docs/port/inventory/app-shell-and-tests.md` §1); the ones the spike has no counterpart for are
    /// reported as unsupported.
    @MainActor
    enum AutomationCommands {
        /// Every command id the original has.
        static let all: Set<String> = [
            "undo", "redo", "editCut", "editCopy", "editPaste", "editSelectAll", "focusFileSearch", "openSelection",
            "editSelection", "openLocationSheet", "openSettings", "zoomIn", "zoomOut", "resetZoom", "openInTerminal",
            "moveSelection", "renameSelection", "duplicateSelection", "newFolder", "trashSelection", "emptyTrash",
            "ejectVolume", "copySelection", "cutSelection", "pasteSelection", "copyPath", "showClipboard",
            "clearClipboard", "refreshOrApplySearchSort", "toggleFolderTree", "toggleInfoPanel", "toggleInfoRow",
            "customizeToolbar", "goHomeRootTree", "goDocuments", "goDesktop", "goDownloads", "goLibrary",
            "goMacintoshHD", "goApplications", "goTrash", "rootTreeAtSelection", "newWindow", "newTab",
            "reopenClosedTab", "closeTab", "selectNextTab", "selectPreviousTab", "openSelectionInNewTab",
            "openSelectionInNewWindow", "moveTabToNewWindow", "mergeAllWindows", "quickLookSelection",
            "calculateSize", "revealInFolder", "toggleFavorite", "showInFinder", "showLastSearchResults",
            "viewAsIcons", "viewAsList", "viewAsDetails", "sortByName", "sortByModified", "sortBySize", "sortByKind",
            "toggleFoldersFirst", "toggleHiddenFiles", "goBack", "goForward", "goEnclosingFolder", "focusTreePane",
            "focusContentPane", "openHelp", "openKeyboardShortcuts",
        ]

        /// The ids `run` carries out.
        static let supported: Set<String> = [
            "goBack", "goForward", "goEnclosingFolder", "openSelection", "viewAsIcons", "viewAsDetails", "newTab",
            "toggleFolderTree", "toggleInfoPanel", "toggleInfoRow", "toggleFoldersFirst", "toggleHiddenFiles",
            "customizeToolbar", "viewAsList", "refreshOrApplySearchSort", "editSelectAll", "focusFileSearch",
            "focusContentPane", "focusTreePane", "rootTreeAtSelection", "toggleFavorite", "ejectVolume",
            "sortByName", "sortByModified", "sortBySize", "sortByKind", "goHomeRootTree", "goDocuments",
            "goDesktop", "goDownloads", "goLibrary", "goMacintoshHD", "goApplications", "goTrash", "newWindow",
            "reopenClosedTab", "closeTab", "selectNextTab", "selectPreviousTab", "openSelectionInNewTab",
            "openSelectionInNewWindow", "moveTabToNewWindow", "mergeAllWindows", "calculateSize",
        ]

        static func run(_ id: String, controller: MainWindowController, window: NSWindow) -> AutomationRunner.Outcome {
            guard all.contains(id) else { return .init(.failed, "unknown command \(id)") }
            switch id {
            case "goBack": controller.goBack(nil)
            case "goForward": controller.goForward(nil)
            case "goEnclosingFolder": controller.goToEnclosingFolder(nil)
            case "openSelection": controller.openSelection(nil)
            case "viewAsIcons": controller.showAsIcons(nil)
            case "viewAsDetails": controller.showAsList(nil)
            case "newTab": controller.newWindowForTab(nil)
            case "toggleFolderTree", "toggleInfoPanel", "toggleInfoRow", "toggleFoldersFirst", "toggleHiddenFiles",
                "customizeToolbar", "viewAsList", "refreshOrApplySearchSort":
                // The window's own commands (P5-01).
                guard let command = RendererCommand(rawValue: id) else { return .init(.failed, "no command \(id)") }
                controller.perform(command)
            case "editSelectAll":
                guard let responder = window.firstResponder,
                    responder.responds(to: #selector(NSResponder.selectAll(_:)))
                else { return .init(.failed, "nothing to select in") }
                responder.perform(#selector(NSResponder.selectAll(_:)), with: nil)
            case "focusFileSearch":
                guard let field = Views.first(NSSearchField.self, in: window.contentView?.superview) else {
                    return .init(.failed, "no search field")
                }
                window.makeFirstResponder(field)
            case "focusContentPane":
                let pane: NSView? =
                    Views.folderTable(in: window) ?? Views.first(NSCollectionView.self, in: window.contentView)
                guard let pane else { return .init(.failed, "no folder view") }
                window.makeFirstResponder(pane)
            case "focusTreePane", "rootTreeAtSelection", "toggleFavorite", "ejectVolume":
                // The sidebar's commands (P5-02).
                guard let command = RendererCommand(rawValue: id) else { return .init(.failed, "no command \(id)") }
                controller.perform(command)
            case "sortByName", "sortByModified", "sortBySize", "sortByKind":
                let key = String(id.dropFirst("sortBy".count)).lowercased()
                // Choosing the field sorted by again reverses the direction, as the original's Sort menu does.
                let current = currentSort(in: window)
                // Size and Date Modified sort descending first, as the original's Sort menu does.
                let first = !(key == "size" || key == "modified")
                let ascending = current?.key == key ? !(current?.ascending ?? first) : first
                guard sort(by: key, ascending: ascending, controller: controller, window: window) else {
                    return .init(.failed, "could not sort by \(key)")
                }
            case "goHomeRootTree", "goMacintoshHD", "goTrash":
                // Home roots the tree; Macintosh HD and the Trash act as their Locations rows (P5-02).
                guard let command = RendererCommand(rawValue: id) else { return .init(.failed, "no command \(id)") }
                controller.perform(command)
            case "goDocuments", "goDesktop", "goDownloads", "goLibrary", "goApplications":
                guard let url = place(id) else { return .init(.failed, "no folder for \(id)") }
                controller.go(to: url)
            case "newWindow", "reopenClosedTab", "closeTab", "selectNextTab", "selectPreviousTab",
                "openSelectionInNewTab", "openSelectionInNewWindow", "moveTabToNewWindow", "mergeAllWindows",
                "calculateSize":
                // The window and tab commands, as the menu sends them (P4-02).
                guard let command = RendererCommand(rawValue: id) else { return .init(.failed, "no command \(id)") }
                controller.perform(command)
            default:
                return .init(.unsupported, "the spike has no \(id)")
            }
            return .init(.ok)
        }

        private static func place(_ id: String) -> URL? {
            let fm = FileManager.default
            switch id {
            case "goHomeRootTree": return fm.homeDirectoryForCurrentUser
            case "goDocuments": return fm.urls(for: .documentDirectory, in: .userDomainMask).first
            case "goDesktop": return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            case "goDownloads": return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            case "goLibrary": return fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            case "goMacintoshHD": return URL(fileURLWithPath: "/")
            case "goApplications": return fm.urls(for: .applicationDirectory, in: .localDomainMask).first
            case "goTrash":
                return try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            default: return nil
            }
        }

        private static func currentSort(in window: NSWindow) -> (key: String, ascending: Bool)? {
            guard let sort = Views.folderTable(in: window)?.sortDescriptors.first, let key = sort.key else {
                return nil
            }
            return (key, sort.ascending)
        }

        /// Sorts through the List view's column headers, as a click on one does. In the Icon view the List
        /// view is shown for a moment, since the sort lives with it in the spike.
        static func sort(by key: String, ascending: Bool, controller: MainWindowController, window: NSWindow) -> Bool {
            guard ["name", "modified", "size", "kind"].contains(key) else { return false }
            let wasIcons = Views.folderTable(in: window) == nil
            if wasIcons { controller.showAsList(nil) }
            defer { if wasIcons { controller.showAsIcons(nil) } }
            guard let table = Views.folderTable(in: window) else { return false }
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            return true
        }
    }
#endif
