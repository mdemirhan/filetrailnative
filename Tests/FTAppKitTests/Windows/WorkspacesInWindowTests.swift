// Checks saving a window as a workspace and opening one, on the app's own windows, never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct WorkspacesInWindowTests {
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func workspaces(_ harness: ExplorerHarness) -> [Workspace] { harness.store.preferences().workspaces }

        /// Save Window as Workspace… with `name` typed and Return pressed.
        private func save(_ tab: MainWindowController, as name: String, in harness: ExplorerHarness) async throws {
            let window = try #require(tab.window)
            harness.windows.saveWorkspace(from: tab)
            #expect(await waitUntil { tab.frontAlert?.content.accessory is TextPromptAccessory })
            let prompt = try #require(tab.frontAlert?.content.accessory as? TextPromptAccessory)
            prompt.field.stringValue = name
            prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            DialogKeys.press(36, "\r", in: window)
            #expect(await waitUntil { !(tab.frontAlert?.content.accessory is TextPromptAccessory) })
        }

        /// A workspace of the window's session as it is saved now, with `tabs` in place of its own.
        private func workspace(
            _ id: String, _ name: String, of tab: MainWindowController, in harness: ExplorerHarness,
            tabs: [OpenTabPreference]? = nil
        ) throws -> Workspace {
            let group = try #require(tab.group)
            group.saveSession()
            let snapshot = try #require(harness.windows.controller.workspaceSnapshot(of: group.windowID))
            var session = snapshot.session
            if let tabs {
                session.openTabs = tabs
                session.activeTabIndex = 0
            }
            return Workspace(id: id, name: name, bounds: snapshot.bounds, session: session)
        }

        @Test func savingUnderANameThatIsTakenAsksAndThenReplacesThatWorkspaceInItsPlace() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            try await save(tab, as: "Work", in: harness)
            #expect(await waitUntil { workspaces(harness).count == 1 })
            let first = try #require(workspaces(harness).first)
            #expect(first.name == "Work")
            #expect(first.session.openTabs.first?.secondPane == nil)
            let other = Workspace(id: "workspace-b", name: "Other", bounds: first.bounds, session: first.session)
            tab.updatePreferences { $0.workspaces = [first, other] }

            // The window changes, and is saved under the same name in other letters.
            let second = tab.openSecondPane(at: real(harness, "Beta"))
            #expect(await waitUntil { second.loaded && !second.isNavigating })
            try await save(tab, as: " work ", in: harness)
            #expect(await waitUntil { tab.frontAlert != nil })
            let question = try #require(tab.frontAlert)
            #expect(question.titleLabel.stringValue == "Replace \u{201C}Work\u{201D}?")
            // Nothing is replaced until it is answered.
            #expect(workspaces(harness).first == first)
            question.press("Replace")

            #expect(await waitUntil { workspaces(harness).first?.session.openTabs.first?.secondPane != nil })
            let kept = workspaces(harness)
            #expect(kept.map(\.id) == [first.id, "workspace-b"])
            #expect(kept.map(\.name) == ["work", "Other"])
            #expect(kept[0].session.openTabs.first?.secondPane?.path == real(harness, "Beta"))
        }

        @Test func noWorkspaceIsSavedPastTheLimitAndANoticeSaysSo() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let one = try workspace("workspace-0", "Kept 0", of: tab, in: harness)
            let full = (0..<Workspaces.limit).map {
                Workspace(id: "workspace-\($0)", name: "Kept \($0)", bounds: one.bounds, session: one.session)
            }
            tab.updatePreferences { $0.workspaces = full }
            #expect(workspaces(harness).count == Workspaces.limit)

            try await save(tab, as: "One More", in: harness)
            #expect(await waitUntil { tab.frontAlert != nil })
            #expect(tab.frontAlert?.titleLabel.stringValue == WorkspaceText.limitTitle)
            #expect(workspaces(harness) == full)
            DialogKeys.press(53, "\u{1b}", in: tab.window)
            #expect(await waitUntil { tab.frontAlert == nil })

            // A name that is kept already is still saved over.
            try await save(tab, as: "Kept 7", in: harness)
            #expect(await waitUntil { tab.frontAlert != nil })
            #expect(tab.frontAlert?.titleLabel.stringValue == "Replace \u{201C}Kept 7\u{201D}?")
            tab.frontAlert?.press("Replace")
            #expect(await waitUntil { tab.frontAlert == nil })
            #expect(workspaces(harness).map(\.id) == full.map(\.id))
        }

        @Test func aSlotPastTheEndOfTheListOpensNothingAndOneInItOpensItsWorkspace() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let kept = try workspace(
                "workspace-a", "Work", of: tab, in: harness,
                tabs: [FTAppKitTests.tab(real(harness, "Alpha")), FTAppKitTests.tab(real(harness, "Beta"))])
            tab.updatePreferences { $0.workspaces = [kept] }

            harness.windows.openWorkspace(slot: 1)
            harness.windows.openWorkspace(slot: 4, inPlaceOf: tab)
            await settle()
            #expect(harness.windows.count == 1)

            harness.windows.openWorkspace(slot: 0)
            #expect(await waitUntil { harness.windows.count == 2 })
            let opened = try #require(harness.windows.newestGroup)
            #expect(opened.tabs.map { $0.panes[0].folder.path } == [real(harness, "Alpha"), real(harness, "Beta")])
        }

        // A workspace opens with the List column widths it was saved with, in every one of its tabs, whatever the
        // window it was opened from has since.
        @Test func aWorkspaceOpensWithTheColumnWidthsItWasSavedWith() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            var widths = tab.content.columnState.widths
            widths[.name] = 333
            tab.content.columnWidthsChanged(widths)
            let kept = try workspace(
                "workspace-a", "Work", of: tab, in: harness,
                tabs: [FTAppKitTests.tab(real(harness, "Alpha")), FTAppKitTests.tab(real(harness, "Beta"))])
            #expect(kept.session.detailColumnWidths.name == 333)
            tab.updatePreferences { $0.workspaces = [kept] }
            widths[.name] = 210
            tab.content.columnWidthsChanged(widths)

            harness.windows.openWorkspace(slot: 0)
            #expect(await waitUntil { harness.windows.count == 2 })
            let opened = try #require(harness.windows.newestGroup)
            #expect(opened.tabs.count == 2)
            for other in opened.tabs {
                // The window's services are this harness's, as `open` gives its first window; nothing else is told.
                other.servicesOverride = harness.services
                // What a tab is told when it joins its window, and whenever the window's panels change.
                other.showPanels(opened.session.panels)
                #expect(other.panes[0].content.columnState.widths[.name] == 333)
            }
            #expect(tab.content.columnState.widths[.name] == 210)
        }

        // A window with a name being edited in it isn't replaced: a beep, and nothing opens. One whose name begins
        // to be edited while the workspace loads stays open with it, and the workspace opens beside it with a beep.
        @Test func aWindowWithANameBeingEditedIsntReplacedByAWorkspace() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            var beeps = 0
            harness.windows.beep = { beeps += 1 }
            let kept = try workspace(
                "workspace-a", "Work", of: tab, in: harness, tabs: [FTAppKitTests.tab(real(harness, "Beta"))])
            tab.updatePreferences { $0.workspaces = [kept] }
            let alpha = harness.folder.appending("Alpha").path

            #expect(tab.content.beginRename(path: alpha))
            harness.windows.openWorkspace(id: "workspace-a", inPlaceOf: tab)
            await settle()
            #expect(beeps == 1)
            #expect(harness.windows.count == 1)
            #expect(tab.content.inlineRename != nil)
            tab.content.renameCancelled()

            harness.windows.openWorkspace(id: "workspace-a", inPlaceOf: tab)
            #expect(harness.windows.count == 2)
            #expect(tab.content.beginRename(path: alpha))
            #expect(await waitUntil { beeps == 2 })
            let opened = try #require(harness.windows.newestGroup)
            #expect(opened.tabs.map { $0.panes[0].folder.path } == [real(harness, "Beta")])
            await settle()
            #expect(harness.windows.count == 2)
            #expect(tab.group?.isDestroyed == false)
            #expect(tab.content.inlineRename != nil)
            tab.content.renameCancelled()
        }

        // A key held down opens its workspace once, not a window for every repeat.
        @Test func aWorkspaceKeyHeldDownOpensItsWorkspaceOnce() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let window = try #require(tab.window)
            let kept = try workspace("workspace-a", "Work", of: tab, in: harness)
            tab.updatePreferences { $0.workspaces = [kept] }
            tab.content.focusList()
            func key(isRepeat: Bool) throws -> NSEvent {
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "1",
                        charactersIgnoringModifiers: "1", isARepeat: isRepeat, keyCode: 18))
            }

            #expect(tab.windowKeyDown(try key(isRepeat: true)))
            await settle()
            #expect(harness.windows.count == 1)

            #expect(tab.windowKeyDown(try key(isRepeat: false)))
            #expect(await waitUntil { harness.windows.count == 2 })
        }

        // A folder that is gone opens as the nearest folder above it, in the second pane as in the first, and a notice
        // says how many tabs had one.
        // A workspace brings back the sizes its panes showed their views at: the icon size, the Compact List's column
        // width and the Previews count, each pane's own, whatever sizes the app has by then.
        @Test func aWorkspaceBringsBackEachPanesSizes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.perform(.viewAsIcons)
            tab.perform(.increaseSize)
            let second = tab.openSecondPane(at: real(harness, "Alpha"))
            #expect(await waitUntil { second.loaded && !second.isNavigating })
            tab.focusPane(second)
            tab.perform(.viewAsPreviews)
            tab.perform(.decreaseSize)
            #expect(tab.panes[0].content.columnState.iconSizes.standard == 72)
            #expect(second.content.columnState.previewCounts.standard == 9)
            try await save(tab, as: "Sized", in: harness)
            #expect(await waitUntil { workspaces(harness).count == 1 })
            let kept = try #require(workspaces(harness).first)
            #expect(kept.session.openTabs.first?.viewSizes?.iconSizes.standard == 72)
            #expect(kept.session.openTabs.first?.secondPane?.viewSizes?.previewCounts.standard == 9)

            // The app's sizes move on.
            tab.updatePreferences {
                $0.iconSizes.standard = 32
                $0.previewCounts.standard = 1
            }
            harness.windows.openWorkspace(id: kept.id)
            #expect(await waitUntil { harness.windows.count == 2 })
            let opened = try #require(harness.windows.newestGroup?.tabs.first)
            #expect(await waitUntil { opened.panes.count == 2 })
            harness.layout(opened)
            #expect(opened.panes[0].content.columnState.iconSizes.standard == 72)
            #expect(opened.panes[1].content.columnState.previewCounts.standard == 9)
        }

        @Test func aWorkspaceWhoseFoldersAreGoneOpensTheFoldersAboveThemInBothPanes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            var notices: [WindowNotice] = []
            harness.windows.showNotice = { notice, _ in notices.append(notice) }
            var lost = FTAppKitTests.tab(real(harness, "Alpha") + "/Gone/Deeper")
            lost.secondPane = OpenPanePreference(
                path: real(harness, "Beta") + "/Gone", viewMode: .list, searchViewMode: .details, sortBy: .name,
                sortDirection: .asc, includeHidden: false, foldersFirst: true)
            lost.activePane = 1
            var half = FTAppKitTests.tab(real(harness, "Gamma"))
            half.secondPane = lost.secondPane
            let whole = FTAppKitTests.tab(real(harness, "Gamma/Inner"))
            let kept = try workspace("workspace-a", "Work", of: tab, in: harness, tabs: [lost, half, whole])
            tab.updatePreferences { $0.workspaces = [kept] }

            harness.windows.openWorkspace(id: "workspace-a")

            #expect(await waitUntil { harness.windows.count == 2 })
            let opened = try #require(harness.windows.newestGroup)
            #expect(opened.tabs.count == 3)
            #expect(opened.tabs.map { $0.panes.count } == [2, 2, 1])
            #expect(opened.tabs[0].panes.map(\.folder.path) == [real(harness, "Alpha"), real(harness, "Beta")])
            #expect(opened.tabs[0].activePaneIndex == 1)
            #expect(opened.tabs[1].panes.map(\.folder.path) == [real(harness, "Gamma"), real(harness, "Beta")])
            #expect(opened.tabs[2].panes.map(\.folder.path) == [real(harness, "Gamma/Inner")])
            // Two tabs had a folder that is gone.
            #expect(await waitUntil { notices == [.workspaceFoldersGone(tabs: 2)] })
            // What is kept stays as it was saved.
            #expect(workspaces(harness) == [kept])
        }
    }
}
