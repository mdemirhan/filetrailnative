// Port of the Cmd-double-click of apps/desktop/src/renderer/App.tabs.test.tsx and components/entryItemEvents.ts, the
// per-tab view of lib/explorerTabs.ts, the merge of App.windows.test.tsx, the sideways header of
// components/ContentPane.items.test.tsx, the path field's keys of components/ContentPane.test.tsx and the Info panel
// across a reload of App.commands.test.tsx
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabsAndViewsMatrixTests {
        private func expectANewTabOnAlpha(
            _ tab: MainWindowController, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            let group = try #require(tab.group, sourceLocation: sourceLocation)
            #expect(await waitUntil { group.tabs.count == 2 }, sourceLocation: sourceLocation)
            #expect(group.tabs.first === tab, sourceLocation: sourceLocation)
            let opened = try #require(group.tabs.last, sourceLocation: sourceLocation)
            let alpha = tab.folder.appendingPathComponent("Alpha").path
            #expect(
                await waitUntil { opened.shownFolderPath == alpha && !opened.isNavigating },
                sourceLocation: sourceLocation)
            #expect(group.selected === opened, sourceLocation: sourceLocation)
        }

        // T-2153a91a B-VIEW-071: with Command, a double-click on a folder's row opens a tab on it after the current one.
        @Test func commandDoubleClickOnAFoldersRowOpensANewTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let home = tab.shownFolderPath
            await list.click(name: "Alpha", count: 2, modifiers: .command)
            try await expectANewTabOnAlpha(tab)
            #expect(tab.shownFolderPath == home)
            await harness.close()
        }

        // T-2153a91a B-VIEW-071: on an icon too.
        @Test func commandDoubleClickOnAnIconOpensANewTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let alpha = try #require(probe.iconItems["Alpha"])
            probe.press(at: probe.point(in: alpha.tile), count: 2, modifiers: .command)
            try await expectANewTabOnAlpha(tab)
            await harness.close()
        }

        // T-2153a91a: and from its menu.
        @Test func aFoldersMenuOpensANewTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let alpha = try #require(tab.content.listed.first { $0.name == "Alpha" })
            let menu = tab.contextMenus.contentMenu(for: [alpha])
            let item = try #require(menu?.items.first { $0.title == "Open in New Tab" })
            _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
            try await expectANewTabOnAlpha(tab)
            await harness.close()
        }

        // B-VIEW-071: without Command it opens in place, and a file with Command just opens.
        @Test func onlyAFolderWithCommandGetsANewTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let group = try #require(tab.group)
            var openedFiles: [String] = []
            tab.openFile = { openedFiles.append($0.lastPathComponent) }
            await list.click(name: "note.txt", count: 2, modifiers: .command)
            #expect(await waitUntil { openedFiles == ["note.txt"] })
            #expect(group.tabs.count == 1)
            await list.click(name: "Alpha", count: 2)
            let alpha = tab.folder.appendingPathComponent("Alpha").path
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            #expect(group.tabs.count == 1)
            await harness.close()
        }

        // B-VIEW-169: hidden files and Folders First belong to the tab; a new one starts with those of the tab it came from.
        @Test func hiddenFilesAndFoldersFirstArePerTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let hidden = tab.includeHidden
            let first = tab.foldersFirst
            tab.perform(.toggleHiddenFiles)
            tab.perform(.toggleFoldersFirst)
            #expect(await waitUntil { !tab.isNavigating })

            group.openNewTab(from: tab)
            let other = try #require(group.tabs.last)
            #expect(other !== tab)
            #expect(other.includeHidden == !hidden)
            #expect(other.foldersFirst == !first)
            #expect(await waitUntil { !other.isNavigating && !other.content.listed.isEmpty })

            other.perform(.toggleHiddenFiles)
            other.perform(.toggleFoldersFirst)
            #expect(await waitUntil { !other.isNavigating })
            #expect(other.includeHidden == hidden)
            #expect(other.foldersFirst == first)
            #expect(tab.includeHidden == !hidden)
            #expect(tab.foldersFirst == !first)
            await harness.close()
        }

        // T-cc3773a9: the other windows' tabs come after this one's, which stays in front; one whose folder went is left out.
        @Test func mergedTabsComeAfterItsOwnWithoutAGoneFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let beta = tab.folder.appendingPathComponent("Beta").path
            let gamma = tab.folder.appendingPathComponent("Gamma").path
            group.openNewWindow(from: tab, path: beta)
            #expect(await waitUntil { harness.windows.count == 2 })
            group.openNewWindow(from: tab, path: gamma)
            #expect(await waitUntil { harness.windows.count == 3 })
            try FileManager.default.removeItem(atPath: gamma)

            tab.perform(.mergeAllWindows)
            #expect(await waitUntil { harness.windows.count == 1 && group.tabs.count == 2 })
            #expect(group.tabs.first === tab)
            #expect(group.tabs.last?.startupTab.path == beta)
            #expect(group.selected === tab)
            await harness.close()
        }

        // T-a691ba1c: the column titles move with the rows scrolled sideways.
        @Test func theColumnTitlesFollowTheRowsSideways() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let pane = try #require(tab.content.pane as? ListViewController)
            // A pane narrower than the Name column can go, so the table runs past it.
            pane.view.setFrameSize(NSSize(width: 80, height: pane.view.frame.height))
            pane.view.layoutSubtreeIfNeeded()
            let header = try #require(identified("list.header", in: pane.view).first)
            let before = header.frame.minX
            pane.scrollPosition = (top: 0, left: 60)
            pane.view.layoutSubtreeIfNeeded()
            let scrolled = pane.scrollPosition.left
            #expect(scrolled > 0)
            #expect(await waitUntil { header.frame.minX == before - scrolled })
            await harness.close()
        }

        // T-f80edb39: Tab goes from the field into the suggestions, previewing; the arrows move; Shift-Tab goes back out;
        // Return on a row takes it and leaves the field open.
        @Test func tabMovesBetweenThePathFieldAndItsSuggestions() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let editor = tab.content.contentShell.pathBarRow.editor
            var submitted: [String] = []
            editor.onSubmit = { submitted.append($0) }
            editor.requestSuggestions = { _ in
                [
                    PathSuggestionRow(path: "/Users/demo/Documents", name: "Documents"),
                    PathSuggestionRow(path: "/Users/demo/Downloads", name: "Downloads"),
                ]
            }
            editor.open(currentPath: "/Users/demo")
            editor.field.stringValue = "/Users/demo/Do"
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.field))
            #expect(await waitUntil { editor.suggestionsAreShown })

            let keys = NSTextView()
            func press(_ selector: Selector) -> Bool {
                editor.control(editor.field, textView: keys, doCommandBy: selector)
            }
            let tabKey = #selector(NSResponder.insertTab(_:))
            let backTab = #selector(NSResponder.insertBacktab(_:))
            #expect(press(tabKey))
            #expect(editor.field.stringValue == "/Users/demo/Documents/")
            // Out to the field again by either key, the row it had staying.
            #expect(press(backTab))
            #expect(editor.field.stringValue == "/Users/demo/Documents/")
            // Shift-Tab from the field goes in at the last row.
            #expect(press(backTab))
            #expect(editor.field.stringValue == "/Users/demo/Downloads/")
            #expect(press(tabKey))
            #expect(editor.field.stringValue == "/Users/demo/Downloads/")
            #expect(press(tabKey))
            #expect(editor.field.stringValue == "/Users/demo/Documents/")
            #expect(press(#selector(NSResponder.moveDown(_:))))
            #expect(editor.field.stringValue == "/Users/demo/Downloads/")
            #expect(press(#selector(NSResponder.insertNewline(_:))))
            #expect(editor.field.stringValue == "/Users/demo/Downloads/")
            #expect(!editor.suggestionsAreShown)
            #expect(submitted.isEmpty)
            editor.close()
            await harness.close()
        }

        // T-321434ce: the folder's own info stays in the panel over a reload, and is asked for again.
        @Test func theInfoPanelKeepsTheFolderAcrossAReload() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            tab.perform(.toggleInfoPanel)
            let info = try #require(tab.infoController)
            let folder = tab.shownFolderPath
            #expect(await waitUntil { probe.detailReads(of: folder) > 0 })
            #expect(info.targetPath == folder)
            try await Task.sleep(for: .milliseconds(200))
            let before = probe.detailReads(of: folder)

            tab.refresh()
            #expect(await waitUntil { probe.detailReads(of: folder) > before })
            #expect(info.targetPath == folder)
            #expect(info.resolved?.item.name == tab.folder.lastPathComponent)
            await harness.close()
        }
    }
}
