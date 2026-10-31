// Covers the routes of a command in a real tab (P7 round 1): the built application menu, its keys and the toolbar, over
// useExplorerShortcuts.ts runRendererCommand, App.tsx buildApplicationMenuState and rendererCommandAvailability.ts
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct CommandRoutesTests {
        /// The application menu, built as the app builds it, over a tab of the harness that is never shown.
        @MainActor
        private final class RealMenu {
            let router = MenuCommandRouter()
            let built: BuiltApplicationMenu
            var index: MenuItemIndex?
            var sync: ApplicationMenuSync!
            let tab: MainWindowController

            init(_ harness: ExplorerHarness, _ tab: MainWindowController) {
                self.tab = tab
                built = ApplicationMenuBuilder.build(target: router, options: .init())
                index = MenuItemIndex(built, router: router)
                let window = tab.window
                sync = ApplicationMenuSync(
                    .init(
                        windows: harness.windows, focusedWindow: { window }, menu: { [unowned self] in index },
                        build: {}))
                router.focusedWindow = { window }
                router.beforeValidating = { [unowned self] in sync.readWindowState() }
                router.explorerFor = { [unowned self] in sync.explorerFor($0) }
                router.isTextEditing = { [unowned self] in sync.state(of: $0).textEditing }
                router.performNativeEdit = { selector, window in
                    _ = window.firstResponder?.tryToPerform(selector, with: nil)
                }
                harness.windows.onMenuState = { [unowned self] id, state in sync.setWindowState(windowID: id, state) }
                sync.menuBuilt()
                report()
            }

            func report() { sync.setWindowState(windowID: tab.windowID, tab.menuState) }

            func item(_ id: String) -> NSMenuItem {
                guard let found = built.itemsByID[id] else { preconditionFailure("no item \(id)") }
                return found
            }

            /// Whether the item can be chosen, as the system asks as it opens the menu or matches a key.
            func isEnabled(_ id: String) -> Bool { router.validateMenuItem(item(id)) }

            func choose(_ id: String) { router.choose(itemID: id) }
        }

        private func key(
            _ name: String, _ modifiers: NSEvent.ModifierFlags = [], in tab: MainWindowController
        ) throws -> NSEvent {
            let found = try #require(KeyEvents.key(named: name))
            let window = try #require(tab.window)
            return try #require(KeyEvents.events(found, modifiers: modifiers, window: window).first)
        }

        private func path(_ name: String, _ tab: MainWindowController) throws -> String {
            try #require(tab.content.listed.first { $0.name == name }?.path)
        }

        private func select(_ names: [String], _ tab: MainWindowController) throws {
            tab.content.select(paths: try names.map { try path($0, tab) })
            tab.content.focusList()
        }

        private func spy(_ tab: MainWindowController) -> OpenSpy {
            let spy = OpenSpy()
            tab.opener = spy.opener
            tab.contextMenus.opener = spy.opener
            return spy
        }

        // MARK: Commands with no route

        // F-597: Open in Terminal, Show in Finder and Copy Path, chosen from the menu bar.
        // B-CLIP-010 B-VIEW-233 T-3af241c2 T-6528d794 T-f9a90488
        @Test func terminalFinderAndCopyPathRunFromTheMenu() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            let spy = spy(tab)
            try select(["note.txt"], tab)
            let note = try path("note.txt", tab)
            menu.report()
            menu.choose("showInFinder")
            menu.choose("openInTerminal")
            #expect(await waitUntil { spy.all.count == 2 })
            #expect(spy.all.contains { $0.hasSuffix(note) })
            #expect(spy.all.contains { $0.contains("Terminal") })
            menu.choose("copyPath")
            #expect(await waitUntil { harness.pasteboard.string(forType: .string) == note })
            await harness.close()
        }

        // The toolbar's buttons reach the same commands.
        @Test func theToolbarsTerminalButtonRuns() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let spy = spy(tab)
            try select(["Alpha"], tab)
            tab.perform(.openInTerminal)
            #expect(await waitUntil { spy.all.count == 1 })
            await harness.close()
        }

        // useExplorerShortcuts.ts:1440-1443, 1540-1547: ? from the list and from the tree, and the Help command.
        // B-VIEW-231
        @Test func helpOpensFromTheQuestionMarkInEitherPaneAndFromItsCommand() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            var opened: [HelpTopicID?] = []
            tab.openHelp = { opened.append($0) }
            tab.perform(.openHelp)
            #expect(opened.count == 1)
            tab.perform(.openKeyboardShortcuts)
            #expect(opened.last == .some(.shortcuts))
            tab.content.focusList()
            let question = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                    windowNumber: tab.window?.windowNumber ?? 0, context: nil, characters: "?",
                    charactersIgnoringModifiers: "?", isARepeat: false, keyCode: 44))
            list.table?.keyDown(with: question)
            #expect(opened.count == 3)
            tab.perform(.focusTreePane)
            #expect(tab.focusedPane == .tree)
            tab.window?.firstResponder?.keyDown(with: question)
            #expect(opened.count == 4)
            #expect(tab.sidebarController.model.typeaheadQuery.isEmpty)
            await harness.close()
        }

        // MARK: Dimming

        // App.tsx:1429-1449: every command that can't run is dimmed, from the same state as the toolbar's.
        // B-VIEW-226 T-4851fd44 T-a1688568
        @Test func theMenuDimsWhatCantRun() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            tab.content.select(paths: [])
            tab.content.focusList()
            menu.report()
            for id in ["trashSelection", "renameSelection", "copyPath", "clearClipboard", "showClipboard"] {
                #expect(!menu.isEnabled(id), "\(id)")
            }
            #expect(menu.isEnabled("newTab"))
            try select(["note.txt"], tab)
            menu.report()
            for id in ["trashSelection", "renameSelection", "copyPath"] { #expect(menu.isEnabled(id), "\(id)") }
            await harness.close()
        }

        // The state comes from the window at the moment the menu is asked: a dialog that just came up dims it all.
        // B-VIEW-228 T-fc829ef9
        @Test func theMenuReadsTheWindowWhenAsked() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            try select(["note.txt"], tab)
            menu.report()
            #expect(menu.isEnabled("trashSelection"))
            tab.openLocationSheet()
            #expect(tab.goToBox != nil)
            #expect(!menu.isEnabled("trashSelection"))
            #expect(!menu.isEnabled("newTab"))
            await harness.close()
        }

        // App.tsx:1522-1527: the state goes to the menu whenever the selection changes it.
        // B-TREE-038
        @Test func favoritesFollowTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            let alpha = try path("Alpha", tab)
            tab.sidebarController.toggleFavorite(alpha)
            tab.content.select(paths: [])
            tab.content.focusList()
            menu.report()
            #expect(!menu.item(ApplicationMenu.favoriteAddItemID).isHidden)
            try select(["Alpha"], tab)
            #expect(await waitUntil { menu.item(ApplicationMenu.favoriteAddItemID).isHidden })
            #expect(!menu.item(ApplicationMenu.favoriteRemoveItemID).isHidden)
            await harness.close()
        }

        // T-e8e8e6cd: the menu's items add the selected folder and take it away.
        @Test func theMenuAddsTheSelectedFolderToFavoritesAndTakesItAway() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            let alpha = try path("Alpha", tab)
            let sidebar = tab.sidebarController
            try select(["Alpha"], tab)
            menu.report()
            #expect(!sidebar.isFavorite(alpha))
            #expect(!menu.item(ApplicationMenu.favoriteAddItemID).isHidden)
            #expect(menu.isEnabled(ApplicationMenu.favoriteAddItemID))
            menu.choose(ApplicationMenu.favoriteAddItemID)
            #expect(sidebar.isFavorite(alpha))
            menu.report()
            #expect(await waitUntil { !menu.item(ApplicationMenu.favoriteRemoveItemID).isHidden })
            #expect(menu.item(ApplicationMenu.favoriteAddItemID).isHidden)
            menu.choose(ApplicationMenu.favoriteRemoveItemID)
            #expect(!sidebar.isFavorite(alpha))
            menu.report()
            #expect(await waitUntil { !menu.item(ApplicationMenu.favoriteAddItemID).isHidden })
            await harness.close()
        }

        // App.tsx:1505: the radio shows the view on screen, the search results' own while they show.
        // B-VIEW-003 T-26fc62ad
        @Test func theViewRadioShowsTheViewOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            tab.setSearchViewMode(.icons)
            tab.search.session.engine = FakeSearchEngine()
            tab.search.session.timers = ManualTimers()
            let field = try #require(tab.searchField)
            field.stringValue = "note"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            _ = tab.search.session.submit("note")
            #expect(await waitUntil { tab.search.showsResults })
            #expect(tab.menuState.viewMode == .icons)
            #expect(tab.viewMode != .icons)
            // ExplorerWorkspace.tsx:1527-1532: the » menu's entries too.
            let entry = try #require(tab.explorerToolbar.overflowEntry(.view)?.submenu)
            #expect(entry.items.first { $0.title == "as Icons" }?.state == .on)
            // useExplorerShortcuts.ts:1392, 1398: the order isn't the folder's to change while results show.
            let order = (tab.sortBy, tab.sortDirection, tab.foldersFirst)
            tab.perform(.sortBySize)
            tab.perform(.toggleFoldersFirst)
            #expect(tab.sortBy == order.0 && tab.sortDirection == order.1 && tab.foldersFirst == order.2)
            await harness.close()
        }

        // MARK: Text fields

        // App.tsx:1500, 1513; appMenu.ts resolveApplicationMenuItemStates: while a field has the keyboard Undo and Redo
        // are its own, always on and plainly named, with no file operation to undo.
        // B-CLIP-008 B-CLIP-184 B-SEL-142 T-7b2fe094
        @Test func aFieldsUndoIsItsOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            let field = try #require(tab.searchField)
            #expect(tab.window?.makeFirstResponder(field) == true)
            #expect(tab.isTextFieldEditing)
            menu.report()
            #expect(tab.menuState.textEditing)
            #expect(!menu.item(ApplicationMenu.textUndoItemID).isHidden)
            #expect(menu.item("undo").isHidden)
            #expect(menu.isEnabled(ApplicationMenu.textUndoItemID))
            #expect(menu.isEnabled(ApplicationMenu.textRedoItemID))
            let editor = try #require(tab.window?.firstResponder as? NSTextView)
            #expect(editor.allowsUndo)
            editor.insertText("note", replacementRange: editor.selectedRange())
            editor.breakUndoCoalescing()
            #expect(field.stringValue == "note")
            menu.choose(ApplicationMenu.textUndoItemID)
            #expect(field.stringValue.isEmpty)
            menu.choose(ApplicationMenu.textRedoItemID)
            #expect(field.stringValue == "note")
            // The same through the key, offered as the system offers it: to the window, then to the menu bar.
            let window = try #require(tab.window)
            let undo = try key("z", [.command], in: tab)
            #expect(KeyEvents.performKeyEquivalent(undo, window: window, menu: menu.built.menu))
            #expect(field.stringValue.isEmpty)
            tab.window?.makeFirstResponder(nil)
            await harness.close()
        }

        // useExplorerShortcuts.ts:1089-1098: ⌘↑ and ⌘⌫ stay with a field that has the keyboard: the menu leaves them.
        // B-NAV-218 B-TREE-194 B-VIEW-230 T-9497e5dc T-f573c5d9
        @Test func aFieldKeepsTheKeysItEditsWith() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            try select(["note.txt"], tab)
            let before = tab.folder.path
            tab.content.contentShell.pathBarRow.beginEditing()
            harness.layout(tab)
            #expect(tab.isTextFieldEditing)
            #expect(tab.focusedPane == nil)
            #expect(!tab.canPerform(.trashSelection))
            menu.report()
            let window = try #require(tab.window)
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.string = "/one/two"
            editor.setSelectedRange(NSRange(location: 8, length: 0))
            let up = try key("ArrowUp", [.command], in: tab)
            #expect(KeyEvents.performKeyEquivalent(up, window: window, menu: menu.built.menu))
            #expect(tab.folder.path == before)
            #expect(editor.selectedRange().location == 0)
            editor.setSelectedRange(NSRange(location: 8, length: 0))
            let delete = try key("Backspace", [.command], in: tab)
            #expect(KeyEvents.performKeyEquivalent(delete, window: window, menu: menu.built.menu))
            #expect(editor.string.isEmpty)
            // A click on the item still acts, as it does in the original.
            #expect(menu.isEnabled("goEnclosingFolder"))
            await harness.close()
        }

        // MARK: Keys of the window

        // useExplorerShortcuts.ts:1537-1604: one table serves every pane.
        // B-SEL-115 B-TREE-106 T-16bc48f4
        @Test func theWindowsKeysWorkWithTheTreeFocused() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let start = tab.folder.path
            let alpha = try path("Alpha", tab)
            tab.go(to: URL(fileURLWithPath: alpha))
            #expect(await waitUntil { tab.folder.path == alpha })
            tab.perform(.focusTreePane)
            #expect(tab.focusedPane == .tree)
            // ⌘← and ⌘→ are Back and Forward.
            tab.window?.firstResponder?.keyDown(with: try key("ArrowLeft", [.command], in: tab))
            #expect(await waitUntil { tab.folder.path == start })
            tab.perform(.focusTreePane)
            tab.window?.firstResponder?.keyDown(with: try key("ArrowRight", [.command], in: tab))
            #expect(await waitUntil { tab.folder.path == alpha })
            await harness.close()
        }

        // A key without ⌘ or ⌃ chosen in Settings runs from the tree too, and isn't type-ahead.
        // B-TREE-119 T-47b5d059 T-8767f57b T-c0704916
        @Test func aPlainKeyChosenInSettingsRunsFromTheTree() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            tab.updatePreferences(["shortcutOverrides": .object(["toggleInfoRow": .array([.string("F6")])])])
            #expect(tab.preferences.shortcutOverrides["toggleInfoRow"] == ["F6"])
            tab.perform(.focusTreePane)
            let row = tab.panels.detailRowOpen
            tab.window?.firstResponder?.keyDown(with: try key("F6", in: tab))
            #expect(tab.panels.detailRowOpen != row)
            #expect(tab.sidebarController.model.typeaheadQuery.isEmpty)
            await harness.close()
        }

        // MARK: Quick Look

        // App.tsx:1434: the toolbar's button follows the selection.
        // B-SEL-112
        @Test func quickLookFollowsTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            tab.content.select(paths: [])
            tab.content.focusList()
            #expect(!tab.canPerform(.quickLookSelection))
            try select(["note.txt"], tab)
            #expect(tab.canPerform(.quickLookSelection))
            await harness.close()
        }

        // useExplorerShortcuts.ts:930: Quick Look is on whatever key it has.
        // B-SEL-112 B-VIEW-233 T-3af241c2
        @Test func quickLookGoesWithItsKey() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            var shown: [String] = []
            tab.showQuickLook = { shown.append($0) }
            try select(["note.txt"], tab)
            let window = try #require(tab.window)
            func press(_ name: String) throws {
                let event = try key(name, in: tab)
                if !WindowEventRouting.intercept(event, in: window) { list.table?.keyDown(with: event) }
            }
            try press("Space")
            #expect(shown.count == 1)
            tab.updatePreferences(["shortcutOverrides": .object(["quickLookSelection": .array([.string("F2")])])])
            try press("Space")
            #expect(shown.count == 1)
            try press("F2")
            #expect(shown.count == 2)
            await harness.close()
        }

        // MARK: Opening

        // App.tsx:1439: Open and Edit go by the limit in Settings.
        @Test func theToolbarFollowsTheOpenLimit() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            try select(["Alpha", "Beta"], tab)
            #expect(tab.canPerform(.openSelection))
            tab.updatePreferences(["openItemLimit": .number(1)])
            #expect(tab.preferences.openItemLimit == 1)
            #expect(!tab.canPerform(.openSelection))
            await harness.close()
        }

        // useExplorerShortcuts.ts:566-581: ⌘↓ over the limit says so, whatever the limit is.
        @Test func commandDownOverTheLimitTellsOfIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.updatePreferences(["openItemLimit": .number(1)])
            try select(["Alpha", "Beta"], tab)
            list.table?.keyDown(with: try key("ArrowDown", [.command], in: tab))
            #expect(await waitUntil { tab.frontAlert != nil })
            tab.dialogs.last?.dismiss()
            await harness.close()
        }

        // useExplorerShortcuts.ts:1099-1122: File ▸ Open and ⌘O open; only activation follows "Double-click a file to".
        @Test func fileOpenOpensWhatActivationWouldEdit() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let spy = spy(tab)
            var opened: [String] = []
            tab.openFile = { opened.append($0.path) }
            tab.updatePreferences(["fileActivationAction": .string("edit")])
            #expect(tab.preferences.fileActivationAction == .edit)
            try select(["note.txt"], tab)
            let note = try path("note.txt", tab)
            let menu = RealMenu(harness, tab)
            menu.choose("openSelection")
            #expect(await waitUntil { !opened.isEmpty })
            #expect(opened == [note])
            #expect(!spy.all.contains { $0.hasPrefix("open -a") })
            await harness.close()
        }

        // MARK: What the keys of the write commands take

        /// A row clicked as the press reaches the list, in the folder of a window with the app's file operations.
        private func clicked(
            _ name: String, _ window: WritingWindow, menu: RealMenu
        ) async -> ListProbe {
            let list = ListProbe(tab: window.tab)
            await list.click(name: name)
            #expect(list.selectedNames == [name])
            #expect(list.table?.selectedRowIndexes.map { list.rowNames[$0] } == [name])
            menu.report()
            return list
        }

        // F-290 F-291 F-378 F-550: ⌘⌫ takes the row the click selected and nothing else, and ⌘Z puts it back; also when a
        // new item moved the rows between the click and the key.
        // B-CLIP-184 T-f90496ca
        @Test(.windowlessAlone) func theTrashKeyTakesTheClickedRowAndUndoPutsItBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let menu = RealMenu(window.harness, tab)
            let list = await clicked("note.txt", window, menu: menu)
            try press("Backspace", .command, in: tab, menu: menu)
            #expect(await waitUntil { !window.exists("note.txt") })
            #expect(await waitUntil { !list.rowNames.contains("note.txt") })
            #expect(list.rowNames == ["Alpha", "Beta", "Gamma"])
            let session = window.operations.session(for: try #require(tab.group))
            #expect(await waitUntil { session.card == nil })
            tab.perform(.undo)
            #expect(await waitUntil { window.exists("note.txt") })
            #expect(await waitUntil { list.rowNames.contains("note.txt") })
            #expect(await waitUntil { session.card == nil })

            _ = await clicked("Gamma", window, menu: menu)
            try FileManager.default.createDirectory(
                at: window.folder.appendingPathComponent("Aardvark"), withIntermediateDirectories: false)
            tab.refresh()
            #expect(await waitUntil { list.rowNames.first == "Aardvark" })
            #expect(list.selectedNames == ["Gamma"])
            #expect(list.table?.selectedRowIndexes.map { list.rowNames[$0] } == ["Gamma"])
            menu.report()
            try press("Backspace", .command, in: tab, menu: menu)
            #expect(await waitUntil { !window.exists("Gamma") })
            #expect(window.exists("Aardvark") && window.exists("Beta") && window.exists("note.txt"))
            #expect(await waitUntil { session.card == nil })
            tab.perform(.undo)
            #expect(await waitUntil { window.exists("Gamma") })
            await window.close()
        }

        // F-290: rename, duplicate and move, reached by the same keys, take the clicked row too.
        // T-1a31a754 T-56c85e6b T-d889b78c
        @Test(.windowlessAlone) func theOtherWriteKeysTakeTheClickedRow() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let menu = RealMenu(window.harness, tab)
            _ = await clicked("Beta", window, menu: menu)
            try press("F2", in: tab, menu: menu)
            #expect(tab.content.inlineRename?.path == window.folder.appendingPathComponent("Beta").path)
            tab.content.renameCancelled()
            #expect(await waitUntil { tab.content.inlineRename == nil })

            _ = await clicked("note.txt", window, menu: menu)
            try press("d", .command, in: tab, menu: menu)
            #expect(await waitUntil { window.exists("note copy.txt") })
            #expect(!window.exists("Alpha copy") && !window.exists("Beta copy") && !window.exists("Gamma copy"))
            let session = window.operations.session(for: try #require(tab.group))
            #expect(await waitUntil { session.card == nil })

            _ = await clicked("note.txt", window, menu: menu)
            // The menu's item: a made-up ⇧ chord doesn't match its key (the capture's driver goes by the item too).
            menu.choose("moveSelection")
            let box = try #require(tab.goToBox)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            DialogKeys.type(window.folder.appendingPathComponent("Alpha").path, into: box)
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            #expect(!window.exists("note.txt"))
            #expect(window.exists("note copy.txt") && window.exists("Beta") && window.exists("Gamma"))
            await window.close()
        }

        // T-9e7de3fa: Copy and Cut from the menu take what is selected: the folder on screen is no implicit selection.
        @Test(.windowlessAlone, arguments: ["editCopy", "editCut"])
        func copyAndCutWithNothingSelectedTakeNothing(_ item: String) async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let menu = RealMenu(window.harness, tab)
            tab.content.select(paths: [])
            tab.content.focusList()
            menu.report()
            #expect(tab.selectedPaths.isEmpty)
            menu.choose(item)
            await settle()
            #expect(tab.services.clipboard.contents == .empty)
            #expect(tab.notifications?.toasts.entries.isEmpty != false)
            #expect(window.recorder.shown.isEmpty)
            // With something selected, the same item does take it.
            try select(["note.txt"], tab)
            menu.report()
            menu.choose(item)
            #expect(tab.services.clipboard.contents.sourcePaths == [try path("note.txt", tab)])
            await window.close()
        }

        // T-b55c9910: Select All from the menu with a field editing selects its text: the Go To box's, the path bar's and
        // a name being typed in its row; the files stay as they were.
        @Test(.windowlessAlone, arguments: ["pathBar", "rename", "goTo"])
        func selectAllFromTheMenuStaysWithTheFieldEditing(_ field: String) async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let menu = RealMenu(window.harness, tab)
            let appWindow = try #require(tab.window)
            try select(["note.txt"], tab)
            let note = try path("note.txt", tab)
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            let clipboard = tab.services.clipboard.contents
            switch field {
            case "pathBar": tab.content.contentShell.pathBarRow.beginEditing()
            case "rename": tab.renameSelected()
            default: tab.openLocationSheet()
            }
            window.harness.layout(tab)
            menu.report()
            let editor = try #require(appWindow.firstResponder as? NSTextView)
            editor.string = "typed text"
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            menu.choose("editSelectAll")
            #expect(editor.selectedRange() == NSRange(location: 0, length: 10))
            #expect(tab.content.selection.paths == [note])
            #expect(tab.services.clipboard.contents == clipboard)
            await window.close()
        }

        // MARK: Keys of a command that can't run

        /// The key as the system offers it: to the window, then to the menu bar, then down the responder chain.
        private func press(
            _ name: String, _ modifiers: NSEvent.ModifierFlags = [], in tab: MainWindowController, menu: RealMenu
        ) throws {
            let event = try key(name, modifiers, in: tab)
            let window = try #require(tab.window)
            if !KeyEvents.performKeyEquivalent(event, window: window, menu: menu.built.menu) {
                window.firstResponder?.keyDown(with: event)
            }
        }

        // useExplorerShortcuts.ts:1569-1603: the keys don't go by what dims the menu. A write's key during another write
        // reaches the command, which says why it can't start (useExplorerActions.ts:3576, 3662, 3917, 3093, 4292).
        // B-CLIP-007 B-CLIP-186
        @Test(.windowlessAlone) func theKeysOfWritesSayAnotherIsRunning() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            try select(["note.txt"], tab)
            writes.session(for: try #require(tab.group))
                .applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
            menu.report()
            let keys: [(String, NSEvent.ModifierFlags)] = [
                ("Backspace", .command), ("d", .command), ("m", [.command, .shift]), ("F2", []),
                ("n", [.command, .shift]), ("Backspace", [.command, .shift]),
            ]
            for (name, modifiers) in keys {
                try press(name, modifiers, in: tab, menu: menu)
                #expect(await waitUntil { tab.frontAlert != nil }, "\(name) \(modifiers)")
                tab.dialogs.last?.dismiss()
                #expect(await waitUntil { tab.frontAlert == nil })
            }
            // shortcuts.ts:968-972: a fixed command is not in the window's table, so ⌘Z and ⇧⌘Z are the menu's alone: its
            // dimmed item keeps them.
            for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
                try press("z", modifiers, in: tab, menu: menu)
                try? await Task.sleep(for: .milliseconds(100))
                #expect(tab.frontAlert == nil)
            }
            await harness.close()
        }

        // useExplorerActions.ts:3329-3331, 3353-3358: ⌘O and ⌘⇧E over "Ask before opening more than" say so; only the
        // toolbar's button and the menu's item dim.
        @Test(.windowlessAlone) func openAndEditKeysOverTheLimitTellOfIt() async throws {
            let harness = try ExplorerHarness.windowless()
            try Data().write(to: harness.folder.appending("second.txt"))
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            tab.updatePreferences(["openItemLimit": .number(1)])
            try select(["Alpha", "Beta"], tab)
            menu.report()
            #expect(!menu.isEnabled("openSelection"))
            try press("o", .command, in: tab, menu: menu)
            #expect(await waitUntil { tab.frontAlert != nil })
            tab.dialogs.last?.dismiss()
            #expect(await waitUntil { tab.frontAlert == nil })
            try select(["note.txt", "second.txt"], tab)
            menu.report()
            #expect(!menu.isEnabled("editSelection"))
            try press("e", [.command, .shift], in: tab, menu: menu)
            #expect(await waitUntil { tab.frontAlert != nil })
            tab.dialogs.last?.dismiss()
            await harness.close()
        }

        // useExplorerActions.ts:3353-3358 `editPaths`: anything but files among the items and it does nothing at all, over
        // the limit too.
        // T-94710962
        @Test(.windowlessAlone) func theEditKeyLeavesFoldersAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            let spy = spy(tab)
            tab.updatePreferences(["openItemLimit": .number(1)])
            try select(["Alpha", "Beta"], tab)
            menu.report()
            try press("e", [.command, .shift], in: tab, menu: menu)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(tab.frontAlert == nil)
            #expect(spy.all.isEmpty)
            await harness.close()
        }

        // useExplorerActions.ts:3379-3388: ⌘D on search results from several folders says why.
        // B-SRCH-143 B-VIEW-203 T-a39af101
        @Test(.windowlessAlone) func theDuplicateKeyOnResultsOfSeveralFoldersTellsOfIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, _) = try await harness.openList()
            let engine = FakeSearchEngine()
            engine.finds = { _ in (["Alpha/one.txt", "Beta/two.txt"], false, false) }
            tab.search.session.engine = engine
            tab.search.session.timers = ManualTimers()
            let field = try #require(tab.searchField)
            field.stringValue = "t"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            _ = tab.search.session.submit("t")
            #expect(await waitUntil { tab.search.showsResults && tab.content.listed.count == 2 })
            let menu = RealMenu(harness, tab)
            tab.content.select(paths: tab.content.listed.map(\.path))
            tab.content.focusList()
            menu.report()
            #expect(!menu.isEnabled("duplicateSelection"))
            try press("d", .command, in: tab, menu: menu)
            #expect(tab.notifications?.toasts.entries.map(\.title) == ["Duplicate items from one folder at a time"])
            #expect(tab.frontAlert == nil)
            await harness.close()
        }

        // useExplorerActions.ts:3081-3087: ⌘⇧⌫ asks to empty the Trash, whatever is known of what is in it.
        // T-e5169248
        @Test(.windowlessAlone) func theEmptyTrashKeyAsksOfAnEmptyTrash() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            var asked: [String] = []
            writes.dialogs.confirm = { question, _ in
                asked.append(question.title)
                return false
            }
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            tab.trashIsEmpty = true
            menu.report()
            #expect(!menu.isEnabled("emptyTrash"))
            try press("Backspace", [.command, .shift], in: tab, menu: menu)
            #expect(await waitUntil { asked == [LocalWriteRules.emptyTrashQuestion.title] })
            await harness.close()
        }

        // `canHandleRawExplorerShortcut`: what the tree doesn't take stays dropped; the dimmed item keeps the key.
        // T-81bf2f83
        @Test(.windowlessAlone) func aKeyTheTreeDoesNotTakeStaysDropped() async throws {
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, _) = try await harness.openList()
            let menu = RealMenu(harness, tab)
            writes.session(for: try #require(tab.group))
                .applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
            tab.perform(.focusTreePane)
            menu.report()
            try press("Backspace", .command, in: tab, menu: menu)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(tab.frontAlert == nil)
            await harness.close()
        }

        // `startDuplicatePaths`: nothing is made in the Trash, which comes before the busy notice.
        @Test func nothingIsDuplicatedInTheTrash() {
            let home = "/Users/me"
            #expect(
                MainWindowController.duplicatesInTrash(["/Users/me/.Trash/a"], destination: "/x", homePath: home))
            #expect(MainWindowController.duplicatesInTrash(["/x/a"], destination: "/Users/me/.Trash", homePath: home))
            #expect(!MainWindowController.duplicatesInTrash(["/x/a"], destination: "/x", homePath: home))
        }
    }
}
