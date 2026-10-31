// Port by feature of the Icons and Compact List share of components/ClipboardMarks.test.tsx and App.dragOut.test.tsx:
// the clipboard's marks and the drags of the Icons view and the Compact List of a window that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct GridDragDropTests {
        private func marks(_ mode: ClipboardMode, _ paths: [String]) -> ClipboardMarks? {
            ClipboardMarks(ClipboardRules.set(mode, paths, capturedAt: "t"), enabled: true)
        }

        // F-791 B-CLIP-014 B-CLIP-015: in the Compact List an item on the clipboard has the copy or scissors glyph
        // after its name, the item grows by the glyph and its gap, and a cut one's name is dimmed.
        // B-VIEW-076
        @Test func compactListItemsShowTheirMark() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let before = try #require(probe.compactItems["note.txt"]).view.frame.width
            tab.content.clipboardMarksChanged(marks(.cut, [note.path]), flash: false)
            probe.layout()
            let item = try #require(probe.compactItems["note.txt"])
            #expect(!item.markGlyph.isHidden && item.markGlyph.mark == .cut)
            #expect(item.label.alphaValue == CGFloat(ClipboardLayout.Mark.cutLabelAlpha))
            let grown = item.view.frame.width - before
            #expect(abs(grown - CGFloat(ClipboardLayout.Mark.gap + ClipboardLayout.Mark.iconSize)) < 1)
            #expect(item.markGlyph.frame.width == CGFloat(ClipboardLayout.Mark.iconSize))
            #expect(item.markGlyph.frame.minX >= item.label.frame.maxX + CGFloat(ClipboardLayout.Mark.gap) - 0.5)
            #expect(probe.compactItems["Alpha"]?.markGlyph.isHidden == true)
            tab.content.clipboardMarksChanged(marks(.copy, [note.path]), flash: false)
            #expect(item.markGlyph.mark == .copy && item.label.alphaValue == 1)
            tab.content.clipboardMarksChanged(nil, flash: false)
            #expect(item.markGlyph.isHidden)
            await harness.close()
        }

        // F-791 B-CLIP-015: a cut item of the Icons view has its name at 0.55 and its picture at 0.45, its badge
        // untouched.
        @Test func cutIconsAreDimmed() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.clipboardMarksChanged(marks(.cut, [note.path]), flash: false)
            let item = try #require(probe.iconItems["note.txt"])
            #expect(item.label.alphaValue == CGFloat(ClipboardLayout.Mark.cutLabelAlpha))
            #expect(item.iconBox.alphaValue == CGFloat(ClipboardLayout.Mark.cutIconAlpha))
            #expect(item.badge.alphaValue == 1 && !item.badge.isHidden)
            tab.content.clipboardMarksChanged(marks(.copy, [note.path]), flash: false)
            #expect(item.label.alphaValue == 1 && item.iconBox.alphaValue == 1)
            await harness.close()
        }

        // F-688 B-CLIP-149: a drag from the Icons view sets off from its pictures and the names centered under them.
        @Test func iconDragImagesComeFromTheItemsInSight() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let placed = try #require(tab.content.dragPlacements(for: [note.path, "/nowhere"]))
            let placement = try #require(placed.placements[note.path])
            #expect(placed.view === probe.grid)
            #expect(placement.inSight && placement.nameCentered)
            #expect(placement.nameRect.minY >= placement.iconRect.maxY)
            #expect(placed.placements["/nowhere"] == nil)
            await harness.close()
        }

        // F-688 B-CLIP-149: a drag from the Compact List sets off from the icons and the names after them.
        @Test func compactListDragImagesComeFromTheItemsInSight() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let placed = try #require(tab.content.dragPlacements(for: [note.path]))
            let placement = try #require(placed.placements[note.path])
            #expect(placed.view === probe.grid)
            #expect(placement.inSight && !placement.nameCentered)
            #expect(placement.nameRect.minX > placement.iconRect.maxX)
            await harness.close()
        }

        // B-CLIP-164: a folder item a drag is over shows what a drop would do; the highlight goes when the drag
        // moves on.
        // B-VIEW-074
        @Test func gridItemsShowTheDropTarget() async throws {
            let harness = try ExplorerHarness.windowless()
            for mode in [RendererCommand.viewAsIcons, .viewAsList] {
                let (tab, probe) = try await harness.openGrid(mode)
                let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
                tab.content.setDropTarget(alpha.path, .valid, background: nil)
                if mode == .viewAsIcons {
                    let item = try #require(probe.iconItems["Alpha"])
                    #expect(item.root.drop?.state == .valid && !item.dropMarker.isHidden)
                    tab.content.setDropTarget(nil, nil, background: nil)
                    #expect(item.root.drop == nil && item.dropMarker.isHidden)
                } else {
                    let item = try #require(probe.compactItems["Alpha"])
                    #expect(item.root.drop?.state == .valid && !item.dropMarker.isHidden)
                    tab.content.setDropTarget(alpha.path, .invalid, background: nil)
                    #expect(item.root.drop?.state == .invalid && item.dropMarker.isHidden)
                    tab.content.setDropTarget(nil, nil, background: nil)
                    #expect(item.root.drop == nil)
                }
            }
            await harness.close()
        }
    }
}
