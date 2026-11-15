// The keys of menu items that are dimmed, and when File ▸ Compress, Extract and Extract To are on
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct DimmedItemKeysTests {
        private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        private func f5() throws -> NSEvent { try key(96, "\u{F708}", .function) }
        private func f6() throws -> NSEvent { try key(97, "\u{F709}", .function) }

        private func names(_ harness: ExplorerHarness) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: harness.folder.path).sorted()
        }

        // F5 and F6 with both panes on one folder: their items are dimmed, the window keeps the keys from the menu,
        // and nothing is copied or moved.
        @Test func copyAndMoveToTheOtherPaneDoNothingWithBothPanesOnOneFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) }, log: { _ in })
            let left = tab.activePane
            let right = tab.openSecondPane(at: harness.folder.path)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            tab.activate(left)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            tab.content.select(paths: [note])
            let before = try names(harness)
            #expect(!tab.canPerform(.copyToOtherPane) && !tab.canPerform(.moveToOtherPane))

            #expect(tab.keyOfDimmedItem(try f5()))
            #expect(tab.keyOfDimmedItem(try f6()))
            await settle()
            for _ in 0..<20 { await Task.yield() }
            #expect(try names(harness) == before)
            #expect(tab.writeActions?.session.card == nil)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // An item that is on keeps its own key: the window leaves it to the menu.
        @Test func theKeyOfAnItemThatIsOnIsLeftToTheMenu() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let right = tab.openSecondPane(at: harness.folder.appending("Alpha").path)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            tab.activate(tab.panes[0])
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            tab.content.select(paths: [note])
            #expect(tab.canPerform(.copyToOtherPane))
            #expect(!tab.keyOfDimmedItem(try f5()))
            // With nothing selected the item is dimmed again, and the key is the window's.
            tab.content.applySelection(.empty)
            #expect(!tab.canPerform(.copyToOtherPane))
            #expect(tab.keyOfDimmedItem(try f5()))
            await harness.close()
        }

        // Compress is on for a selection outside the Trash; Extract and Extract To for archives alone.
        @Test func compressAndExtractAreOnForWhatTheyCanActOn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let archive = harness.folder.path + "/packed.zip"
            try "x".write(toFile: archive, atomically: true, encoding: .utf8)
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: [archive]))
            #expect(await waitUntil { tab.content.listedEntry(at: archive) != nil })
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            let commands: [AppCommand] = [.compressSelection, .extractSelection, .extractSelectionTo]
            func on() -> [Bool] { commands.map(tab.canPerform) }

            tab.content.applySelection(.empty)
            #expect(on() == [false, false, false])
            tab.content.select(paths: [note])
            #expect(on() == [true, false, false])
            tab.content.select(paths: [archive])
            #expect(on() == [true, true, true])
            // An archive among other items: nothing to extract them all from.
            tab.content.select(paths: [note, archive])
            #expect(on() == [true, false, false])
            await harness.close()
        }
    }
}
