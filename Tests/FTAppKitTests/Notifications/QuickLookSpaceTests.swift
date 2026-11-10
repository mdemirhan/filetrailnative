// Space sent through the window to the focused list
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

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct QuickLookSpaceTests {
        func opened(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            #expect(await waitUntil { tab.content.entries.count >= 4 })
            return tab
        }

        // Space previews the selected item, and Space again closes the panel
        // The panel zooms out of the item's icon in the List, wherever the density puts it: past the row's inset and
        // padding, at the icon size the List draws.
        @Test(arguments: ["standard", "finder"])
        func zoomsOutOfTheIconTheListDraws(density: String) async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.updatePreferences(["density": .string(density)])
            tab.perform(.viewAsDetails)
            tab.refreshColumns()
            harness.layout(tab)
            let list = try #require(tab.content.pane as? ListViewController)
            #expect(list.layoutMetrics == DesignTokens.details(density: density == "finder" ? .finder : .standard))
            let item = try #require(tab.content.entries.first)
            let metrics = list.layoutMetrics
            let table = list.table
            let row = table.rect(ofRow: 0)

            let frame = try #require(
                QuickLookItemFrame.screenFrame(of: item.path, entries: tab.content.entries, in: tab.content.view))

            let window = try #require(tab.window)
            let inTable = table.convert(window.convertFromScreen(frame), from: nil)
            #expect(abs(inTable.minX - (row.minX + CGFloat(metrics.rowInset + metrics.rowPaddingInline))) < 0.5)
            #expect(abs(inTable.width - CGFloat(metrics.iconSize)) < 0.5)
            await harness.close()
        }

        // Closed, the panel lets go of what told it where its item was: that holds the tab's list.
        @Test func lettingGoOfThePanelLetsGoOfTheTabItCameFrom() {
            final class Pane {}
            let quickLook = QuickLookController.shared
            let system = quickLook.panel
            quickLook.panel = FakeQuickLookPanel()
            defer { quickLook.panel = system }
            weak var held: Pane?
            do {
                let pane = Pane()
                held = pane
                quickLook.show("/f/a.txt", from: nil) { _ in
                    _ = pane
                    return nil
                }
            }
            #expect(held != nil)

            quickLook.ended()

            #expect(held == nil)
        }

        @Test func spacePreviewsTheSelectedItemWithQuickLookAndSpaceAgainClosesIt() async throws {
            let harness = try ExplorerHarness.windowless()
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
            quickLook.close()
            await harness.close()
        }
    }
}
