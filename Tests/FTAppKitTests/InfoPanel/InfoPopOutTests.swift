// The Info panel in a window of its own, and how the panel and the row keep an item while the next one's answers
// come, on windows that are never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct InfoPopOutTests {
        func texts(_ id: String, in tab: MainWindowController) -> [String] {
            guard let root = tab.window?.contentView?.superview else { return [] }
            return findViews(id, in: root).map(fieldText)
        }

        // While the Info window or a popover of a tab has the keyboard, the menus act on that tab.
        @Test func theMenusActOnTheTabTheInfoWindowDescribes() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let popOut = InfoPopOut.shared
            let before = popOut.owner
            defer { popOut.owner = before }
            let info = InfoPopOutWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered,
                defer: true)
            info.isReleasedWhenClosed = false
            popOut.owner = tab
            #expect(harness.windows.handle(for: info) === tab)
            popOut.owner = nil
            #expect(harness.windows.handle(for: info) == nil)
            // A popover's window is a child of the window it hangs from.
            let window = try #require(tab.window)
            let child = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                backing: .buffered, defer: true)
            child.isReleasedWhenClosed = false
            window.addChildWindow(child, ordered: .above)
            defer { window.removeChildWindow(child) }
            #expect(harness.windows.handle(for: child) === tab)
            await harness.close()
        }

        // The window describing a tab that closed lets go of it, and hides until another tab takes it; another
        // tab's going changes nothing.
        @Test func theInfoWindowLetsGoOfATabThatClosed() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let other = try await harness.open()
            let popOut = InfoPopOut.shared
            let before = popOut.owner
            defer { popOut.owner = before }
            popOut.owner = tab
            popOut.ownerGone(other)
            #expect(popOut.owner === tab)
            popOut.ownerGone(tab)
            #expect(popOut.owner == nil)
            #expect(!(popOut.window?.isVisible ?? false))
            await harness.close()
        }

        // Moving on before the answers come shows an item once the wait from the first change has run out: a key
        // held down doesn't keep the panel on the item it started from.
        @Test func theWaitRunsFromTheFirstChange() async throws {
            let harness = try ExplorerHarness.windowless()
            for name in ["a.txt", "b.txt", "c.txt"] {
                try "x".write(to: harness.folder.appending(name), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let info = try #require(tab.infoController)
            let folderName = harness.folder.path.split(separator: "/").last.map(String.init) ?? ""
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == [folderName] })
            // The details never come in time: only the wait shows another item.
            info.detailsReader = { _, cancel in
                for _ in 0..<100 where !cancel.isCancelled { usleep(10_000) }
                return nil
            }
            info.holdGrace = 0.3
            let started = ContinuousClock.now
            for name in ["a.txt", "b.txt", "c.txt"] {
                tab.content.select(paths: [harness.folder.appending(name).path])
                try await Task.sleep(for: .milliseconds(120))
            }
            #expect(await waitUntil { texts("infoPanel.name", in: tab) != [folderName] })
            // Shown about 0.3 s after the first change, not 0.3 s after the last one (0.54 s).
            #expect(ContinuousClock.now - started < .milliseconds(500))
            await harness.close()
        }

        // With only the Info Row open, several items and the folder on screen show at once: what the panel waits
        // for (their tags, the folder's details) isn't read for the row.
        @Test func theRowAloneDoesntWaitForWhatOnlyThePanelReads() async throws {
            let harness = try ExplorerHarness.windowless()
            for name in ["a.txt", "b.txt"] {
                try "x".write(to: harness.folder.appending(name), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            let info = try #require(tab.infoController)
            info.holdGrace = 30
            let paths = ["a.txt", "b.txt"].map { harness.folder.appending($0).path }
            tab.content.select(paths: paths)
            #expect(
                await waitUntil(timeout: .seconds(5)) { texts("infoRow.name", in: tab).first?.hasSuffix("(2)") == true }
            )
            tab.content.select(paths: [])
            let folderName = harness.folder.path.split(separator: "/").last.map(String.init) ?? ""
            #expect(await waitUntil(timeout: .seconds(5)) { texts("infoRow.name", in: tab) == [folderName] })
            await harness.close()
        }
    }
}
