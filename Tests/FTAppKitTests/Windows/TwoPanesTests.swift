import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

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

            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
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
    }
}
