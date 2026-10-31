// Port of apps/desktop/src/shared/rendererCommands.ts (the command ids), sent to the window as the driver sends them.
#if DEBUG
    import AppKit
    import FTFoundation

    /// Runs a scenario's `command` step. Ids are the original's renderer command types
    /// (the Electron app's command list).
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

        /// The zoom commands, which this app leaves to the system (DEVIATIONS D-005).
        static let leftToTheSystem: Set<String> = ["zoomIn", "zoomOut", "resetZoom"]

        /// The ids `run` carries out: every command of the original but the zoom ones.
        static let supported: Set<String> = all.subtracting(leftToTheSystem)

        /// Carries out a command as the original's driver sends it (`filetrail:command` to the window): through the
        /// window's own command handler, as the menu bar reaches it. Help and Keyboard Shortcuts open the Help window,
        /// as the menu does.
        static func run(_ id: String, controller: MainWindowController, window: NSWindow) -> AutomationRunner.Outcome {
            guard all.contains(id) else { return .init(.failed, "unknown command \(id)") }
            guard supported.contains(id), let command = RendererCommand(rawValue: id) else {
                return .init(.unsupported, "\(id) is left to the system here (DEVIATIONS D-005)")
            }
            switch command {
            case .openHelp, .openKeyboardShortcuts:
                guard let pages = (NSApp.delegate as? AppDelegate)?.pageWindows else {
                    return .init(.failed, "no Help window")
                }
                pages.openHelp(topic: command == .openKeyboardShortcuts ? .shortcuts : nil)
            default:
                // A text field with the keyboard does Cut, Copy, Paste, Select All and Undo itself. The window's
                // command sends those to the key window, which a run started from a terminal may not have: here they
                // go to the field's editor, and up its responder chain to the window's undo manager.
                if let selector = MenuCommandRouter.nativeEditSelector(command), controller.isTextFieldEditing,
                    let editor = window.firstResponder
                {
                    guard editor.tryToPerform(selector, with: nil) else {
                        return .init(.failed, "the field took no \(id)")
                    }
                    return .init(.ok)
                }
                // Select All outside a field is the focused pane's (`selectAllContentEntries` with the list focused).
                // The window's command sends it to the key window, so here it goes up this window's responder chain.
                if command == .editSelectAll, !controller.isDialogOpen, let responder = window.firstResponder {
                    _ = responder.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil)
                    return .init(.ok)
                }
                controller.perform(command)
            }
            return .init(.ok)
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
