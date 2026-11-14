// A pinned filter: it holds through Esc, other folders and searches in its own pane, shows every folder, and typing
// selects names instead of changing it
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct PinnedFilterTests {
        /// Desk: two screenshots, a note and Projects (a screenshot, a plan and Archive).
        private func desk(_ harness: ExplorerHarness) throws -> String {
            let desk = harness.folder.url.appendingPathComponent("Desk")
            let projects = desk.appendingPathComponent("Projects")
            try FileManager.default.createDirectory(
                at: projects.appendingPathComponent("Archive"), withIntermediateDirectories: true)
            for (folder, name) in [
                (desk, "Screenshot 09.12.png"), (desk, "Screenshot 10.02.png"), (desk, "notes.md"),
                (projects, "Screenshot 11.31.png"), (projects, "plan.md"),
            ] {
                try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let path = desk.path
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func names(_ tab: MainWindowController) -> [String] { tab.content.entries.map(\.name) }

        private func type(_ text: String, _ content: ContentPaneController) {
            for letter in text { content.applyFilterKey(.type(String(letter))) }
        }

        private func arrived(_ pane: BrowserPane) async {
            #expect(await waitUntil { pane.loaded && pane.hasShownFolder && !pane.isNavigating })
            await settle()
        }

        @Test func pinningKeepsTheFilterAndShowsTheFoldersTooAndUnpinningGivesTheTextBack() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open(try desk(harness))
            #expect(await waitUntil { tab.content.entries.count == 4 })
            #expect(!tab.canPerform(.togglePinFilter))

            type("scr", tab.content)
            #expect(names(tab) == ["Screenshot 09.12.png", "Screenshot 10.02.png"])
            #expect(tab.canPerform(.togglePinFilter))
            #expect(!tab.menuState.filterPinned)

            tab.perform(.togglePinFilter)
            #expect(tab.content.pinnedFilter == PinnedListFilter(query: "scr", mode: .fuzzy))
            #expect(tab.content.filter.isEmpty)
            #expect(names(tab) == ["Projects", "Screenshot 09.12.png", "Screenshot 10.02.png"])
            #expect(tab.menuState.filterPinned)
            let pill = tab.content.container.filterPill
            #expect(pill.isShowingFilter)
            #expect(pill.isPinned)
            #expect(pill.pin.isPinned)

            // The chip is locked while pinned.
            #expect(pill.chip.accessibilityPerformPress())
            #expect(tab.content.pinnedFilter?.mode == .fuzzy)

            // Unpinned, it is the typed filter again: folders it doesn't match go, and Esc clears it.
            #expect(pill.pin.accessibilityPerformPress())
            #expect(tab.content.pinnedFilter == nil)
            #expect(tab.content.filter == "scr")
            #expect(names(tab) == ["Screenshot 09.12.png", "Screenshot 10.02.png"])
            #expect(!pill.isPinned)
            tab.content.applyFilterKey(.clear)
            #expect(tab.content.filter.isEmpty)
            #expect(names(tab).count == 4)
        }

        @Test func typingWhilePinnedSelectsANameAndEscLeavesThePin() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open(try desk(harness))
            #expect(await waitUntil { tab.content.entries.count == 4 })
            type("scr", tab.content)
            tab.perform(.togglePinFilter)

            tab.content.typeToSelect("p")
            #expect(tab.content.selection.paths == [tab.content.entries[0].path])
            tab.content.typeToSelect(nil)
            tab.content.typeToSelect("S")
            tab.content.typeToSelect("c")
            #expect(tab.content.selection.leadPath?.hasSuffix("Screenshot 09.12.png") == true)
            // Nothing typed changed the filter; Esc in the list leaves it pinned.
            #expect(tab.content.filter.isEmpty)
            tab.content.applyFilterKey(.clear)
            #expect(tab.content.pinnedFilter != nil)
            #expect(names(tab).count == 3)
        }

        @Test func thePinFollowsItsPaneIntoOtherFoldersAndBack() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let path = try desk(harness)
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 4 })
            type("scr", tab.content)
            tab.perform(.togglePinFilter)

            await tab.activePane.navigate(to: URL(fileURLWithPath: path + "/Projects"))
            #expect(tab.content.pinnedFilter?.query == "scr")
            #expect(names(tab) == ["Archive", "Screenshot 11.31.png"])

            tab.perform(.goBack)
            await arrived(tab.activePane)
            #expect(tab.shownFolderPath == path)
            #expect(names(tab) == ["Projects", "Screenshot 09.12.png", "Screenshot 10.02.png"])

            // A filter typed and not pinned is cleared by another folder, as before.
            tab.perform(.togglePinFilter)
            #expect(tab.content.filter == "scr")
            await tab.activePane.navigate(to: URL(fileURLWithPath: path + "/Projects"))
            #expect(tab.content.filter.isEmpty)
            #expect(tab.content.pinnedFilter == nil)
            #expect(names(tab).count == 3)
        }

        @Test func eachPaneHasItsOwnPinAndItMovesWithItsPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let path = try desk(harness)
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 4 })
            let left = tab.activePane
            type("scr", left.content)
            tab.perform(.togglePinFilter)

            let right = tab.openSecondPane(at: path)
            await arrived(right)
            harness.layout(tab)
            #expect(right.content.pinnedFilter == nil)
            #expect(right.content.entries.count == 4)

            tab.perform(.swapPanes)
            #expect(tab.panes.first === right)
            #expect(left.content.pinnedFilter?.query == "scr")
            #expect(right.content.pinnedFilter == nil)
            tab.focusPane(right)
            #expect(!tab.menuState.filterPinned)
            #expect(!tab.canPerform(.togglePinFilter))
            tab.focusPane(left)
            #expect(tab.menuState.filterPinned)
        }

        @Test func theClearButtonRemovesThePinAndShowingAnItemItHidesLetsItGo() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let path = try desk(harness)
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 4 })
            type("scr", tab.content)
            tab.perform(.togglePinFilter)

            tab.content.select(paths: [path + "/notes.md"])
            #expect(tab.content.pinnedFilter == nil)
            #expect(tab.content.selection.paths == [path + "/notes.md"])
            #expect(names(tab).count == 4)

            type("scr", tab.content)
            tab.perform(.togglePinFilter)
            tab.content.container.filterPill.onClear()
            #expect(tab.content.pinnedFilter == nil)
            #expect(tab.content.filter.isEmpty)
            #expect(!tab.content.container.filterPill.isShowingFilter)
            #expect(names(tab).count == 4)
        }

        @Test func duplicateTabKeepsThePinAndANewTabStartsWithout() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let path = try desk(harness)
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 4 })
            type("scr", tab.content)
            tab.perform(.togglePinFilter)

            #expect(tab.activePane.liveView?.pinnedListFilter?.query == "scr")
            let snapshot = tab.snapshot
            #expect(ExplorerTabs.newTab(from: snapshot).view?.pinnedListFilter == nil)
        }
    }
}
