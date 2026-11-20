// A drag over one of two folders whose paths differ only in how an accent is stored
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// "café" with its "é" as one scalar, and as an "e" with the accent after it: two rows on a disk that keeps both.
    @MainActor
    @Suite struct DragAccentTwinsTests {
        // The row under the drag is the one that shows it, when the drag goes from one of the two to the other.
        @Test func theRowUnderTheDragIsTheOneThatShowsIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let content = tab.content
            let composed = tab.shownFolderPath + "/caf\u{E9}"
            let decomposed = tab.shownFolderPath + "/cafe\u{301}"

            content.setDropTarget(composed, .valid, background: nil)
            #expect(content.dropState(for: composed) == .valid)
            #expect(content.dropState(for: decomposed) == nil)

            content.setDropTarget(decomposed, .valid, background: nil)
            #expect(content.dropState(for: decomposed) == .valid)
            #expect(content.dropState(for: composed) == nil)

            content.setDropTarget(nil, nil, background: nil)
            #expect(content.dropState(for: decomposed) == nil)
            await harness.close()
        }

        // A drop on one of the two folders goes into it, though the other is the item dragged.
        @Test func aDropOnOneTakesTheOtherAsAnItem() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let composed = tab.shownFolderPath + "/caf\u{E9}"
            let decomposed = tab.shownFolderPath + "/cafe\u{301}"
            let session = DragSession(
                sourceSurface: .external, sourceItems: [DragItem(path: composed, kind: .directory)],
                leadPath: composed, leadKind: .directory)
            func refusal(_ path: String) -> DropRefusal? {
                tab.dragDrop.decide(
                    session, target: TabDragDrop.Target(surface: .tree, path: path, supportsMove: true),
                    offersMove: true, modifiers: [.option]
                ).refusal
            }
            #expect(refusal(decomposed) == nil)
            #expect(refusal(composed) == .samePath)
            await harness.close()
        }
    }
}
