import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TwoPanesTests {
        /// The real path of `name` in the harness's folder: what listings and the tree call it.
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// The pane has read its folder, and what follows in the sidebar has been told.
        private func arrived(_ pane: BrowserPane) async {
            #expect(await waitUntil { pane.loaded && pane.hasShownFolder && !pane.isNavigating })
            await settle()
        }

        private func twoPanes(_ harness: ExplorerHarness, right: String? = nil) async throws -> (
            MainWindowController, BrowserPane, BrowserPane
        ) {
            let tab = try await harness.open()
            let left = tab.activePane
            let second = tab.openSecondPane(at: right.map { real(harness, $0) })
            await arrived(second)
            harness.layout(tab)
            return (tab, left, second)
        }

        @Test func twoPanesOpensTheSecondPaneBesideTheFirstOnItsFolderAndKeepsTheFirstActive() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            #expect(!tab.showsTwoPanes)
            #expect(!tab.canPerform(.switchToOtherPane))

            tab.perform(.toggleTwoPanes)
            let second = try #require(tab.otherPane)
            await arrived(second)
            harness.layout(tab)

            #expect(tab.panes.count == 2)
            #expect(tab.activePaneIndex == 0)
            #expect(second.shownFolderPath == tab.shownFolderPath)
            #expect(tab.workspace.showsTwoPanes)
            #expect(tab.workspace.secondCell.content === second.content.view)
            #expect(tab.workspace.secondStatusCell.content === second.content.contentShell.pathBarRow)
            #expect(tab.workspace.secondCell.frame.width >= PaneSplit.minimumPaneWidth)
            #expect(tab.window?.minSize.width ?? 0 > MainWindowController.minimumSize.width)
            #expect(tab.canPerform(.switchToOtherPane))
            #expect(tab.menuState.twoPanesShown)
            let name = (tab.shownFolderPath as NSString).lastPathComponent
            #expect(tab.twoPaneLabel == "\(name) | \(name)")
            #expect(tab.window?.tab.title == "\(name) | \(name)")
        }

        @Test func eachPaneOpensFoldersInItsOwnHistoryAndTheToolbarAndTitleFollowTheActiveOne() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha")
            #expect(right.shownFolderPath == real(harness, "Alpha"))
            #expect(left.shownFolderPath == real(harness))

            await right.navigate(to: URL(fileURLWithPath: real(harness, "Alpha/Inner")))
            #expect(right.navigationHistory.paths == [real(harness, "Alpha"), real(harness, "Alpha/Inner")])
            #expect(left.navigationHistory.paths == [real(harness)])
            // The tab reads the active pane: the left one still.
            #expect(tab.shownFolderPath == real(harness))
            #expect(!tab.canGoBack)

            tab.focusPane(right)
            #expect(tab.activePane === right)
            #expect(tab.workspace.activePane == 1)
            #expect(tab.shownFolderPath == real(harness, "Alpha/Inner"))
            #expect(tab.canGoBack)
            #expect(tab.window?.title == "Inner")
            tab.perform(.goBack)
            await arrived(right)
            #expect(right.shownFolderPath == real(harness, "Alpha"))
            #expect(left.shownFolderPath == real(harness))
        }

        @Test func theKeyboardGoingIntoAPaneMakesItTheActiveOne() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            right.content.focusList()
            #expect(tab.activePane === right)
            left.content.focusList()
            #expect(tab.activePane === left)
            tab.perform(.switchToOtherPane)
            #expect(tab.activePane === right)
            #expect(tab.paneWithKeyboard === right)
        }

        /// The line runs along the top of `cell`, its ends in from the cell's sides.
        private func isOver(_ line: ActivePaneLine, _ cell: WorkspaceCell) -> Bool {
            let inset = CGFloat(ActivePaneLine.inset)
            return line.frame.minX == cell.frame.minX + inset && line.frame.maxX == cell.frame.maxX - inset
                && line.frame.minY == cell.frame.minY
        }

        /// The line's look for where the keyboard is: grey whatever it is while the window is in the background.
        private func expectedLook(_ tab: MainWindowController, lit: Bool) -> ActivePaneLine.Look {
            let keyboard = tab.workspace.activePaneKeyboard()
            #expect(keyboard.hasKeyboard == lit)
            return !keyboard.windowActive ? .background : lit ? .lit : .dimmed
        }

        @Test func theLineOverThePaneShowsWithOnePaneAndIsLitWhileThePaneOrItsRenameHasTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let line = tab.workspace.contentColumn.activeLine
            tab.content.focusList()
            harness.layout(tab)
            #expect(!line.isHidden)
            #expect(isOver(line, tab.workspace.mainCell))
            #expect(line.look == expectedLook(tab, lit: true))

            tab.perform(.focusTreePane)
            harness.layout(tab)
            #expect(line.look == expectedLook(tab, lit: false))

            // A name being renamed is the pane's keyboard too.
            let item = try #require(tab.content.entries.first)
            tab.content.select(paths: [item.path])
            #expect(tab.content.beginRename(path: item.path))
            harness.layout(tab)
            #expect(line.look == expectedLook(tab, lit: true))
            tab.content.renameCancelled()
        }

        @Test func withTwoPanesTheLineIsOverTheActivePaneAndDimsWhileTheTreeHasTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            let line = tab.workspace.contentColumn.activeLine
            right.content.focusList()
            harness.layout(tab)
            #expect(isOver(line, tab.workspace.secondCell))
            #expect(line.look == expectedLook(tab, lit: true))

            tab.perform(.focusTreePane)
            harness.layout(tab)
            // The tree drives the right pane still: the line stays over it, dimmed.
            #expect(tab.activePane === right)
            #expect(isOver(line, tab.workspace.secondCell))
            #expect(line.look == expectedLook(tab, lit: false))

            left.content.focusList()
            harness.layout(tab)
            #expect(isOver(line, tab.workspace.mainCell))
            #expect(line.look == expectedLook(tab, lit: true))
        }

        @Test func tabWalksTheTreeTheLeftPaneAndTheRightPaneInTurn() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            left.content.focusList()

            tab.tabKeyPressed(from: left)
            #expect(tab.paneWithKeyboard === right)
            tab.tabKeyPressed(from: right)
            #expect(tab.focusedPane == .tree)
            #expect(tab.activePane === right)
            tab.tabKeyPressedInTree()
            #expect(tab.paneWithKeyboard === left)
            #expect(tab.activePane === left)

            // With the tree hidden, Tab goes back and forth between the panes.
            tab.updatePanels { $0.folderTreeOpen = false }
            tab.tabKeyPressed(from: left)
            #expect(tab.paneWithKeyboard === right)
            tab.tabKeyPressed(from: right)
            #expect(tab.paneWithKeyboard === left)
        }

        @Test func theTreeFollowsTheActivePaneWithoutMovingItsRoot() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta/Inner")
            let model = tab.sidebarController.model
            let root = model.rootPath

            tab.focusPane(right)
            #expect(await waitUntil { model.selected == .filesystem(real(harness, "Beta/Inner")) })
            #expect(model.nodes[real(harness, "Beta")]?.expanded == true)
            #expect(model.rootPath == root)
            tab.focusPane(left)
            #expect(await waitUntil { model.selected == .filesystem(real(harness)) })

            // A tree rooted below the other pane's folder stays where it is when that pane becomes active.
            model.initializeTree(real(harness, "Alpha"))
            await left.navigate(to: URL(fileURLWithPath: real(harness, "Alpha")))
            await settle()
            tab.focusPane(right)
            await settle()
            #expect(model.rootPath == real(harness, "Alpha"))
            #expect(await waitUntil { model.selected == nil })
        }

        @Test func twoPanesAgainClosesThePaneThatIsntActiveAndBringsItBackWhereItWas() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let oneMinimum = tab.window?.minSize
            let right = tab.openSecondPane(at: real(harness, "Gamma"))
            await arrived(right)
            #expect(tab.window?.minSize != oneMinimum)
            tab.focusPane(right)

            #expect(tab.sidebarController.paneFolders == [real(harness), real(harness, "Gamma")])
            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
            #expect(tab.sidebarController.paneFolders.isEmpty)
            #expect(tab.activePane === right)
            #expect(tab.workspace.mainCell.content === right.content.view)
            #expect(!tab.workspace.showsTwoPanes)
            #expect(tab.window?.minSize == oneMinimum)

            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane)
            await arrived(back)
            #expect(back.shownFolderPath == real(harness))
            #expect(tab.activePane === right)
            #expect(tab.panes.first === right)
        }

        // ⌘\ brings a closed pane back as it was: its Back and Forward, filter mode, selection and filter.
        @Test func aClosedPaneComesBackWithItsHistoryFilterModeSelectionAndFilter() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness)
            await right.navigate(to: URL(fileURLWithPath: real(harness, "Alpha")))
            await arrived(right)
            right.content.setViewFilterMode(.contains)
            right.content.select(paths: [real(harness, "Alpha/Inner")])
            right.content.setFilter("inn")
            let history = right.navigationHistory
            #expect(history.paths == [real(harness), real(harness, "Alpha")])
            left.content.setViewFilterMode(.fuzzy)

            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane)
            await arrived(back)
            #expect(back.shownFolderPath == real(harness, "Alpha"))
            #expect(back.navigationHistory == history)
            #expect(back.content.folderFilterMode == .contains)
            #expect(back.content.selection.paths == [real(harness, "Alpha/Inner")])
            #expect(back.content.filter == "inn")
            #expect(tab.activePane === left)
        }

        @Test func aChangeInTheSecondPanesFolderIsReadThereByItsOwnWatch() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha")
            #expect(right.watchID != left.watchID)
            #expect(left.watchID == tab.windowID)
            let made = real(harness, "Alpha") + "/made.txt"
            try "x".write(toFile: made, atomically: true, encoding: .utf8)
            // The watch lets go of the cached listings before it tells the window.
            harness.services.directoryService.cache.clear()

            harness.windows.folderChanged(
                windowID: right.watchID, FolderChange(path: real(harness, "Alpha"), changedPaths: [made]))
            #expect(await waitUntil { right.content.listed.contains { $0.path == made } })
            #expect(!left.content.listed.contains { $0.path == made })
        }
        // MARK: Across the panes

        /// The app's file operations for the harness's windows, with nothing asked or shown.
        private func writes(_ harness: ExplorerHarness) -> AppWriteOperations {
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) }, log: { _ in })
            operations.dialogs.show = { _, _, _ in }
            operations.dialogs.confirm = { _, _ in false }
            return operations
        }

        @Test func copyAndMoveToOtherPaneSendTheSelectionIntoTheOtherPanesFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma")
            let operations = writes(harness)
            defer { withExtendedLifetime(operations) {} }
            let note = real(harness, "note.txt")
            left.content.focusList()
            left.content.select(paths: [note])
            #expect(tab.canPerform(.copyToOtherPane))

            tab.perform(.copyToOtherPane)
            let copied = real(harness, "Gamma") + "/note.txt"
            #expect(await waitUntil { FileManager.default.fileExists(atPath: copied) })
            #expect(FileManager.default.fileExists(atPath: note))
            #expect(tab.activePane === left)
            // The other pane shows what arrived, selected, without waiting for a folder watch.
            #expect(await waitUntil { right.content.selection.paths == [copied] })
            #expect(right.content.listed.contains { $0.path == copied })

            try FileManager.default.removeItem(atPath: copied)
            #expect(await waitUntil { !tab.isWriteLocked })
            left.content.select(paths: [note])
            tab.perform(.moveToOtherPane)
            #expect(await waitUntil { FileManager.default.fileExists(atPath: copied) })
            #expect(await waitUntil { !FileManager.default.fileExists(atPath: note) })
            #expect(await waitUntil { right.content.selection.paths == [copied] })
            // The pane it left lets go of it at once.
            #expect(await waitUntil { !left.content.listed.contains { $0.path == note } })
        }

        @Test func copyAndMoveToOtherPaneWaitForASecondPaneOnAnotherFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.content.focusList()
            tab.content.select(paths: [real(harness, "note.txt")])
            #expect(!tab.canPerform(.copyToOtherPane))
            #expect(!tab.canPerform(.moveToOtherPane))
            let second = tab.openSecondPane()
            await arrived(second)
            // Both panes show one folder.
            #expect(!tab.canPerform(.copyToOtherPane))
            await second.navigate(to: URL(fileURLWithPath: real(harness, "Beta")))
            #expect(tab.canPerform(.copyToOtherPane))
            #expect(tab.canPerform(.moveToOtherPane))
        }

        @Test func openInOtherPaneOpensTheSelectedFolderThereAndOpensThePaneFirstIfNeeded() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.content.focusList()
            tab.content.select(paths: [real(harness, "Alpha")])
            #expect(tab.canPerform(.openSelectionInOtherPane))

            tab.perform(.openSelectionInOtherPane)
            let other = try #require(tab.otherPane)
            #expect(await waitUntil { other.shownFolderPath == real(harness, "Alpha") })
            #expect(tab.activePane === tab.panes[0])

            tab.content.select(paths: [real(harness, "Beta")])
            tab.perform(.openSelectionInOtherPane)
            #expect(await waitUntil { other.shownFolderPath == real(harness, "Beta") })
            #expect(other.navigationHistory.paths == [real(harness, "Alpha"), real(harness, "Beta")])
        }

        @Test func swapPanesTradesThePlacesOfThePanesAndTheActiveOneStaysActive() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            left.content.focusList()

            tab.perform(.swapPanes)
            #expect(tab.panes.first === right)
            #expect(tab.panes.last === left)
            #expect(tab.activePane === left)
            #expect(tab.workspace.activePane == 1)
            #expect(tab.workspace.mainCell.content === right.content.view)
            #expect(tab.workspace.secondCell.content === left.content.view)
            #expect(tab.paneWithKeyboard === left)
            let name = (real(harness) as NSString).lastPathComponent
            #expect(tab.twoPaneLabel == "Beta | \(name)")
        }

        /// Swap Panes with the keyboard put somewhere by `place`, in a tab whose right pane is active or its left: the
        /// active pane stays active on the other side, and the keyboard stays with what had it. `then` looks at the tab
        /// after the swap.
        private func swapKeepsTheActivePane(
            rightActive: Bool,
            _ place: @MainActor (MainWindowController, _ active: BrowserPane, _ other: BrowserPane) async -> Void,
            then: (MainWindowController, _ active: BrowserPane) -> Void = { _, _ in }
        ) async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            let (active, other) = rightActive ? (right, left) : (left, right)
            tab.focusPane(active)
            await place(tab, active, other)
            harness.layout(tab)
            let responder = tab.window?.firstResponder
            let keyboard = tab.paneWithKeyboard
            #expect(tab.activePane === active)

            tab.perform(.swapPanes)
            harness.layout(tab)
            await settle()
            #expect(tab.panes.first === right)
            #expect(tab.activePane === active)
            #expect(tab.workspace.activePane == (rightActive ? 0 : 1))
            #expect(tab.window?.firstResponder === responder)
            #expect(tab.paneWithKeyboard === keyboard)
            #expect(tab.workspace.mainCell.content === right.content.view)
            #expect(tab.workspace.statusCell.content === right.content.contentShell.pathBarRow)
            #expect(tab.workspace.secondCell.content === left.content.view)
            #expect(tab.workspace.secondStatusCell.content === left.content.contentShell.pathBarRow)
            then(tab, active)
        }

        @Test(arguments: [false, true]) func swapPanesWithTheKeyboardInTheActiveList(rightActive: Bool) async throws {
            try await swapKeepsTheActivePane(rightActive: rightActive) { _, active, _ in active.content.focusList() }
        }

        // A right-click in the other pane makes it active and leaves the keyboard in the list it was in: it stays
        // there, and that pane inactive.
        @Test(arguments: [false, true]) func swapPanesWithTheKeyboardInTheOtherList(rightActive: Bool) async throws {
            try await swapKeepsTheActivePane(rightActive: rightActive) { tab, active, other in
                other.content.focusList()
                tab.activate(active)
                #expect(tab.paneWithKeyboard === other)
            }
        }

        @Test(arguments: [false, true]) func swapPanesWithTheKeyboardInTheTree(rightActive: Bool) async throws {
            try await swapKeepsTheActivePane(rightActive: rightActive) { tab, _, _ in
                #expect(tab.sidebarController.focusTree())
            }
        }

        @Test(arguments: [false, true]) func swapPanesWithTheKeyboardInTheSearchField(rightActive: Bool) async throws {
            try await swapKeepsTheActivePane(rightActive: rightActive) { tab, _, _ in
                #expect(tab.window?.makeFirstResponder(tab.searchField) == true)
            }
        }

        // Typing in the list shows the filter pill; the keyboard stays in the list, and the filter with its pane.
        @Test(arguments: [false, true]) func swapPanesWithAFilterTyped(rightActive: Bool) async throws {
            try await swapKeepsTheActivePane(rightActive: rightActive) { _, active, _ in
                active.content.focusList()
                active.content.setFilter("a")
            } then: { tab, active in
                #expect(active.content.filter == "a")
                #expect(tab.otherPane?.content.filter == "")
            }
        }

        // A path being typed in the path bar stays, with the keyboard, and its suggestions open over the bar where it
        // is now.
        @Test(arguments: [false, true]) func swapPanesWhileAPathIsTyped(rightActive: Bool) async throws {
            let timers = ManualTimers()
            try await swapKeepsTheActivePane(rightActive: rightActive) { tab, active, _ in
                let row = active.content.contentShell.pathBarRow
                row.editor.timers = timers
                row.requestSuggestions = { _ in [PathSuggestionRow(path: "/Applications", name: "Applications")] }
                row.beginEditing()
                tab.window?.contentView?.layoutSubtreeIfNeeded()
                timers.advance(InfoMetrics.suggestionDebounce)
                #expect(await waitUntil { row.editor.suggestionsAreShown })
            } then: { tab, active in
                let editor = active.content.contentShell.pathBarRow.editor
                #expect(active.content.contentShell.pathBarRow.isEditing)
                #expect(editor.field.currentEditor() != nil)
                let host = try? #require(tab.window?.contentView)
                let bar = host.map { editor.convert(editor.bounds, to: $0) }
                #expect(editor.suggestionsFrame?.minX == bar?.minX)
                #expect(editor.suggestionsFrame?.width == bar?.width)
            }
        }

        @Test func theGoCommandsShowOnePanesFolderInTheOther() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma")
            #expect(tab.canPerform(.goToOtherPaneFolder))

            tab.perform(.goToOtherPaneFolder)
            await arrived(left)
            #expect(left.shownFolderPath == real(harness, "Gamma"))
            #expect(!tab.canPerform(.goToOtherPaneFolder))

            await left.navigate(to: URL(fileURLWithPath: real(harness, "Alpha")))
            tab.perform(.showFolderInOtherPane)
            #expect(await waitUntil { right.shownFolderPath == real(harness, "Alpha") })
            #expect(tab.activePane === left)
        }

        @Test func makePanesEqualWidthSharesTheRoomEvenly() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, _) = try await twoPanes(harness)
            tab.workspace.setPaneSplit(0.7)
            harness.layout(tab)
            #expect(tab.workspace.mainCell.frame.width > tab.workspace.secondCell.frame.width + 50)

            tab.perform(.equalizePanes)
            harness.layout(tab)
            #expect(abs(tab.workspace.mainCell.frame.width - tab.workspace.secondCell.frame.width) <= 1)
        }
        // MARK: Kept with the tab

        /// The tab the group opened after `tab`, read.
        private func opened(_ tab: MainWindowController, after count: Int) async throws -> MainWindowController {
            let group = try #require(tab.group)
            #expect(await waitUntil { group.tabs.count == count + 1 })
            let index = try #require(group.tabs.firstIndex { $0 === tab })
            let new = group.tabs[index + 1]
            new.servicesOverride = tab.servicesOverride
            #expect(await waitUntil { new.panes.allSatisfy { $0.loaded && !$0.isNavigating } })
            return new
        }

        @Test func theSavedTabKeepsBothPanesAndATabMadeFromItShowsThemAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Beta")
            right.setMode(.icons)
            tab.focusPane(right)
            tab.workspace.setPaneSplit(0.6)

            let saved = tab.openTab
            #expect(saved.path == real(harness))
            #expect(saved.secondPane?.path == real(harness, "Beta"))
            #expect(saved.secondPane?.viewMode == .icons)
            #expect(saved.activePane == 1)
            #expect(saved.paneSplit == 0.6)
            #expect(tab.activePaneTab.path == real(harness, "Beta"))
            #expect(tab.activePaneTab.secondPane == nil)

            let start = StartupTabs.startupTab(saved, homePath: real(harness))
            let again = MainWindowController(tab: start)
            again.servicesOverride = tab.servicesOverride
            defer { again.window?.close() }
            #expect(again.panes.count == 2)
            #expect(again.activePaneIndex == 1)
            #expect(again.panes[1].folder.path == real(harness, "Beta"))
            #expect(again.panes[1].viewMode == .icons)
            #expect(again.workspace.paneSplit == 0.6)
        }

        @Test func duplicateTabAndReopenClosedTabBringBothPanes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Alpha")
            await right.navigate(to: URL(fileURLWithPath: real(harness, "Alpha/Inner")))
            let group = try #require(tab.group)

            group.duplicateTab(tab)
            let copy = try await opened(tab, after: 1)
            #expect(copy.panes.count == 2)
            #expect(copy.panes[1].shownFolderPath == real(harness, "Alpha/Inner"))
            #expect(copy.panes[1].navigationHistory.paths == right.navigationHistory.paths)

            group.closeTab(copy)
            #expect(await waitUntil { group.tabs.count == 1 })
            group.reopenClosedTab(from: tab)
            let back = try await opened(tab, after: 1)
            #expect(back.panes.count == 2)
            #expect(back.panes[1].shownFolderPath == real(harness, "Alpha/Inner"))
        }

        // A tab comes back as it was closed: each pane's Back and Forward, selection and filter, which Duplicate Tab
        // copies too.
        @Test func reopenClosedTabBringsBackEachPanesHistorySelectionAndFilter() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha")
            let group = try #require(tab.group)
            group.duplicateTab(tab)
            let copy = try await opened(tab, after: 1)
            let (copyLeft, copyRight) = (copy.panes[0], copy.panes[1])
            await arrived(copyLeft)
            copyLeft.go(to: URL(fileURLWithPath: real(harness, "Beta")))
            #expect(await waitUntil { copyLeft.shownFolderPath == real(harness, "Beta") })
            await arrived(copyLeft)
            #expect(copy.activePane === copyLeft)
            copy.perform(.goBack)
            #expect(await waitUntil { copyLeft.shownFolderPath == real(harness) })
            await arrived(copyLeft)
            copyLeft.content.select(paths: [real(harness, "note.txt")])
            copyRight.content.select(paths: [real(harness, "Alpha/Inner")])
            copyRight.content.setFilter("inn")
            let leftHistory = copyLeft.navigationHistory
            let rightHistory = copyRight.navigationHistory
            #expect(leftHistory.paths == [real(harness), real(harness, "Beta")])
            #expect(leftHistory.index == 0)
            #expect(left.navigationHistory.paths == [real(harness)])
            #expect(right.content.selection.paths.isEmpty)

            group.closeTab(copy)
            #expect(await waitUntil { group.tabs.count == 1 })
            group.reopenClosedTab(from: tab)
            let back = try await opened(tab, after: 1)
            await arrived(back.panes[0])
            await arrived(back.panes[1])
            #expect(back.panes[0].navigationHistory == leftHistory)
            #expect(back.panes[1].navigationHistory == rightHistory)
            #expect(back.panes[0].content.selection.paths == [real(harness, "note.txt")])
            #expect(back.panes[1].content.selection.paths == [real(harness, "Alpha/Inner")])
            #expect(back.panes[1].content.filter == "inn")
            #expect(back.panes[0].content.filter.isEmpty)
        }

        // A pane closed in a tab is the tab's while it is open: the tab reopened has none to bring back, so ⌘\ in it
        // opens a copy of the active pane.
        @Test func aReopenedTabDoesNotBringBackAPaneClosedInIt() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openNewTab(from: tab)
            let other = try await opened(tab, after: 1)
            let second = other.openSecondPane(at: real(harness, "Gamma"))
            await arrived(second)
            other.perform(.toggleTwoPanes)
            #expect(other.panes.count == 1)
            #expect(other.closedSecondPane != nil)

            group.closeTab(other)
            #expect(await waitUntil { group.tabs.count == 1 })
            group.reopenClosedTab(from: tab)
            let back = try await opened(tab, after: 1)
            #expect(back.closedSecondPane == nil)
            back.perform(.toggleTwoPanes)
            let copy = try #require(back.otherPane)
            await arrived(copy)
            #expect(copy.shownFolderPath == real(harness))
        }

        // A tab comes back where it was in the row, not after the tab on screen; with fewer tabs left, at the end.
        @Test func reopenClosedTabPutsTheTabBackWhereItWas() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let first = try await harness.open()
            let group = try #require(first.group)
            group.openNewTab(from: first)
            let middle = try await opened(first, after: 1)
            await arrived(middle.activePane)
            middle.activePane.go(to: URL(fileURLWithPath: real(harness, "Beta")))
            #expect(await waitUntil { middle.activePane.shownFolderPath == real(harness, "Beta") })
            group.openNewTab(from: middle)
            let last = try await opened(middle, after: 2)
            group.select(last)

            group.closeTab(middle)
            #expect(await waitUntil { group.tabs.count == 2 })
            #expect(group.session.closedTabs.last?.index == 1)
            group.reopenClosedTab(from: last)
            #expect(await waitUntil { group.tabs.count == 3 })
            #expect(group.tabs[1].panes[0].folder.path == real(harness, "Beta"))
            #expect(group.selected === group.tabs[1])

            // Tabs closed one after another come back in their order.
            let (beta, end) = (group.tabs[1], group.tabs[2])
            group.closeTab(beta)
            group.closeTab(end)
            #expect(await waitUntil { group.tabs.count == 1 })
            group.reopenClosedTab(from: first)
            #expect(await waitUntil { group.tabs.count == 2 })
            group.reopenClosedTab(from: first)
            #expect(await waitUntil { group.tabs.count == 3 })
            #expect(group.tabs[1].panes[0].folder.path == real(harness, "Beta"))
        }
        // ⌘\ to open or close the second pane leaves the keyboard in a list, so Tab goes on between the panes.
        @Test func openingAndClosingTheSecondPaneKeepTheKeyboardInAList() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let left = tab.activePane
            left.content.focusList()

            tab.perform(.toggleTwoPanes)
            let right = try #require(tab.otherPane)
            #expect(tab.paneWithKeyboard === left)
            await arrived(right)
            left.content.switchPane()
            #expect(tab.paneWithKeyboard === right)

            // The left pane goes; the right one moves into its place with the keyboard.
            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
            #expect(tab.paneWithKeyboard === right)

            tab.perform(.toggleTwoPanes)
            #expect(tab.paneWithKeyboard === right)
            let other = try #require(tab.otherPane)
            await arrived(other)
            right.content.switchPane()
            #expect(tab.paneWithKeyboard === other)

            // The left pane stays: its list keeps the keyboard where it is.
            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
            #expect(tab.paneWithKeyboard === other)
        }
        // The right-click menus have the Other Pane submenu only while the tab shows two panes.
        @Test func theRightClickMenusOfferTheOtherPaneOnlyWithTwoPanes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let operations = writes(harness)
            defer { withExtendedLifetime(operations) {} }
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            func submenu(_ menu: NSMenu?) -> NSMenu? {
                menu?.items.first { $0.identifier?.rawValue == "otherPane" }?.submenu
            }
            #expect(submenu(tab.contextMenus.contentMenu(for: [note])) == nil)
            #expect(submenu(tab.contextMenus.contentMenu(for: nil)) == nil)

            let right = tab.openSecondPane(at: real(harness, "Beta"))
            await arrived(right)
            let files = try #require(submenu(tab.contextMenus.contentMenu(for: [note])))
            #expect(files.items.map(\.title) == ["Open", "Copy", "Move"])
            #expect(files.items.map(\.isEnabled) == [false, true, true])
            #expect(files.items[1].keyEquivalent == String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!)))
            let folder = try #require(submenu(tab.contextMenus.contentMenu(for: [alpha])))
            #expect(folder.items.map(\.isEnabled) == [true, true, true])
            let background = try #require(submenu(tab.contextMenus.contentMenu(for: nil)))
            #expect(background.items.map(\.title) == ["Show This Folder", "Go to Its Folder"])

            // Copy acts on the items right-clicked.
            tab.contextMenus.contextMenu(
                otherPane: .copyToOtherPane,
                subject: ContextMenuSubject(
                    surface: .content, scope: .selection, paths: [note.path], targetPath: note.path,
                    entries: [ContextMenuCoordinator.commandEntry(note)]))
            let copied = real(harness, "Beta") + "/note.txt"
            #expect(await waitUntil { FileManager.default.fileExists(atPath: copied) })
            #expect(await waitUntil { right.content.listed.contains { $0.path == copied } })

            tab.contextMenus.contextMenu(
                otherPane: .openSelectionInOtherPane,
                subject: ContextMenuSubject(
                    surface: .content, scope: .selection, paths: [alpha.path], targetPath: alpha.path,
                    entries: [ContextMenuCoordinator.commandEntry(alpha)]))
            #expect(await waitUntil { right.shownFolderPath == real(harness, "Alpha") })
        }
    }
}
