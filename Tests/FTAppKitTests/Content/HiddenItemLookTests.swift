import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct HiddenItemLookTests: ListTesting {
        // Each view fades a hidden item's icon and not its name; in the Icons view a cut one looks cut. One window,
        // its view switched.
        @Test func eachViewFadesAHiddenItemsIconAndNotItsName() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { !tab.content.entries.isEmpty })
            // Hidden files shown in a folder with a hidden file and the plain ones.
            let folder = try #require(tab.content.entries.first).url.deletingLastPathComponent()
            try Data().write(to: folder.appendingPathComponent(".secret.txt"))
            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == ".secret.txt" } })
            harness.layout(tab)
            let entry = try #require(tab.content.entries.first { $0.name == ".secret.txt" })

            // The List.
            let rows = bars(tab)
            let hiddenRow = try #require(rows.first { $0.entry?.name == ".secret.txt" })
            let plainRow = try #require(rows.first { $0.entry?.name == "note.txt" })
            #expect(hiddenRow.nameCell.iconView.alphaValue == CGFloat(HiddenItemLook.iconAlpha))
            #expect(hiddenRow.nameLabel.alphaValue == 1)
            #expect(plainRow.nameCell.iconView.alphaValue == 1)

            // The Compact List.
            let probe = GridProbe(tab: tab)
            tab.perform(.viewAsList)
            #expect(await waitUntil { probe.compact != nil })
            harness.layout(tab)
            probe.layout()
            let hiddenColumn = try #require(probe.compactItems[".secret.txt"])
            let plainColumn = try #require(probe.compactItems["note.txt"])
            #expect(hiddenColumn.iconView.alphaValue == CGFloat(HiddenItemLook.iconAlpha))
            #expect(hiddenColumn.label.alphaValue == 1)
            #expect(plainColumn.iconView.alphaValue == 1)

            // The Icons view, and a cut item there.
            tab.perform(.viewAsIcons)
            #expect(await waitUntil { probe.icons != nil })
            harness.layout(tab)
            probe.layout()
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
