// Port of the cases of apps/desktop/src/renderer/App.commands.test.tsx (the background's menu) and App.openItems.test.tsx
// (a folder alias, Always Open With cancelled), chosen from the menus themselves
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ContextMenuMatrixTests {
        private func choose(_ title: String, in menu: NSMenu?) throws {
            let item = try #require(menu?.items.first { $0.title == title }, "\(title)")
            _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }

        // T-891ee398: with nothing right-clicked, the menu's actions are on the folder on screen, whatever is selected.
        @Test func theBackgroundsActionsRunOnTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let spy = OpenSpy()
            tab.opener = spy.opener
            tab.contextMenus.opener = spy.opener
            let folder = tab.shownFolderPath
            let note = try #require(tab.content.listed.first { $0.name == "note.txt" })

            try choose("Copy Path", in: tab.contextMenus.contentMenu(for: nil))
            #expect(await waitUntil { harness.pasteboard.string(forType: .string) == folder })

            try choose("Show in Finder", in: tab.contextMenus.contentMenu(for: nil))
            #expect(await waitUntil { spy.all.count == 1 })
            #expect(spy.all.last?.hasSuffix(folder) == true)
            #expect(spy.all.last?.contains(note.name) == false)

            try choose("Open in Terminal", in: tab.contextMenus.contentMenu(for: nil))
            #expect(await waitUntil { spy.all.count == 2 })
            #expect(spy.all.last?.contains("Terminal") == true)
            #expect(spy.all.last?.hasSuffix(folder) == true)

            try choose("Show Info", in: tab.contextMenus.contentMenu(for: nil))
            #expect(tab.infoController?.targetPath == folder)
            #expect(tab.panels.propertiesOpen)
            await harness.close()
        }

        // T-ce789a8a: a folder alias opens the folder it points to, in a new tab.
        @Test func anAliasOfAFolderOpensInANewTabAtItsFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createSymbolicLink(
                atPath: harness.folder.appending("Link").path,
                withDestinationPath: harness.folder.appending("Alpha").path)
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let link = try #require(tab.content.listed.first { $0.name == "Link" })
            #expect(link.kind == .symlinkDirectory)
            let alpha = tab.folder.appendingPathComponent("Alpha").path

            try choose("Open in New Tab", in: tab.contextMenus.contentMenu(for: [link]))
            #expect(await waitUntil { group.tabs.count == 2 })
            let opened = try #require(group.tabs.last)
            #expect(await waitUntil { opened.shownFolderPath == alpha && !opened.isNavigating })
            #expect(opened.historyPaths == [alpha])
            #expect(group.selected === opened)
            await harness.close()
        }

        // T-6e357c2b: Always Open With cancelled changes nothing and opens nothing.
        @Test func alwaysOpenWithCancelledChangesAndOpensNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let spy = OpenSpy()
            let notices = NoticeSpy()
            notices.answer = false
            tab.contextMenus.opener = spy.opener
            tab.contextMenus.notices = notices
            var changed: [String] = []
            tab.contextMenus.setDefaultApplication = { appPath, _ in
                changed.append(appPath)
                return .success
            }
            let note = try #require(tab.content.listed.first { $0.name == "note.txt" })
            tab.contextMenus.contextMenu(
                open: [note.path],
                with: .application(
                    id: "zed", label: "Zed", appPath: "/Applications/Zed.app", appName: "Zed", always: true),
                kind: OpenWithKind(contentType: "public.plain-text", name: "Plain Text Document", isFolder: false))
            #expect(await waitUntil { !notices.asked.isEmpty })
            try await Task.sleep(for: .milliseconds(100))
            #expect(changed.isEmpty)
            #expect(spy.all.isEmpty)
            #expect(notices.shown.isEmpty)
            await harness.close()
        }
    }
}
