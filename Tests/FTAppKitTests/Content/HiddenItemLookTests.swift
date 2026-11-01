import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct HiddenItemLookTests: ListTesting {
        /// Hidden files shown in a folder with a hidden file and the plain ones.
        private func showHidden(
            _ harness: ExplorerHarness, _ tab: MainWindowController, _ probe: GridProbe?
        ) async throws -> DirectoryEntry {
            let folder = try #require(tab.content.entries.first).url.deletingLastPathComponent()
            try Data().write(to: folder.appendingPathComponent(".secret.txt"))
            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == ".secret.txt" } })
            harness.layout(tab)
            probe?.layout()
            return try #require(tab.content.entries.first { $0.name == ".secret.txt" })
        }

        @Test func theDetailsViewFadesAHiddenItemsIconAndNotItsName() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !tab.content.entries.isEmpty }
            _ = try await showHidden(harness, tab, nil)
            let rows = bars(tab)
            let hidden = try #require(rows.first { $0.entry?.name == ".secret.txt" })
            let plain = try #require(rows.first { $0.entry?.name == "note.txt" })
            #expect(hidden.nameCell.iconView.alphaValue == CGFloat(HiddenItemLook.iconAlpha))
            #expect(hidden.nameLabel.alphaValue == 1)
            #expect(plain.nameCell.iconView.alphaValue == 1)
            await harness.close()
        }

        @Test func theCompactListFadesAHiddenItemsIconAndNotItsName() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList)
            _ = try await showHidden(harness, tab, probe)
            let hidden = try #require(probe.compactItems[".secret.txt"])
            let plain = try #require(probe.compactItems["note.txt"])
            #expect(hidden.iconView.alphaValue == CGFloat(HiddenItemLook.iconAlpha))
            #expect(hidden.label.alphaValue == 1)
            #expect(plain.iconView.alphaValue == 1)
            await harness.close()
        }

        @Test func theIconsViewFadesAHiddenItemsIconAndACutOneLooksCut() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let entry = try await showHidden(harness, tab, probe)
            let hidden = try #require(probe.iconItems[".secret.txt"])
            #expect(hidden.iconBox.alphaValue == CGFloat(HiddenItemLook.iconAlpha))
            #expect(hidden.label.alphaValue == 1)
            #expect(try #require(probe.iconItems["note.txt"]).iconBox.alphaValue == 1)

            let marks = ClipboardMarks(ClipboardRules.set(.cut, [entry.path], capturedAt: "t"), enabled: true)
            tab.content.clipboardMarksChanged(marks, flash: false)
            #expect(hidden.iconBox.alphaValue == CGFloat(ClipboardLayout.Mark.cutIconAlpha))
            #expect(hidden.label.alphaValue == CGFloat(ClipboardLayout.Mark.cutLabelAlpha))
            await harness.close()
        }
    }
}
