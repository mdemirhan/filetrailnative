// Checks against useDialogFocus.ts:22 and useExplorerTabs.ts:862-867: an open dialog keeps the keyboard, so a tab shown
// again under its own dialog leaves it there.
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabBackUnderAlertTests {
        @Test func aTabComingBackUnderItsAlertLeavesTheKeyboardInTheAlert() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let group = try #require(first.group)
            first.perform(.viewAsDetails)
            first.content.focusList()
            group.openTab(path: harness.folder.appending("Alpha").path, from: first)
            #expect(await waitUntil { group.tabs.count == 2 })
            let second = try #require(group.tabs.last)
            group.select(second)
            let window = try #require(first.window)
            let scrim = InWindowAlerts.present(
                AlertContent(
                    title: "T", message: nil, buttons: [AlertButton(title: "OK", variant: .plain) {}], stacked: nil,
                    accessory: nil, onEscape: {}), in: window)
            #expect((window.firstResponder as? NSView)?.isDescendant(of: scrim) == true)
            group.select(first)
            #expect((window.firstResponder as? NSView)?.isDescendant(of: scrim) == true)
            // The dialog hands the keyboard back to the pane it took it from.
            scrim.dismiss()
            #expect(window.firstResponder === first.content.focusView)
            await harness.close()
        }
    }
}
