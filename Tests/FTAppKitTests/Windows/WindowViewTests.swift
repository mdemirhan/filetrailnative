// Checks window views opened and saved, Tab View Options and Window View Options saving, and the Views window's tab
// views and window views, on the app's own windows, never shown
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct WindowViewTests {
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func opens(_ harness: ExplorerHarness, _ name: String) -> TabView {
            TabView(
                id: "tab-\(name)", name: "Open \(name)",
                keeps: TabViewKeeps(pane: PaneKeeps(folder: real(harness, name), view: FolderViewKeeps(view: .details)))
            )
        }

        // MARK: Opening

        @Test func aSlotPastTheEndOpensNothingAndOneInItOpensItsWindowViewsTabs() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let alpha = opens(harness, "Alpha")
            let beta = opens(harness, "Beta")
            tab.updatePreferences {
                $0.tabViews = [alpha, beta]
                $0.windowViews = [WindowView(id: "w1", name: "Work", tabs: [alpha.id, nil, beta.id])]
            }
            harness.windows.openWindowView(slot: 1)
            harness.windows.openWindowView(slot: 4, inPlaceOf: tab)
            await settle()
            #expect(harness.windows.count == 1)

            harness.windows.openWindowView(slot: 0)
            #expect(await waitUntil { harness.windows.count == 2 })
            let opened = try #require(harness.windows.newestGroup)
            #expect(opened.tabs.count == 3)
            // The tab in front takes its tab view once its first folder is read.
            let front = try #require(opened.selected)
            #expect(await waitUntil { front.activePane.folderPath == real(harness, "Alpha") })
            #expect(front.activePane.viewMode == .details)
            #expect(front.lastTabViewID == alpha.id)
            // A tab with no tab view opens where the window it was opened from is.
            #expect(opened.tabs[1].panes[0].folderPath == tab.activePane.folderPath)
            // The others take theirs as they are first shown.
            opened.select(opened.tabs[2])
            opened.tabs[2].ensureLoaded()
            #expect(await waitUntil { opened.tabs[2].activePane.folderPath == real(harness, "Beta") })
        }

        @Test func theFrontTabThePanelsAndTheSizeAreTheWindowViewsWhereKept() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            #expect(tab.preferences.folderTreeOpen)
            tab.updatePreferences {
                $0.windowViews = [
                    WindowView(
                        id: "w1", name: "Work", tabs: [nil, nil], frontTab: 1, size: .init(width: 900, height: 620),
                        folderTreeOpen: false)
                ]
            }
            harness.windows.openWindowView(id: "w1")
            #expect(await waitUntil { harness.windows.count == 2 })
            let opened = try #require(harness.windows.newestGroup)
            #expect(opened.selected === opened.tabs[1])
            let front = try #require(opened.selected)
            #expect(!opened.session.panels.folderTreeOpen)
            // Not kept: as in the window it was opened from.
            #expect(opened.session.panels.propertiesOpen == tab.preferences.propertiesOpen)
            let frame = try #require(front.window?.frame)
            #expect(abs(frame.width - 900) < 2 && abs(frame.height - 620) < 2)
        }

        @Test func inThisWindowTakesTheWindowsPlace() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let first = try #require(tab.group)
            tab.updatePreferences { $0.windowViews = [WindowView(id: "w1", name: "Work", tabs: [nil, nil, nil])] }
            harness.windows.openWindowView(id: "w1", inPlaceOf: tab)
            #expect(await waitUntil { harness.windows.newestGroup !== first && harness.windows.count == 1 })
            #expect(harness.windows.newestGroup?.tabs.count == 3)
        }

        @Test func aTabViewRemovedSinceOpensItsTabAsANewTab() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences { $0.windowViews = [WindowView(id: "w1", name: "Work", tabs: ["gone"])] }
            harness.windows.openWindowView(id: "w1")
            #expect(await waitUntil { harness.windows.count == 2 })
            let front = try #require(harness.windows.newestGroup?.selected)
            #expect(await waitUntil { front.loaded && !front.isNavigating })
            #expect(front.activePane.folderPath == tab.activePane.folderPath)
            #expect(front.lastTabViewID == nil)
        }

        // MARK: Saving a tab view

        private func tabSheet(_ tab: MainWindowController) throws -> TabViewOptionsSheet {
            try #require(tab.dialogs.lazy.compactMap { $0.panel as? TabViewOptionsSheet }.first)
        }

        @Test func saveTabViewKeepsWhatTheSheetKeepsAndATakenNameIsSavedOver() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let other = TabView(id: "other", name: "Compare", keeps: TabViewKeeps(panes: 2))
            tab.updatePreferences {
                $0.tabViews = [other]
                $0.windowViews = [WindowView(id: "w1", name: "Work", tabs: ["other"])]
                $0.newTabViewID = "other"
            }
            tab.perform(.saveTabView)
            var draft = try tabSheet(tab).draft
            // It starts from the tab: one pane kept, with its view.
            #expect(draft.keeps.panes == 1)
            #expect(draft.keeps.pane?.view.view == tab.activePane.viewMode)
            draft.name = "  compare "
            try tabSheet(tab).onSave(draft)
            #expect(await waitUntil { tab.dialogs.isEmpty })
            let kept = tab.preferences.tabViews
            // Saved over the one with its name, which keeps its id: what uses it uses what was saved now.
            #expect(kept.count == 1 && kept[0].name == "compare" && kept[0].id == "other")
            #expect(kept[0].keeps == draft.keeps)
            #expect(tab.preferences.windowViews[0].tabs == ["other"])
            #expect(tab.preferences.newTabViewID == "other")
            #expect(tab.lastTabViewID == "other")
        }

        @Test func editingATabViewKeepsItsPlaceAndItsId() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let views = [
                TabView(id: "a", name: "A", keeps: TabViewKeeps(panes: 1)),
                TabView(id: "b", name: "B", keeps: TabViewKeeps(panes: 2)),
            ]
            tab.updatePreferences { $0.tabViews = views }
            tab.presentTabViewOptions(editing: views[0])
            var draft = try tabSheet(tab).draft
            #expect(draft.editingID == "a" && draft.name == "A")
            draft.name = "A2"
            draft.keepsHidden = true
            try tabSheet(tab).onSave(draft)
            #expect(await waitUntil { tab.dialogs.isEmpty })
            #expect(tab.preferences.tabViews.map(\.id) == ["a", "b"])
            #expect(tab.preferences.tabViews[0].name == "A2")
            #expect(tab.preferences.tabViews[0].keeps.includeHidden == tab.includeHidden)
        }

        @Test func noTabViewIsSavedPastTheLimitAndANoticeSaysSo() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let full = (0..<SavedViewNames.limit).map {
                TabView(id: "t\($0)", name: "Kept \($0)", keeps: TabViewKeeps(panes: 1))
            }
            tab.updatePreferences { $0.tabViews = full }
            tab.perform(.saveTabView)
            var draft = try tabSheet(tab).draft
            draft.name = "One More"
            try tabSheet(tab).onSave(draft)
            #expect(await waitUntil { tab.frontAlert != nil })
            #expect(tab.frontAlert?.titleLabel.stringValue == SavedViewNames.limitTitle(kind: "tab views"))
            #expect(tab.preferences.tabViews == full)
        }

        // MARK: Saving a window view

        @Test func saveWindowViewStartsFromTheWindowsTabsAndTheTabViewsLastAppliedToThem() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let alpha = opens(harness, "Alpha")
            tab.updatePreferences { $0.tabViews = [alpha] }
            tab.applyTabView(id: alpha.id)
            #expect(await waitUntil { tab.activePane.folderPath == real(harness, "Alpha") })
            tab.perform(.saveWindowView)
            let sheet = try #require(tab.dialogs.lazy.compactMap { $0.panel as? WindowViewOptionsSheet }.first)
            var draft = sheet.draft
            #expect(draft.tabs == [alpha.id])
            #expect(draft.front == 0)
            #expect(!draft.keepsSize && !draft.keepsFolderTree && !draft.keepsInfoPanel)
            draft.name = "Research"
            draft.setTabCount(3)
            draft.keepsFolderTree = true
            sheet.onSave(draft)
            #expect(await waitUntil { !tab.preferences.windowViews.isEmpty })
            let saved = try #require(tab.preferences.windowViews.first)
            #expect(saved.name == "Research")
            #expect(saved.tabs == [alpha.id, nil, nil])
            #expect(saved.folderTreeOpen == tab.preferences.folderTreeOpen)
            #expect(saved.size == nil)
        }

        // MARK: The Views window

        @Test func theViewsWindowOpensOnEachPaneWithItsTitle() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let views = ViewsWindowController(views: SharedFolderViews(), open: { _ in })
            defer { views.close() }
            for pane in ViewsWindowPane.allCases {
                views.present(pane, explorer: tab)
                #expect(views.pane == pane)
                #expect(views.window?.title == pane.title)
                #expect(views.tabViewsPane.isHidden == (pane != .tabViews))
                #expect(views.windowViewsPane.isHidden == (pane != .windowViews))
            }
        }

        @Test func tabViewsAreReorderedRenamedDuplicatedAndRemovedThere() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let saved = ["A", "B", "C"].map { TabView(id: $0.lowercased(), name: $0, keeps: TabViewKeeps(panes: 1)) }
            tab.updatePreferences {
                $0.tabViews = saved
                $0.windowViews = [WindowView(id: "w1", name: "Work", tabs: ["b", "c"])]
            }
            let views = ViewsWindowController(views: SharedFolderViews(), open: { _ in })
            defer { views.close() }
            views.present(.tabViews, explorer: tab)
            let pane: SavedViewsPane = views.tabViewsPane
            pane.reload()
            #expect(pane.rows.map(\.name) == ["A", "B", "C"])
            // The keys go by the order: the first five can be given them, ⌥⌘1 to ⌥⌘5 to begin with.
            #expect(pane.rows.map(\.key) == ["⌥⌘1", "⌥⌘2", "⌥⌘3"])

            pane.move(from: 2, to: 0)
            #expect(tab.preferences.tabViews.map(\.id) == ["c", "a", "b"])
            #expect(pane.rows.map(\.name) == ["C", "A", "B"])

            // A name another has is refused; a new one is kept.
            pane.rename("a", to: "c")
            #expect(tab.preferences.tabViews.map(\.name) == ["C", "A", "B"])
            pane.rename("a", to: "  Alpha ")
            #expect(tab.preferences.tabViews.map(\.name) == ["C", "Alpha", "B"])

            pane.tableView.selectRowIndexes([1], byExtendingSelection: false)
            pane.duplicateSelected()
            #expect(tab.preferences.tabViews.map(\.name) == ["C", "Alpha", "Alpha copy", "B"])

            // A tab view a window view uses leaves it a plain tab, and the new-tab view as none.
            tab.updatePreferences { $0.newTabViewID = "c" }
            pane.forget(["c"])
            #expect(tab.preferences.tabViews.map(\.name) == ["Alpha", "Alpha copy", "B"])
            #expect(tab.preferences.windowViews[0].tabs == ["b", nil])
            #expect(tab.preferences.newTabViewID == nil)
        }

        @Test func theNewTabViewIsChosenInTheTabViewsPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences {
                $0.tabViews = [
                    TabView(id: "a", name: "A", keeps: TabViewKeeps(panes: 1)),
                    TabView(id: "b", name: "B", keeps: TabViewKeeps(panes: 2)),
                ]
            }
            let views = ViewsWindowController(views: SharedFolderViews(), open: { _ in })
            defer { views.close() }
            views.present(.tabViews, explorer: tab)
            let pane: SavedViewsPane = views.tabViewsPane
            pane.reload()
            #expect(pane.newTabsPopUp.itemTitles == ["None", "A", "B"])
            pane.chooseNewTabView(at: 2)
            #expect(tab.preferences.newTabViewID == "b")
            #expect(pane.rows[1].keeps.hasPrefix("New tabs"))
            pane.chooseNewTabView(at: 0)
            #expect(tab.preferences.newTabViewID == nil)
        }

        @Test func windowViewsListTheirTabsTabViewsByName() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences {
                $0.tabViews = [TabView(id: "a", name: "Compare", keeps: TabViewKeeps(panes: 2))]
                $0.windowViews = [WindowView(id: "w1", name: "Work", tabs: ["a", nil], frontTab: 1)]
            }
            let views = ViewsWindowController(views: SharedFolderViews(), open: { _ in })
            defer { views.close() }
            views.present(.windowViews, explorer: tab)
            let pane: SavedViewsPane = views.windowViewsPane
            pane.reload()
            #expect(pane.rows.map(\.key) == ["⌃⌘1"])
            #expect(pane.rows[0].keeps == "2 tabs \u{00B7} 1: Compare \u{00B7} 2: New tab \u{00B7} Tab 2 in front")
        }
    }
}
