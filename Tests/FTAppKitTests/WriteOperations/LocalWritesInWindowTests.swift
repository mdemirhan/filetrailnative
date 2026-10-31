// Port by feature of the New Folder and rename cases of apps/desktop/src/renderer/App.fileOperations.test.tsx that need
// a real tab: the folder made in the folder on screen named in its row, and the rename field's name carried out by the
// write coordinator
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

extension ExplorerWindowlessTests {
    @MainActor @Suite(.windowlessAlone) struct LocalWritesInWindowTests {
        /// A tab on the harness's folder with the app's file operations, its notices kept.
        private func open() async throws -> (ExplorerHarness, MainWindowController, AppWriteOperations, Notices) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn,
                log: { _ in })
            let notices = Notices()
            operations.dialogs.show = { title, message, _ in
                notices.titles.append(title)
                notices.messages.append(message)
            }
            operations.dialogs.confirm = { _, _ in false }
            return (harness, tab, operations, notices)
        }

        final class Notices {
            var titles: [String] = []
            var messages: [String] = []
        }

        /// A rename the test lets finish.
        @MainActor final class Held {
            private var isOpen = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                if isOpen { return }
                await withCheckedContinuation { waiters.append($0) }
            }

            func open() {
                isOpen = true
                for waiter in waiters { waiter.resume() }
                waiters = []
            }
        }

        // New Folder from the keyboard makes "untitled folder" in the folder on screen and opens its name in its
        // row, the filter cleared to show it.
        // F-243 F-297 T-c1a82f6c T-ac17441a T-be6a681a
        // B-NAV-173 B-SEL-144 T-574fdd65
        @Test func namesANewFolderInItsRowWhileTheListIsFiltered() async throws {
            let (harness, tab, operations, notices) = try await open()
            tab.content.setFilter("Alp")
            #expect(!tab.content.filter.isEmpty)

            tab.perform(.newFolder)
            #expect(await waitUntil { tab.content.inlineRename != nil })

            let made = tab.folder.path + "/untitled folder"
            #expect(tab.content.inlineRename.map { NodePath.basename($0.path) } == "untitled folder")
            #expect(FileManager.default.fileExists(atPath: made))
            #expect(tab.content.filter.isEmpty)
            #expect(await waitUntil { tab.content.selection.paths == [made] })
            #expect(notices.titles.isEmpty)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // A second press while the first folder is being made is refused, and the first one's name still opens in its row.
        // T-f4c7e32e
        @Test func stillEditsTheFirstFoldersNameAfterASecondPressIsRefused() async throws {
            let (harness, tab, operations, notices) = try await open()
            tab.perform(.newFolder)
            tab.perform(.newFolder)
            #expect(await waitUntil { tab.content.inlineRename != nil })
            #expect(tab.content.inlineRename.map { NodePath.basename($0.path) } == "untitled folder")
            #expect(notices.messages == [WriteDialogs.busyMessage])
            #expect(!FileManager.default.fileExists(atPath: tab.folder.path + "/untitled folder 2"))
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // The name typed in the row goes to the write coordinator; its end selects the item where it is now.
        // F-243 F-302 T-5fe733dc T-fe6c45d8
        @Test func renamesTheItemInItsRowThroughTheCoordinator() async throws {
            let (harness, tab, operations, notices) = try await open()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            tab.content.select(paths: [note])
            tab.renameSelected()
            #expect(tab.content.inlineRename?.path == note)

            tab.content.renameSubmitted("renamed.txt")
            let renamed = tab.folder.path + "/renamed.txt"
            #expect(await waitUntil { tab.content.inlineRename == nil && isListed(tab, "renamed.txt") })
            #expect(FileManager.default.fileExists(atPath: renamed))
            #expect(!isListed(tab, "note.txt"))
            #expect(await waitUntil { tab.content.selection.leadPath?.hasSuffix("/renamed.txt") == true })
            #expect(notices.titles.isEmpty)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // A name another item has is refused in the field, which stays open with the reason.
        // F-302 T-4bfb37f4
        // B-CLIP-197
        @Test func refusesATakenNameAndKeepsTheFieldOpen() async throws {
            let (harness, tab, operations, notices) = try await open()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            tab.content.select(paths: [note])
            tab.renameSelected()

            tab.content.renameSubmitted("Alpha")
            #expect(await waitUntil { tab.content.inlineRename?.error != nil })
            #expect(tab.content.inlineRename?.path == note)
            #expect(tab.content.inlineRename?.error == "An item named “Alpha” already exists.")
            #expect(FileManager.default.fileExists(atPath: note))
            #expect(notices.titles.isEmpty)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // The folder is left while the name is checked: the refusal comes back with no field to show it under, and
        // is said in a dialog of its own (B-SEL-140).
        // F-302 T-4649783b
        // B-CLIP-197 B-SEL-140 T-fedfb7ae
        @Test func saysARefusalThatCameAfterItsFolderWasLeftInADialog() async throws {
            let (harness, tab, operations, notices) = try await open()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            let held = Held()
            tab.renameItem = { _, _ in
                await held.wait()
                return .refused("An item named \u{201C}Alpha\u{201D} already exists.")
            }
            tab.content.select(paths: [note])
            tab.renameSelected()

            tab.content.renameSubmitted("Alpha")
            _ = await tab.navigate(to: harness.folder.url.appendingPathComponent("Beta"))
            #expect(await waitUntil { tab.content.inlineRename == nil })
            #expect(notices.titles.isEmpty)
            held.open()

            #expect(await waitUntil { !notices.titles.isEmpty })
            #expect(notices.titles == ["\u{201C}note.txt\u{201D} couldn\u{2019}t be renamed"])
            #expect(notices.messages == ["An item named \u{201C}Alpha\u{201D} already exists."])
            #expect(tab.content.inlineRename == nil)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // A refusal the field was showing when its folder was left is said in a dialog, so it isn't lost.
        // F-302 T-4649783b
        // B-CLIP-197 B-SEL-140
        @Test func saysTheFieldsRefusalInADialogWhenItsFolderIsLeft() async throws {
            let (harness, tab, operations, notices) = try await open()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            tab.content.select(paths: [note])
            tab.renameSelected()
            tab.content.renameSubmitted("Alpha")
            #expect(await waitUntil { tab.content.inlineRename?.error != nil })
            #expect(notices.titles.isEmpty)

            _ = await tab.navigate(to: harness.folder.url.appendingPathComponent("Beta"))
            #expect(await waitUntil { tab.content.inlineRename == nil && !notices.titles.isEmpty })
            #expect(notices.titles == ["Couldn\u{2019}t Rename"])
            #expect(notices.messages == ["An item named \u{201C}Alpha\u{201D} already exists."])
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        private func isListed(_ tab: MainWindowController, _ name: String) -> Bool {
            tab.content.entries.contains { $0.name == name }
        }
    }
}
