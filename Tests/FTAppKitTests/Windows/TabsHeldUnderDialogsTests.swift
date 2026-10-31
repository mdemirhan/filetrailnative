// Checks against useExplorerTabs.ts:394-397,423 (`canChangeTabs`, `activateTab`) and App.tsx:1150 (`blocked`): while a
// dialog is open the tab on screen stays; on a tab group that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// The system's tab bar is built only for a window on screen: this takes its place, known by its class's name.
private final class NSTabBarStandIn: NSView {}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabsHeldUnderDialogsTests {
        private func twoTabs(_ harness: ExplorerHarness) async throws -> (MainWindowController, MainWindowController) {
            let first = try await harness.open()
            let group = try #require(first.group)
            group.openTab(path: harness.folder.appending("Alpha").path, from: first)
            #expect(await waitUntil { group.tabs.count == 2 })
            let second = try #require(group.tabs.last)
            group.select(first)
            #expect(group.selected === first)
            return (first, second)
        }

        private func cameKey(_ tab: MainWindowController) {
            tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        }

        /// A press on a stand-in for the tab bar, low in the window, away from the title bar and its veil.
        private func tabBarPress(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
            let frameView = try #require(window.contentView?.superview)
            let bar =
                frameView.subviews.first { $0 is NSTabBarStandIn }
                ?? {
                    let bar = NSTabBarStandIn(frame: NSRect(x: 100, y: 20, width: 200, height: 30))
                    frameView.addSubview(bar, positioned: .above, relativeTo: nil)
                    return bar
                }()
            let location = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
            #expect(ExplorerTabGroup.isTabBarPress(at: location, in: window))
            return try #require(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        // The tabs lie under `.go-to-folder-backdrop` (styles.css:3435, fixed over the whole window), whose `onMouseDown`
        // closes the box (GoToFolderDialog.tsx:271): a left press on a tab closes it and the tab on screen stays.
        // B-SRCH-167
        @Test func aLeftPressOnATabIsAPressOnTheScrim() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, _) = try await twoTabs(harness)
            let group = try #require(first.group)
            let window = try #require(first.window)

            first.openLocationSheet()
            #expect(WindowEventRouting.intercept(try tabBarPress(.rightMouseDown, in: window), in: window))
            #expect(WindowEventRouting.intercept(try tabBarPress(.otherMouseDown, in: window), in: window))
            #expect(first.goToBox != nil)

            #expect(WindowEventRouting.intercept(try tabBarPress(.leftMouseDown, in: window), in: window))
            #expect(first.goToBox == nil)
            #expect(group.selected === first)

            #expect(!WindowEventRouting.intercept(try tabBarPress(.leftMouseDown, in: window), in: window))
            await harness.close()
        }

        // An alert's scrim takes no press, and a name being edited has no scrim: the tab bar is only held.
        @Test func aPressOnATabLeavesAnAlertAndAnInlineRenameOpen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, _) = try await twoTabs(harness)
            let window = try #require(first.window)
            let press = try tabBarPress(.leftMouseDown, in: window)

            let alert = InWindowAlerts.present(AlertContent(title: "Stop", message: nil, buttons: []), in: window)
            #expect(WindowEventRouting.intercept(press, in: window))
            #expect(DialogScrim.front(in: window) != nil)
            alert.dismiss()

            #expect(first.content.beginRename(path: harness.folder.appending("Alpha").path))
            #expect(WindowEventRouting.intercept(press, in: window))
            #expect(first.content.inlineRename != nil)
            first.content.renameCancelled()
            await harness.close()
        }

        // Anything that brings a tab forward by the system's way: the tab holding the dialog stays the tab on
        // screen, so the window's tab commands don't go dead over a dialog out of sight.
        @Test func aTabComingForwardGivesWayToTheOneWithTheDialog() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let group = try #require(first.group)
            first.openLocationSheet()
            #expect(first.isDialogOpen && group.isBlocked)

            cameKey(second)
            #expect(group.selected === first)

            first.goToBox?.onClose()
            #expect(!group.isBlocked)
            cameKey(second)
            #expect(group.selected === second)
            await harness.close()
        }

        // An alert drawn in the window and a name being edited hold the tabs the same way (`renameDialogState`).
        // B-SRCH-167
        @Test func anAlertAndAnInlineRenameHoldTheTabsToo() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let group = try #require(first.group)
            let window = try #require(first.window)
            let alert = InWindowAlerts.present(AlertContent(title: "Stop", message: nil, buttons: []), in: window)
            cameKey(second)
            #expect(group.selected === first)
            alert.dismiss()

            #expect(first.content.beginRename(path: harness.folder.appending("Alpha").path))
            cameKey(second)
            #expect(group.selected === first)
            first.content.renameCancelled()
            cameKey(second)
            #expect(group.selected === second)
            await harness.close()
        }

        // The Window menu's list goes through the window itself: it stays back, off screen as it was.
        @Test func theWindowOfAnotherTabRefusesToComeForward() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let group = try #require(first.group)
            #expect(!group.refusesFront(second))
            first.openLocationSheet()
            #expect(group.refusesFront(second))
            #expect(!group.refusesFront(first))
            second.window?.makeKeyAndOrderFront(nil)
            #expect(second.window?.isVisible == false)
            #expect(group.selected === first)
            first.goToBox?.onClose()
            #expect(!group.refusesFront(second))
            await harness.close()
        }

        // A dialog on a tab at the back (a notice from a copy that tab started) can still be reached.
        @Test func aDialogOnATabAtTheBackDoesNotHoldTheTabOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let group = try #require(first.group)
            second.openLocationSheet()
            #expect(group.isBlocked)
            #expect(!group.refusesFront(second))
            #expect(!group.holdsTabBar)
            cameKey(second)
            #expect(group.selected === second)
            #expect(group.holdsTabBar)
            await harness.close()
        }

        // A tab's close button, should a press get past the hold on the tab bar.
        @Test func aTabIsNotClosedFromTheTabBarWhileADialogIsOpen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let group = try #require(first.group)
            #expect(!group.holdsTabBar)
            first.openLocationSheet()
            #expect(group.holdsTabBar)
            #expect(!group.shouldCloseTab(second))
            #expect(!group.shouldCloseTab(first))
            #expect(group.tabs.count == 2)
            #expect(group.selected === first)
            first.goToBox?.onClose()
            #expect(!group.holdsTabBar)
            await harness.close()
        }
    }
}
