// Ports the Quick Look cases of App.menusAndTree.test.tsx on a real explorer window on screen: Space sent through
// the window to the focused list
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

@MainActor
final class FakeQuickLookPanel: QuickLookPanelControlling {
    var isVisible = false
    var presented = 0

    func present(_ controller: QuickLookController) {
        isVisible = true
        presented += 1
    }

    func refresh() {}

    func dismiss() { isVisible = false }
}

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct NotificationsGUITests {
        func opened(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            #expect(await waitUntil { tab.content.entries.count >= 4 })
            return tab
        }

        // T-0db05884 F-686 F-145: Space previews the selected item, and Space again closes the panel
        @Test func spacePreviewsTheSelectedItemWithQuickLookAndSpaceAgainClosesIt() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.focusList()
            tab.content.select(paths: [note.path])
            #expect(await waitUntil { tab.focusedPane == .content && tab.content.selection.paths == [note.path] })
            let quickLook = QuickLookController.shared
            let system = quickLook.panel
            let fake = FakeQuickLookPanel()
            quickLook.panel = fake
            defer { quickLook.panel = system }
            func space() {
                guard let window = tab.window,
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: " ",
                        charactersIgnoringModifiers: " ",
                        isARepeat: false, keyCode: 49)
                else { return }
                window.sendEvent(event)
            }
            space()
            #expect(quickLook.url?.path == note.path)
            #expect(quickLook.isShowing)
            space()
            #expect(!quickLook.isShowing)
            // Only the one item is previewed.
            space()
            #expect(quickLook.numberOfPreviewItems(in: nil) == 1)
            #expect(fake.presented == 2)
            // The transition leaves from the item's row.
            let frame = quickLook.sourceFrame?(URL(fileURLWithPath: note.path))
            #expect(frame != nil && frame?.isEmpty == false)
            await harness.close()
        }
    }
}
