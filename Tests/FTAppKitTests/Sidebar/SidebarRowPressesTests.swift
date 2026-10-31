// Ports the press, focus and scroll cases of components/TreePane.test.tsx, TreePane.rows.test.tsx and the Tab case of
// App.menusAndTree.test.tsx: each test presses the row's list as the window does, with the sidebar's clock moved by hand
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension SidebarTesting {
    /// A press and release on the row, as the window hands them to its list, `count` times over.
    func press(
        _ cell: SidebarItemCell, count: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) throws {
        let outline = try #require(enclosingOutline(cell))
        let window = try #require(outline.window)
        let point = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
        for number in 1...count {
            outline.mouseDown(
                with: try #require(
                    MouseEvents.event(.leftMouseDown, at: point, in: window, clickCount: number, modifiers: modifiers)))
            outline.mouseUp(
                with: try #require(
                    MouseEvents.event(.leftMouseUp, at: point, in: window, clickCount: number, modifiers: modifiers)))
        }
    }

    /// A press on a place of the list's outline, in its own coordinates.
    func pressOutline(_ outline: SidebarOutlineView, at point: NSPoint) throws {
        let window = try #require(outline.window)
        outline.mouseDown(
            with: try #require(MouseEvents.event(.leftMouseDown, at: outline.convert(point, to: nil), in: window)))
    }

    func chevron(_ cell: SidebarItemCell) throws -> SidebarChevronView {
        try #require(
            cell.box.subviews.first { $0.accessibilityIdentifier() == "sidebar.row.chevron" } as? SidebarChevronView)
    }

    /// The sidebar's timers wait for the clock.
    func handClock(_ controller: SidebarViewController) -> HandScheduler {
        let clock = HandScheduler()
        controller.model.schedule = { milliseconds, fire in
            clock.schedule(afterMilliseconds: Double(milliseconds), fire)
        }
        return clock
    }

    func row(
        _ path: String, _ kind: TreeItemKind = .filesystem, in controller: SidebarViewController
    ) throws -> SidebarItemCell {
        try #require(cells(controller).first { $0.state?.item.path == path && $0.state?.item.kind == kind }, "\(path)")
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SidebarRowPressesTests: SidebarTesting {
        private struct Opened {
            let harness: ExplorerHarness
            let tab: MainWindowController
            let controller: SidebarViewController
            let clock: HandScheduler
        }

        /// A tab on the harness's folder with the tree rooted there and the sidebar's clock in hand.
        private func open(folders: [String] = []) async throws -> Opened {
            let harness = try ExplorerHarness.windowless()
            for name in folders {
                try FileManager.default.createDirectory(
                    at: harness.folder.appending(name), withIntermediateDirectories: true)
            }
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            let controller = sidebar(tab)
            #expect(await waitUntil { self.labels(controller).contains("Beta") })
            return Opened(harness: harness, tab: tab, controller: controller, clock: handClock(controller))
        }

        // MARK: Clicks

        // B-TREE-052
        @Test func aClickOpensTheRowAfterTheDelayAndAnotherClickStartsItAgain() async throws {
            let opened = try await open()
            let (tab, controller, clock) = (opened.tab, opened.controller, opened.clock)
            let root = tab.shownFolderPath
            let alpha = listed(opened.harness, "Alpha")
            let steps = tab.navigationHistory.paths.count

            try press(try row(alpha, in: controller))
            clock.advance(179)
            await settle()
            #expect(tab.shownFolderPath == root)
            #expect(controller.model.selected != .filesystem(alpha))
            // Another click in the 180 ms: the time starts again from it.
            try press(try row(alpha, in: controller))
            clock.advance(179)
            await settle()
            #expect(controller.model.selected != .filesystem(alpha))
            #expect(tab.shownFolderPath == root)
            clock.advance(1)
            #expect(controller.model.selected == .filesystem(alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            #expect(tab.navigationHistory.paths.count == steps + 1)
            await opened.harness.close()
        }

        // T-f872fab2
        @Test func aSingleClickExpandsTheFolderOnlyWithTheSettingOn() async throws {
            let opened = try await open()
            let (tab, controller, clock) = (opened.tab, opened.controller, opened.clock)
            let alpha = listed(opened.harness, "Alpha")
            let beta = listed(opened.harness, "Beta")

            try press(try row(alpha, in: controller))
            clock.advance(180)
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            #expect(controller.model.nodes[alpha]?.expanded == false)

            tab.updatePreferences(["singleClickExpandTreeItems": .bool(true)])
            tab.preferencesChanged(PreferencesChange(patch: [:], senderID: nil))
            #expect(controller.model.singleClickExpand)
            try press(try row(beta, in: controller))
            #expect(controller.model.nodes[beta]?.expanded == false)
            clock.advance(180)
            #expect(controller.model.selected == .filesystem(beta))
            #expect(await waitUntil { controller.model.nodes[beta]?.expanded == true })
            #expect(await waitUntil { tab.shownFolderPath == beta })
            await opened.harness.close()
        }

        // B-TREE-054 T-c018e887
        @Test func aDoubleClickOnAFolderTogglesAndOpensItOnce() async throws {
            let opened = try await open()
            let (tab, controller, clock) = (opened.tab, opened.controller, opened.clock)
            let alpha = listed(opened.harness, "Alpha")
            let steps = tab.navigationHistory.paths.count

            try press(try row(alpha, in: controller), count: 2)
            #expect(await waitUntil { controller.model.nodes[alpha]?.expanded == true })
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            // The first click's time was called off, as was the second's.
            clock.advance(1000)
            await settle()
            #expect(controller.model.nodes[alpha]?.expanded == true)
            #expect(tab.navigationHistory.paths.count == steps + 1)
            await opened.harness.close()
        }

        // B-TREE-054 T-9371df14
        @Test func aDoubleClickOnAFavoriteOpensItOnceAndExpandsNothing() async throws {
            let opened = try await open()
            let (tab, controller, clock) = (opened.tab, opened.controller, opened.clock)
            let gamma = listed(opened.harness, "Gamma")
            await setPlacement(tab, "separate", opened.harness)
            controller.toggleFavorite(gamma)
            opened.harness.layout(tab)
            let steps = tab.navigationHistory.paths.count
            let expanded = controller.model.nodes.all.filter(\.expanded).map(\.path)

            try press(try row(gamma, .favorite, in: controller), count: 2)
            #expect(await waitUntil { tab.shownFolderPath == gamma })
            #expect(controller.model.selected == .favorite(gamma))
            clock.advance(1000)
            await settle()
            #expect(tab.navigationHistory.paths.count == steps + 1)
            #expect(controller.model.nodes[gamma]?.expanded != true)
            #expect(controller.model.nodes.all.filter(\.expanded).map(\.path) == expanded)
            await opened.harness.close()
        }

        // MARK: ⌘-click

        // B-TREE-057 T-83af561d
        @Test func aCommandClickOpensTheFolderInANewTabAndLeavesThisOneAlone() async throws {
            let opened = try await open()
            let (tab, controller, clock) = (opened.tab, opened.controller, opened.clock)
            let group = try #require(tab.group)
            let beta = listed(opened.harness, "Beta")
            let (selected, history, shown) = (
                controller.model.selected, tab.navigationHistory.paths, tab.shownFolderPath
            )

            try press(try row(beta, in: controller), modifiers: .command)
            #expect(group.tabs.count == 2)
            let new = try #require(group.tabs.last)
            #expect(new !== tab)
            #expect(new.folder.path == beta)
            // No click is waiting to open it here too.
            clock.advance(1000)
            await settle()
            #expect(controller.model.selected == selected)
            #expect(tab.navigationHistory.paths == history)
            #expect(tab.shownFolderPath == shown)
            await opened.harness.close()
        }

        // B-TREE-057: nothing while a dialog holds the tabs.
        @Test func aCommandClickOpensNoTabWhileADialogIsUp() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            let group = try #require(tab.group)
            let target = try row(listed(opened.harness, "Beta"), in: controller)
            tab.perform(.openLocationSheet)
            #expect(tab.goToBox != nil)

            try press(target, modifiers: .command)
            #expect(group.tabs.count == 1)
            await opened.harness.close()
        }

        // B-TREE-057: at the limit the notice says why.
        @Test func aCommandClickAtTheTabLimitTellsTheLimit() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            let group = try #require(tab.group)
            group.addTabs(Array(repeating: tab.openTab, count: AppPreferenceLimits.openTabsLimit))
            #expect(group.tabs.count == AppPreferenceLimits.openTabsLimit)
            var told: [WindowNotice] = []
            opened.harness.windows.showNotice = { notice, _ in told.append(notice) }

            try press(try row(listed(opened.harness, "Beta"), in: controller), modifiers: .command)
            #expect(group.tabs.count == AppPreferenceLimits.openTabsLimit)
            #expect(told == [.tabLimit])
            await opened.harness.close()
        }

        // MARK: Empty space

        // T-c0357324: a press in the separate list's empty space lets go of the folder on screen.
        @Test func aPressBelowTheRowsOfTheSeparateListClearsTheSelection() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            await setPlacement(tab, "separate", opened.harness)
            let alpha = listed(opened.harness, "Alpha")
            controller.toggleFavorite(alpha)
            controller.model.selectItem(.favorite(alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            opened.harness.layout(tab)

            let outline = controller.sections.outline
            let last = outline.rect(ofRow: outline.numberOfRows - 1)
            try pressOutline(outline, at: NSPoint(x: last.midX, y: last.maxY + 400))
            #expect(controller.model.selected == nil)
            #expect(await waitUntil { tab.shownFolderPath.isEmpty })
            await opened.harness.close()
        }

        // B-TREE-028: and a press beside a header's button.
        @Test func aPressBesideAHeadersButtonClearsTheSelection() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            await setPlacement(tab, "separate", opened.harness)
            let alpha = listed(opened.harness, "Alpha")
            controller.toggleFavorite(alpha)
            controller.model.selectItem(.favorite(alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            opened.harness.layout(tab)

            let list = controller.sections
            let outline = list.outline
            let header = try #require(
                (0..<outline.numberOfRows).first {
                    if case .header = list.row(at: $0) { return true }
                    return false
                })
            let rect = outline.rect(ofRow: header)
            try pressOutline(outline, at: NSPoint(x: rect.minX + 1, y: rect.midY))
            #expect(controller.model.selected == nil)
            await opened.harness.close()
        }

        // T-6f692b35: and a press on the spacer at the top of the list favorites are rows of.
        @Test func aPressOnASpacerOfTheListClearsTheSelection() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            await setPlacement(tab, "integrated", opened.harness)
            let alpha = listed(opened.harness, "Alpha")
            controller.toggleFavorite(alpha)
            controller.model.selectItem(.favorite(alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            opened.harness.layout(tab)

            let outline = controller.tree.outline
            controller.tree.scrollTop = 0
            guard case .spacer? = controller.tree.row(at: 0) else {
                Issue.record("the list starts with a spacer")
                return
            }
            let spacer = outline.rect(ofRow: 0)
            try pressOutline(outline, at: NSPoint(x: spacer.midX, y: spacer.midY))
            #expect(controller.model.selected == nil)
            #expect(await waitUntil { tab.shownFolderPath.isEmpty })
            await opened.harness.close()
        }

        // MARK: The chevron

        // B-TREE-070 T-945f8c88: a folder's chevron opens the branch and changes nothing else.
        @Test func theChevronTogglesTheBranchWithoutSelectingOrOpening() async throws {
            let opened = try await open()
            let (tab, controller, clock) = (opened.tab, opened.controller, opened.clock)
            let alpha = listed(opened.harness, "Alpha")
            let (selected, shown) = (controller.model.selected, tab.shownFolderPath)

            let closed = try row(alpha, in: controller)
            #expect(try chevron(closed).isEnabled)
            #expect(try chevron(closed).toolTip == "Expand Folder")
            #expect(try chevron(closed).accessibilityLabel() == "Expand Folder")
            try chevron(closed).onClick?()
            #expect(await waitUntil { controller.model.nodes[alpha]?.expanded == true })
            opened.harness.layout(tab)
            let open = try row(alpha, in: controller)
            #expect(try chevron(open).toolTip == "Collapse Folder")
            clock.advance(1000)
            await settle()
            #expect(controller.model.selected == selected)
            #expect(tab.shownFolderPath == shown)
            await opened.harness.close()
        }

        // B-TREE-070 T-945f8c88: an alias of a folder has nothing to open, so its chevron is disabled.
        @Test func anAliasRowsChevronIsDisabledWithNoSubfolders() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createSymbolicLink(
                at: harness.folder.appending("Alias"), withDestinationURL: harness.folder.appending("Beta"))
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            let controller = sidebar(tab)
            let alias = listed(harness, "") + "/Alias"
            #expect(await waitUntil { self.labels(controller).contains("Alias") })
            let cell = try row(alias, in: controller)
            #expect(cell.state?.item.canExpand == false)
            #expect(try !chevron(cell).isEnabled)
            #expect(try chevron(cell).toolTip == "No subfolders")
            await harness.close()
        }

        // B-TREE-070: the headings say their section, an empty Favorites that there are none, and a row being read waits.
        @Test func aHeadingsChevronNamesItsSectionAndAnEmptyOneSaysSo() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            await setPlacement(tab, "integrated", opened.harness)
            func heading(_ kind: TreeItemKind) throws -> SidebarItemCell {
                try #require(cells(controller).first { $0.state?.item.kind == kind })
            }
            #expect(try chevron(heading(.favoritesRoot)).toolTip == "Collapse Favorites")
            #expect(try chevron(heading(.locationsRoot)).toolTip == "Collapse Locations")
            #expect(try chevron(heading(.locationsRoot)).accessibilityLabel() == "Collapse Locations")
            try chevron(heading(.favoritesRoot)).onClick?()
            await settle()
            opened.harness.layout(tab)
            #expect(!controller.model.favoritesExpanded)
            #expect(try chevron(heading(.favoritesRoot)).toolTip == "Expand Favorites")
            try chevron(heading(.favoritesRoot)).onClick?()
            await settle()

            tab.updatePreferences(["favorites": .array([])])
            tab.preferencesChanged(PreferencesChange(patch: [:], senderID: nil))
            await settle()
            opened.harness.layout(tab)
            let empty = try heading(.favoritesRoot)
            #expect(try chevron(empty).toolTip == "No favorites")
            #expect(try !chevron(empty).isEnabled)

            let folder = try row(listed(opened.harness, "Alpha"), in: controller)
            var state = try #require(folder.state)
            state.item.loading = true
            folder.configure(state, width: Double(folder.bounds.width))
            #expect(try !chevron(folder).isEnabled)
            await opened.harness.close()
        }

        // MARK: The keyboard

        // T-fda19010
        @Test func theSidebarIsFocusedWhileEitherOfItsListsHasTheKeyboard() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            await setPlacement(tab, "separate", opened.harness)
            let window = try #require(tab.window)

            #expect(window.makeFirstResponder(controller.tree.outline))
            #expect(controller.isFocused)
            controller.model.type("a")
            #expect(controller.typeaheadQuery == "a")
            // To the other list: the sidebar never lost it.
            #expect(window.makeFirstResponder(controller.sections.outline))
            await settle()
            try? await Task.sleep(for: .milliseconds(20))
            #expect(controller.isFocused)
            #expect(controller.typeaheadQuery == "a")

            tab.content.focusList()
            #expect(await waitUntil { !controller.isFocused })
            #expect(controller.typeaheadQuery.isEmpty)
            await opened.harness.close()
        }

        // B-TREE-118 T-6ab02fc0
        @Test func tabAndShiftTabGoBetweenTheSidebarAndTheListAndOtherModifiersDoNot() async throws {
            let opened = try await open()
            let (tab, controller) = (opened.tab, opened.controller)
            let window = try #require(tab.window)
            let tabKey: UInt16 = 48

            func fromTree(_ modifiers: NSEvent.ModifierFlags) {
                tab.perform(.focusTreePane)
                #expect(tab.focusedPane == .tree)
                key(tabKey, "\t", modifiers: modifiers, in: window)
            }
            fromTree([])
            #expect(tab.focusedPane == .content)
            fromTree(.shift)
            #expect(tab.focusedPane == .content)
            fromTree(.option)
            #expect(tab.focusedPane == .tree)
            fromTree(.control)
            #expect(tab.focusedPane == .tree)

            // From the list it goes to the sidebar.
            tab.content.focusList()
            #expect(tab.focusedPane == .content)
            key(tabKey, "\t", in: window)
            #expect(tab.focusedPane == .tree)
            #expect(controller.isFocused)

            // With the sidebar hidden it stays with the list.
            tab.content.focusList()
            tab.updatePanels { $0.folderTreeOpen = false }
            opened.harness.layout(tab)
            key(tabKey, "\t", in: window)
            #expect(tab.focusedPane == .content)
            await opened.harness.close()
        }
    }

    // MARK: Scrolling to the selection

    @MainActor
    @Suite struct SidebarHandToggleScrollTests: SidebarTesting {
        private static let names = (0..<80).map { String(format: "f%02d", $0) }

        /// A tree longer than the window, with its last row selected, scrolled by hand to the top.
        private func open() async throws -> (ExplorerHarness, MainWindowController, HandScheduler) {
            let harness = try ExplorerHarness.windowless()
            for name in Self.names {
                try FileManager.default.createDirectory(
                    at: harness.folder.appending(name), withIntermediateDirectories: true)
            }
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            await setPlacement(tab, "integrated", harness)
            let controller = sidebar(tab)
            let clock = handClock(controller)
            let last = listed(harness, "f79")
            #expect(await waitUntil { controller.model.nodes[last] != nil })
            harness.layout(tab)
            controller.model.selectItem(.filesystem(last))
            #expect(await waitUntil { tab.shownFolderPath == last })
            harness.layout(tab)
            #expect(controller.tree.scrollTop > 0)
            return (harness, tab, clock)
        }

        private func selectedRowIsInView(_ controller: SidebarViewController) throws -> Bool {
            let selected = try #require(controller.model.selected)
            return controller.tree.isFullyVisible(try #require(controller.tree.index(ofItem: selected)))
        }

        // B-TREE-138 T-e11a44ff
        @Test func aSectionToggledByHandLeavesTheScrollForTheSettleTimeOnly() async throws {
            let (harness, tab, clock) = try await open()
            let controller = sidebar(tab)
            controller.tree.scrollTop = 0
            #expect(try !selectedRowIsInView(controller))

            controller.model.toggleFavorites()
            harness.layout(tab)
            #expect(controller.tree.scrollTop == 0)
            clock.advance(1499)
            controller.model.toggleFavorites()
            harness.layout(tab)
            #expect(controller.tree.scrollTop == 0)

            // Past the time since the last toggle, a change of rows that isn't a toggle by hand scrolls to the selection.
            clock.advance(1500)
            tab.perform(.toggleHiddenFiles)
            // The row is gone for a moment while the tree is rebuilt, which `#require` would record as a failure.
            #expect(
                await waitUntil {
                    guard let selected = controller.model.selected, let row = controller.tree.index(ofItem: selected)
                    else { return false }
                    return controller.tree.isFullyVisible(row)
                })
            await harness.close()
        }

        // T-e4d47b84
        @Test func theFirstSectionToggledAfterATabComesBackLeavesTheScroll() async throws {
            let (harness, tab, _) = try await open()
            let group = try #require(tab.group)
            // A copy comes forward with the sidebar kept where this tab left it, its row out of sight above.
            sidebar(tab).tree.scrollTop = 0
            group.duplicateTab(tab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let copy = try #require(group.tabs.last)
            copy.servicesOverride = tab.servicesOverride
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                copy.whenFirstReadFinished { _ in done.resume() }
            }
            harness.layout(copy)
            let controller = sidebar(copy)
            _ = handClock(controller)
            #expect(await waitUntil { !controller.holdsScrollPosition })
            #expect(controller.tree.scrollTop == 0)
            #expect(try !selectedRowIsInView(controller))

            controller.model.toggleFavorites()
            harness.layout(copy)
            #expect(controller.tree.scrollTop == 0)
            await harness.close()
        }

        // T-7074ac30
        @Test func hiddenFilesMovingTheSelectedRowOffScreenBringItBack() async throws {
            let harness = try ExplorerHarness.windowless()
            // Hidden folders come ahead of the first row: shown, they push it out of the list.
            for index in 0..<60 {
                try FileManager.default.createDirectory(
                    at: harness.folder.appending(String(format: ".h%02d", index)), withIntermediateDirectories: true)
            }
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            await setPlacement(tab, "separate", harness)
            let controller = sidebar(tab)
            let gamma = listed(harness, "Gamma")
            #expect(await waitUntil { controller.model.nodes[gamma] != nil })
            controller.model.selectItem(.filesystem(gamma))
            #expect(await waitUntil { tab.shownFolderPath == gamma })
            harness.layout(tab)
            #expect(try selectedRowIsInView(controller))
            let top = controller.tree.scrollTop

            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { controller.model.nodes[listed(harness, ".h59")] != nil })
            harness.layout(tab)
            #expect(try selectedRowIsInView(controller))
            #expect(controller.tree.scrollTop > top)
            await harness.close()
        }
    }
}
