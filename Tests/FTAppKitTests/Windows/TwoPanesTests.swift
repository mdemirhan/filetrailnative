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
            let (tab, left, _) = try await twoPanes(harness, right: "Gamma")
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

            try FileManager.default.removeItem(atPath: copied)
            #expect(await waitUntil { !tab.isWriteLocked })
            left.content.select(paths: [note])
            tab.perform(.moveToOtherPane)
            #expect(await waitUntil { FileManager.default.fileExists(atPath: copied) })
            #expect(await waitUntil { !FileManager.default.fileExists(atPath: note) })
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
    }
}
