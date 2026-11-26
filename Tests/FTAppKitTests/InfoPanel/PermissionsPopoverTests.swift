// The permissions popover in a window with the app's file operations: what it shows, a click written, the Info
// panel's Edit…, items it can't change, the question before you lock yourself out, and its one Undo
import AppKit
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct PermissionsPopoverTests {
        /// A tab on the harness's folder with two files to change (644 and a 755 script), the app's file operations,
        /// and its notices kept.
        private func open() async throws -> (ExplorerHarness, MainWindowController, AppWriteOperations, NoticeSpy) {
            let harness = try ExplorerHarness.windowless()
            for (name, mode) in [("a.txt", 0o644), ("run.sh", 0o755)] {
                let path = harness.folder.appending(name).path
                try "x".write(toFile: path, atomically: true, encoding: .utf8)
                #expect(Darwin.chmod(path, mode_t(mode)) == 0)
            }
            let tab = try await harness.open()
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "run.sh" } })
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) }, log: { _ in })
            let notices = NoticeSpy()
            tab.contextMenus.notices = notices
            return (harness, tab, operations, notices)
        }

        private func path(_ harness: ExplorerHarness, _ name: String) -> String {
            harness.folder.appending(name).path
        }

        private func mode(_ path: String) -> Int {
            var info = Darwin.stat()
            return Darwin.lstat(path, &info) == 0 ? Int(info.st_mode & 0o7777) : -1
        }

        /// The popover for `paths`, once it has read them.
        private func popover(_ tab: MainWindowController, _ paths: [String]) async throws -> PermissionsPopover {
            var made: PermissionsPopover?
            tab.shownPermissionsPopover = { made = $0 }
            tab.editPermissions(paths, from: try #require(tab.window?.contentView))
            #expect(await waitUntil { made != nil })
            return try #require(made)
        }

        // Two files: what both have is checked, what one has is mixed, the third column is Run. A click on the
        // group's Write puts it on both and leaves the script's Run; the boxes show what was written.
        @Test func showsTheItemsAndWritesAClick() async throws {
            let (harness, tab, operations, notices) = try await open()
            let paths = [path(harness, "a.txt"), path(harness, "run.sh")]
            let popover = try await popover(tab, paths)
            let view = popover.view
            #expect(view.title.stringValue == "2 Items")
            #expect(view.subtitle.stringValue == "2 files")
            #expect(view.heads.map(\.stringValue) == ["Read", "Write", "Run"])
            #expect(view.boxes[0][0].state == .on)
            #expect(view.boxes[0][2].state == .mixed)
            #expect(view.boxes[1][1].state == .off)
            #expect(view.modeField.stringValue == "Mixed")
            #expect(view.letters.stringValue == "rw?r-?r-?")
            #expect(view.note.stringValue == PermissionsPopoverView.note)
            #expect(view.boxes.allSatisfy { $0.allSatisfy(\.isEnabled) })
            view.boxes[1][1].performClick(nil)
            // Shown at once, before it is written.
            #expect(view.boxes[1][1].state == .on)
            await popover.waitForWrites()
            #expect(mode(paths[0]) == 0o664)
            #expect(mode(paths[1]) == 0o775)
            #expect(view.letters.stringValue == "rw?rw?r-?")
            #expect(notices.shown.isEmpty)
            // The list reads them again: its rows show the new modes.
            #expect(
                await waitUntil {
                    paths.map { path in
                        (tab.content.metadata(for: path)?.permissionMode
                            ?? tab.content.listedEntry(at: path)?.permissionMode).map { Int($0) & 0o777 }
                    } == [0o664, 0o775]
                })
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // A mode typed and Return sets the nine bits of every item; what isn't a mode changes nothing.
        @Test func aModeTypedIsWritten() async throws {
            let (harness, tab, operations, _) = try await open()
            let paths = [path(harness, "a.txt"), path(harness, "run.sh")]
            let popover = try await popover(tab, paths)
            #expect(!popover.typeMode("9"))
            #expect(popover.typeMode("rw-------"))
            await popover.waitForWrites()
            #expect(paths.map(mode) == [0o600, 0o600])
            #expect(popover.view.modeField.stringValue == "600")
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // Everything changed while it is open is one Undo, named for the items; Undo puts back what they had when it
        // opened, and Redo the last of it.
        @Test func oneVisitIsOneUndo() async throws {
            let (harness, tab, operations, _) = try await open()
            let paths = [path(harness, "a.txt"), path(harness, "run.sh")]
            let popover = try await popover(tab, paths)
            popover.toggle(who: 2, what: 0)
            popover.toggle(who: 1, what: 0)
            await popover.waitForWrites()
            #expect(paths.map(mode) == [0o600, 0o711])
            #expect(operations.undoHistory.entries(.undo).count == 1)
            #expect(operations.undoHistory.menu().undo == "Permissions of 2 Items")
            popover.close()
            _ = await tab.writeActions?.undo()
            #expect(await waitUntil { paths.map(mode) == [0o644, 0o755] })
            #expect(await waitUntil { operations.undoHistory.menu().redo == "Permissions of 2 Items" })
            _ = await tab.writeActions?.redo()
            #expect(await waitUntil { paths.map(mode) == [0o600, 0o711] })
            await harness.close()
        }

        // Someone else's item is shown with everything off limits, and why.
        @Test func anotherOwnersItemCantBeChanged() async throws {
            let (harness, tab, operations, _) = try await open()
            let popover = try await popover(tab, ["/usr/bin"])
            let view = popover.view
            #expect(view.whoNames[0].stringValue == "root")
            #expect(view.heads[2].stringValue == "Open")
            #expect(view.boxes.allSatisfy { $0.allSatisfy { !$0.isEnabled } })
            #expect(!view.modeField.isEnabled)
            #expect(!view.lockedBox.isEnabled)
            #expect(view.note.stringValue == "Only root can change these. You can read this item.")
            popover.toggle(who: 2, what: 0)
            await popover.waitForWrites()
            #expect(operations.undoHistory.entries(.undo).isEmpty)
            await harness.close()
        }

        // Turning off your own Open of a folder asks first: Cancel leaves it, Turn Off writes it.
        @Test func turningOffYourOwnOpenOfAFolderAsksFirst() async throws {
            let (harness, tab, operations, notices) = try await open()
            let folder = path(harness, "Alpha")
            let before = mode(folder)
            let popover = try await popover(tab, [folder])
            notices.answer = false
            popover.toggle(who: 0, what: 2)
            #expect(await waitUntil { notices.questions.count == 1 })
            #expect(notices.questions.first?.title == "Turn Off Open for You?")
            #expect(
                notices.questions.first?.message
                    == "You won\u{2019}t be able to open \u{201C}Alpha\u{201D} until it is turned back on.")
            await popover.waitForWrites()
            #expect(mode(folder) == before)
            #expect(popover.view.boxes[0][2].state == .on)
            notices.answer = true
            popover.toggle(who: 0, what: 2)
            #expect(await waitUntil { mode(folder) == before & ~0o100 })
            #expect(Darwin.chmod(folder, mode_t(before)) == 0)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // The Info panel's Sharing & Permissions title has Edit…, which opens the popover for the item it describes.
        @Test func theInfoPanelsEditOpensIt() async throws {
            let (harness, tab, operations, _) = try await open()
            let file = path(harness, "a.txt")
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            tab.content.select(paths: [file])
            let root = try #require(tab.window?.contentView?.superview)
            #expect(await waitUntil { !findViews("infoPanel.permissions.edit", in: root).isEmpty })
            var made: PermissionsPopover?
            tab.shownPermissionsPopover = { made = $0 }
            let edit = try #require(findViews("infoPanel.permissions.edit", in: root).first)
            #expect(edit.accessibilityPerformPress())
            #expect(await waitUntil { made != nil })
            #expect(made?.paths == [file])
            #expect(made?.view.title.stringValue == "a.txt")
            #expect(made?.view.modeField.stringValue == "644")
            // A change shows in the panel's Mode row.
            func modeRow() -> String? {
                findViews("infoPanel.row.value", in: root).compactMap { ($0 as? NSTextField)?.stringValue }
                    .first { $0.hasSuffix("rw-r--r--") || $0.hasSuffix("rw-------") }
            }
            #expect(modeRow() == "644 \u{00B7} rw-r--r--")
            #expect(made?.typeMode("600") == true)
            await made?.waitForWrites()
            #expect(await waitUntil { modeRow() == "600 \u{00B7} rw-------" })
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}
