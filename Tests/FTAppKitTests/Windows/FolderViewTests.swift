import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// A folder's own view (View ▸ Folder View): laid over what the pane carries while it shows the folder, changed on
    /// screen until Update, and covering the folders inside when asked.
    @MainActor
    @Suite struct FolderViewTests {
        private func real(_ harness: ExplorerHarness, _ name: String) -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func go(_ tab: MainWindowController, _ harness: ExplorerHarness, _ name: String) async {
            await tab.navigate(to: URL(fileURLWithPath: real(harness, name)))
            #expect(await waitUntil { !tab.isNavigating })
        }

        @Test func aRememberedFolderShowsItsViewAndLeavingItPutsBackWhatThePaneCarries() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            #expect(pane.shownFolderView?.use.own == true)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .own)

            // Leaving: Previews was chosen in Alpha before Alpha was customized, so it is Alpha's alone; the pane shows
            // what it carried as it came into Alpha.
            await go(tab, harness, "Beta")
            #expect(pane.viewMode == .icons)
            #expect(pane.content.mode == .icons)
            #expect(pane.shownFolderView == nil)
            // The symbol stays, faint, and opens the options.
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .noView)
            tab.setMode(.details)
            await go(tab, harness, "Alpha")
            #expect(pane.shownMode == .previews)
            #expect(pane.content.mode == .previews)
            await go(tab, harness, "Gamma")
            #expect(pane.content.mode == .details)
        }

        @Test func aChangeIsOnScreenUntilUpdateAndLeavingDropsIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.perform(.rememberFolderView)
            tab.setMode(.details)
            #expect(pane.shownFolderView?.unsaved == [.view])
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == true)
            #expect(tab.canPerform(.updateFolderView))
            // The pane carries nothing of it.
            #expect(pane.viewMode == .icons)
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .icons)

            // Changed back by hand: no change.
            tab.setMode(.icons)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false)
            tab.setMode(.details)
            await go(tab, harness, "Beta")
            await go(tab, harness, "Alpha")
            #expect(pane.shownMode == .icons)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false)

            tab.setMode(.details)
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .details)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false)
            tab.setMode(.list)
            tab.perform(.revertFolderView)
            #expect(pane.shownMode == .details)
        }

        @Test func aViewCoversTheFoldersInsideAndKeepForThisFolderOnlyGivesOneItsOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            pane.setFolderViewSubfolders(true)
            #expect(pane.shownFolderView?.subfoldersUnsaved == true)
            tab.perform(.updateFolderView)

            await go(tab, harness, "Alpha/Inner")
            #expect(pane.shownFolderView?.use.own == false)
            #expect(pane.shownMode == .previews)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .above)
            // Reset does nothing in a folder with no view of its own.
            #expect(!tab.canPerform(.resetFolderView))

            // Apply to Subfolders is Alpha's: off here until changed. Nothing changed, Save does nothing.
            #expect(pane.shownFolderView?.shownSubfolders == false)
            pane.updateFolderView()
            #expect(pane.folderViews.views.own(real(harness, "Alpha/Inner")) == nil)
            // A change here is Inner's own once saved; Alpha is changed in Alpha.
            tab.setMode(.details)
            #expect(pane.shownFolderView?.hasUnsavedChanges == true)
            pane.updateFolderView()
            let inner = try #require(pane.folderViews.views.own(real(harness, "Alpha/Inner")))
            #expect(inner.keeps.view == .details)
            #expect(!inner.subfolders)
            // Alpha's own is as it was.
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .previews)
            #expect(pane.shownFolderView?.use.own == true)

            // Reset: Inner uses Alpha's again.
            tab.perform(.resetFolderView)
            #expect(pane.shownFolderView?.use.own == false)
            #expect(pane.shownMode == .previews)
        }

        @Test func aKeptOrderIsTheOrderTheFolderIsReadIn() async throws {
            let harness = try ExplorerHarness.windowless()
            for name in ["b.txt", "a.txt", "c.txt"] {
                try "x".write(to: harness.folder.appending("Beta/\(name)"), atomically: false, encoding: .utf8)
            }
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Beta")
            pane.setFolderViewValue(.sort) { $0.sort = FolderViewSort(by: .name, direction: .desc) }
            pane.setFolderViewValue(.foldersFirst) { $0.foldersFirst = false }
            #expect(pane.shownFolderView?.isDraft == true)
            // Read again in that order.
            #expect(await waitUntil { pane.content.entries.map(\.name) == ["Inner", "c.txt", "b.txt", "a.txt"] })
            // The pane's own order is still Name, ascending.
            #expect(pane.sortBy == .name && pane.sortDirection == .asc)
            tab.perform(.updateFolderView)
            #expect(pane.shownFolderView?.isOwnSaved == true)
            await go(tab, harness, "Alpha")
            await go(tab, harness, "Beta")
            #expect(pane.content.entries.map(\.name) == ["Inner", "c.txt", "b.txt", "a.txt"])
        }

        @Test func aColumnShownInAFolderThatKeepsItsColumnsIsAChangeOfItsView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            #expect(!tab.preferences.detailColumns.permissions)
            tab.perform(.showPermissionsColumn)
            // No folder view here: every folder's columns change.
            #expect(tab.preferences.detailColumns.permissions)
            tab.perform(.showPermissionsColumn)

            tab.keepColumns(true, in: pane)
            tab.perform(.showPermissionsColumn)
            #expect(!tab.preferences.detailColumns.permissions)
            #expect(pane.shownFolderView?.unsaved == [.columns])
            #expect(tab.shownColumns.contains(.permissions))
            await go(tab, harness, "Beta")
            #expect(!tab.shownColumns.contains(.permissions))
        }

        @Test func sizesAndColumnWidthsSetInAFolderThatKeepsThemAreItsOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            pane.setFolderViewKeeps(.size, true)
            pane.setFolderViewKeeps(.columns, true)
            pane.content.onIconSizeChanged?(.standard, 96)
            pane.content.onCompactListWidthChanged?(.standard, 400)
            var widths = Dictionary(uniqueKeysWithValues: DetailColumn.allCases.map { ($0, 150.0) })
            widths[.name] = 333
            pane.content.onColumnWidthsChanged?(widths)
            #expect(Set(pane.shownFolderView?.unsaved ?? []) == [.size, .columns])
            // The app's and the pane's are as they were.
            #expect(tab.preferences.iconSizes[.standard] != 96)
            #expect(tab.preferences.detailColumnWidths[.name] != 333)
            tab.perform(.updateFolderView)

            let saved = try #require(pane.folderViews.views.own(real(harness, "Alpha")))
            #expect(saved.keeps.size?.iconSizes[.standard] == 96)
            #expect(saved.keeps.size?.compactListWidths[.standard] == 400)
            #expect(saved.keeps.columns?.widths[.name] == 333)
            await go(tab, harness, "Beta")
            #expect(pane.shownPreferences(tab.preferences).iconSizes[.standard] != 96)
            await go(tab, harness, "Alpha")
            let shown = pane.shownPreferences(tab.preferences)
            #expect(shown.iconSizes[.standard] == 96 && shown.compactListWidths[.standard] == 400)
            #expect(shown.detailColumnWidths[.name] == 333)
        }

        @Test func aViewSavedInOneTabShowsInAnotherOnTheSameFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            await go(first, harness, "Alpha")
            first.setMode(.icons)
            let group = try #require(first.group)
            group.duplicateTab(first)
            #expect(await waitUntil { group.tabs.count == 2 })
            let second = group.tabs[1]
            second.servicesOverride = first.servicesOverride
            #expect(await waitUntil { second.activePane.loaded && !second.isNavigating })
            harness.services.folderViews.onChanged = { [weak first, weak second] _ in
                first?.folderViewsChanged()
                second?.folderViewsChanged()
            }
            first.setMode(.previews)
            first.perform(.rememberFolderView)
            #expect(second.activePane.shownFolderView?.use.own == true)
            #expect(second.activePane.shownMode == .previews)
        }

        @Test func aColumnShownTakesItsStandardPlaceAmongThoseShown() {
            // The order saved before the standard one changed: Date Created after Kind.
            let saved: [OptionalDetailColumnKey] = [
                .modified, .size, .kind, .created, .added, .lastOpened, .permissions,
            ]
            var shown: Set<OptionalDetailColumnKey> = [.modified, .size, .kind]
            func show(_ key: OptionalDetailColumnKey, in order: [OptionalDetailColumnKey]) -> [OptionalDetailColumnKey]
            {
                shown.insert(key)
                return ColumnOrder.showing(
                    key, in: order, isShown: { shown.contains($0) }, standard: OptionalDetailColumnKey.menuOrder)
            }
            var order = show(.created, in: saved)
            order = show(.lastOpened, in: order)
            order = show(.added, in: order)
            #expect(order.filter(shown.contains) == [.modified, .created, .lastOpened, .added, .size, .kind])
            // Moved by hand, Size stays first; a column shown later goes right after its standard neighbour.
            shown = [.modified, .size]
            order = ColumnOrder.placing(.size, before: .modified, in: OptionalDetailColumnKey.menuOrder)
            order = show(.kind, in: order)
            #expect(order.filter(shown.contains) == [.size, .kind, .modified])
            // With none before it shown, it comes first, after Name.
            shown = [.kind]
            #expect(show(.modified, in: [.kind, .modified]).filter(shown.contains) == [.modified, .kind])
        }

        @Test func aSettingTheFolderKeepsFromNowGoesBackToWhatThePaneCarriedAsItCameIn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            // Changed here with no customization: the pane's, until Alpha keeps it.
            tab.setMode(.details)
            #expect(pane.viewMode == .details)
            pane.setFolderViewKeeps(.view, true)
            // Not saved yet: the pane still carries it.
            #expect(pane.viewMode == .details)
            tab.perform(.updateFolderView)
            // Alpha keeps List; the pane carries Icons again.
            #expect(pane.viewMode == .icons)
            #expect(pane.shownMode == .details)
            await go(tab, harness, "Beta")
            #expect(pane.content.mode == .icons)
        }

        @Test func columnOrderMovesAmongTheColumnsShownAndNameStaysFirst() {
            let order: [OptionalDetailColumnKey] = [.modified, .size, .kind, .created, .permissions]
            var visible = DetailColumnVisibility.defaults
            visible.permissions = true
            // Created is hidden: Kind and Permissions are neighbours.
            #expect(
                ColumnOrder.moving(.kind, by: 1, in: order, visible: visible)
                    == [.modified, .size, .permissions, .created, .kind])
            #expect(ColumnOrder.moving(.modified, by: -1, in: order, visible: visible) == nil)
            #expect(ColumnOrder.moving(.permissions, by: 1, in: order, visible: visible) == nil)
            #expect(
                ColumnOrder.placing(.kind, before: .modified, in: order) == [
                    .kind, .modified, .size, .created, .permissions,
                ])
            #expect(
                ColumnOrder.placing(.modified, before: nil, in: order) == [
                    .size, .kind, .created, .permissions, .modified,
                ])
        }

        @Test func theFolderViewsWindowListsEachFolderUnderTheOneAboveAndRemovesTheOnesSelected() throws {
            _ = NSApplication.shared
            let shared = SharedFolderViews()
            let home = NSHomeDirectory()
            let app = home + "/Projects/App"
            shared.update(from: nil) {
                $0.set(
                    FolderView(
                        path: home, subfolders: true,
                        keeps: FolderViewKeeps(view: .previews, sort: FolderViewSort(by: .modified, direction: .desc))))
                $0.set(FolderView(path: "/nowhere/Old Scans", keeps: FolderViewKeeps(foldersFirst: false)))
                $0.set(FolderView(path: app + "/Sources", keeps: FolderViewKeeps(view: .details)))
                $0.set(FolderView(path: app, keeps: FolderViewKeeps(view: .list)))
            }
            var opened: [String] = []
            let window = FolderViewsWindowController(views: shared, open: { opened.append($0) })
            window.reload()
            // Each under the nearest customized folder above it; the home folder's first.
            #expect(window.shownRows.map(\.path) == [home, app, app + "/Sources", "/nowhere/Old Scans"])
            #expect(window.shownLevels == [0, 1, 2, 0])
            let tree = FolderViewNode.tree(shared.views.all)
            let summaries = [
                FolderViewsWindowController.summary(tree[0].view),
                FolderViewsWindowController.summary(tree[0].children[0].view),
                FolderViewsWindowController.summary(tree[1].view),
            ]
            #expect(summaries[0].path == "~" && summaries[0].tags == ["View", "Sort"] && summaries[0].subfolders)
            #expect(summaries[0].missing == nil)
            #expect(summaries[1].name == "App" && summaries[1].path == "~/Projects/App")
            #expect(summaries[2].name == "Old Scans" && summaries[2].tags == ["Folders First"])
            #expect(summaries[2].missing == "Not Found")
            #expect(!window.removeButton.isEnabled)

            window.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(window.showButton.isEnabled)
            window.pressShow()
            #expect(opened == [home])
            // A folder that isn't there can't be shown, only removed.
            window.tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            #expect(!window.showButton.isEnabled)
            window.pressRemove()
            #expect(shared.views.all.map(\.path) == [home, app, app + "/Sources"])
            // The window follows the views however they change: with the home folder's gone, App is at the top.
            window.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            window.pressRemove()
            #expect(window.shownRows.map(\.path) == [app, app + "/Sources"])
            #expect(window.shownLevels == [0, 1])
        }

        @Test func removeLeavesTheFoldersInsideAndRemoveWithSubfoldersTakesOnlyThoseInsideTheSelected() throws {
            _ = NSApplication.shared
            let shared = SharedFolderViews()
            let paths = [
                "/nowhere/r1", "/nowhere/r1/a", "/nowhere/r1/a/b", "/nowhere/r1/z", "/nowhere/r1x", "/nowhere/r2",
                "/nowhere/r2/c", "/nowhere/r3",
            ]
            shared.update(from: nil) { views in
                for path in paths { views.set(FolderView(path: path, keeps: FolderViewKeeps(view: .list))) }
            }
            let window = FolderViewsWindowController(views: shared, open: { _ in })
            window.reload()
            func select(_ selected: [String]) {
                let rows = window.shownRows.enumerated().filter { selected.contains($0.element.path) }.map(\.offset)
                window.tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            }
            // A folder with nothing customized inside it: Remove with Subfolders has nothing more to do.
            select(["/nowhere/r3"])
            #expect(window.removeButton.isEnabled && !window.removeWithSubfoldersButton.isEnabled)

            // Remove: the folders inside keep theirs, and move up a level.
            select(["/nowhere/r2"])
            #expect(window.removeWithSubfoldersButton.isEnabled)
            window.pressRemove()
            #expect(shared.views.all.map(\.path).contains("/nowhere/r2/c"))
            #expect(!shared.views.all.map(\.path).contains("/nowhere/r2"))

            // Two selected under different roots: each with what is inside it, and nothing above, beside or merely
            // named alike (r1x is not inside r1).
            select(["/nowhere/r1/a", "/nowhere/r2/c"])
            window.pressRemoveWithSubfolders()
            #expect(
                shared.views.all.map(\.path) == ["/nowhere/r1", "/nowhere/r1/z", "/nowhere/r1x", "/nowhere/r3"])
        }

        @Test func escClosesTheFolderViewsWindow() throws {
            _ = NSApplication.shared
            let window = FolderViewsWindowController(views: SharedFolderViews(), open: { _ in })
            window.window?.orderFront(nil)
            #expect(window.window?.isVisible == true)
            window.window?.cancelOperation(nil)
            #expect(window.window?.isVisible == false)
            window.window?.orderFront(nil)
            let esc = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            window.tableView.keyDown(with: esc)
            #expect(window.window?.isVisible == false)
        }

        @Test func whatIsChangedInFolderCustomizationIsSavedOnlyWithSave() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            let alpha = real(harness, "Alpha")
            // A folder with no view: a Keep box makes one on screen, not saved.
            pane.setFolderViewKeeps(.view, true)
            pane.setFolderViewValue(.view) { $0.view = .previews }
            #expect(pane.shownMode == .previews)
            #expect(pane.shownFolderView?.isDraft == true)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == true)
            #expect(pane.folderViews.views.own(alpha) == nil)
            #expect(!tab.canPerform(.resetFolderView) && tab.canPerform(.updateFolderView))
            // Revert lets it go.
            tab.perform(.revertFolderView)
            #expect(pane.shownFolderView == nil)
            #expect(pane.shownMode == .icons)

            // Leaving drops it too.
            pane.setFolderViewValue(.view) { $0.view = .previews }
            await go(tab, harness, "Beta")
            await go(tab, harness, "Alpha")
            #expect(pane.shownFolderView == nil && pane.shownMode == .icons)

            // Save saves it, Apply to Subfolders with it.
            pane.setFolderViewValue(.view) { $0.view = .previews }
            pane.setFolderViewSubfolders(true)
            tab.perform(.updateFolderView)
            let saved = try #require(pane.folderViews.views.own(alpha))
            #expect(saved.keeps.view == .previews && saved.subfolders)
            #expect(pane.shownFolderView?.isOwnSaved == true && pane.shownFolderView?.hasUnsavedChanges == false)

            // Unchecking every box and Apply to Subfolders, then Save, removes it.
            pane.setFolderViewKeeps(.view, false)
            pane.setFolderViewSubfolders(false)
            #expect(pane.folderViews.views.own(alpha) != nil)
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(alpha) == nil)
            #expect(pane.shownFolderView == nil)
        }

        @Test func folderCustomizationShowsEachChangeMadeInIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            let popover = FolderViewPopover(pane: pane, tab: tab, dismiss: {})
            tab.folderViewPopover = popover
            defer { tab.folderViewPopover = nil }
            func control<T: NSView>(_ id: String, as type: T.Type) -> T? {
                func find(_ view: NSView) -> NSView? {
                    if view.accessibilityIdentifier() == id { return view }
                    return view.subviews.lazy.compactMap(find).first
                }
                return find(popover.contentView) as? T
            }
            // Nothing kept: the View pop-up is dimmed until its box is checked, by a click as a person makes it.
            #expect(control("folderViewPopover.view", as: NSPopUpButton.self)?.isEnabled == false)
            let keepView = try #require(control("folderViewPopover.keep.view", as: NSButton.self))
            keepView.performClick(nil)
            #expect(control("folderViewPopover.view", as: NSPopUpButton.self)?.isEnabled == true)
            #expect(control("folderViewPopover.update", as: NSButton.self)?.isEnabled == true)
            // A value chosen there is shown, and Save saves it.
            let views = try #require(control("folderViewPopover.view", as: NSPopUpButton.self))
            views.selectItem(withTitle: ExplorerViewMode.previews.menuName)
            _ = views.target?.perform(views.action, with: views)
            #expect(pane.shownMode == .previews)
            #expect(
                control("folderViewPopover.view", as: NSPopUpButton.self)?.titleOfSelectedItem
                    == ExplorerViewMode.previews.menuName)
            try #require(control("folderViewPopover.update", as: NSButton.self)).performClick(nil)
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .previews)
            #expect(control("folderViewPopover.update", as: NSButton.self)?.isEnabled == false)
        }

        @Test func resetInFolderCustomizationWaitsForSave() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            let alpha = real(harness, "Alpha")
            pane.clearFolderViewOnScreen()
            // The pane's settings show, and the customization is still saved.
            #expect(pane.shownMode == .icons)
            #expect(pane.folderViews.views.own(alpha) != nil)
            #expect(pane.shownFolderView?.hasUnsavedChanges == true)
            tab.perform(.revertFolderView)
            #expect(pane.shownMode == .previews)
            pane.clearFolderViewOnScreen()
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(alpha) == nil)
            #expect(pane.shownFolderView == nil && pane.shownMode == .icons)
        }

        @Test func folderCustomizationKeepsItsHeightWhateverTheView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            tab.perform(.rememberFolderView)
            let popover = FolderViewPopover(pane: pane, tab: tab, dismiss: {})
            var heights: Set<Double> = []
            for mode in ExplorerViewMode.menuOrder {
                pane.setFolderViewValue(.view) { $0.view = mode }
                popover.refresh()
                heights.insert(popover.contentView.frame.height)
                #expect(FolderViewPopover.settings(for: mode).count == 4)
            }
            #expect(heights.count == 1)
        }

        @Test func aChangedSizeSaysWhichOfItsSizesIsSaved() {
            let saved = FolderViewSizes(
                iconSizes: .iconDefaults, compactListWidths: .compactListDefaults, previewCounts: .previewCountDefaults)
            var shown = saved
            shown.previewCounts[.standard] = 9
            var view = FolderViewOnScreen(
                FolderViewUse(view: FolderView(path: "/a", keeps: FolderViewKeeps(size: saved)), own: true))
            view.shown.size = shown
            // In Icons, the icon size is the same: the Previews count is what changed.
            let text = FolderViewText.saved(.size, of: view, mode: .icons, density: .standard)
            #expect(text == "Saved: Previews \(saved.previewCounts[.standard]) at a time")
        }

        @Test func theSizeIsChosenFromEveryStepAndPreviewsByHowManyFit() {
            let previews = FolderViewPopover.sizeChoices(.previews, current: 4)
            #expect(
                previews.map(\.title) == [
                    "9 at a time (3 \u{00D7} 3)", "4 at a time (2 \u{00D7} 2)", "2 at a time (2 \u{00D7} 1)",
                    "1 at a time",
                ])
            let icons = FolderViewPopover.sizeChoices(.icons, current: 64)
            #expect(icons.first?.value == 32 && icons.last?.value == 128 && icons.count == 13)
            // A width between two steps (the Compact List's default) is among them.
            let widths = FolderViewPopover.sizeChoices(.list, current: 292).map(\.value)
            #expect(widths.contains(292) && widths.first == 160 && widths.last == 600)
            #expect(FolderViewPopover.sizeChoices(.details, current: 0).isEmpty)
        }
    }
}
