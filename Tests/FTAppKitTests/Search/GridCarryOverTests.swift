// The Icons view and the Compact List: a renaming item takes presses everywhere on it, a wheel notch moves the
// Compact List 40 sideways, and both views read the details of search results on screen
import AppKit
import CoreGraphics
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct GridCarryOverTests {
        // A press beside the tile of an item being renamed keeps the selection and the field.
        @Test func aRenamingIconItemTakesPressesEverywhereOnIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            #expect(tab.content.beginRename(path: note.path))
            let item = try #require(probe.iconItems["note.txt"])
            probe.press(at: probe.point(in: item.view, at: NSPoint(x: 4, y: 40)))
            #expect(probe.selectedNames == ["note.txt"])
            #expect(tab.content.inlineRename?.path == note.path)
            // A right-click there opens no menu and keeps the selection.
            let pane = try #require(probe.pane)
            let local = try #require(probe.grid).convert(
                probe.point(in: item.view, at: NSPoint(x: 4, y: 40)), from: nil)
            #expect(pane.menu(forEventAt: local) == nil)
            #expect(probe.selectedNames == ["note.txt"])
            await harness.close()
        }

        @Test func aRenamingCompactListItemTakesPressesEverywhereOnIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            #expect(tab.content.beginRename(path: note.path))
            let item = try #require(probe.compactItems["note.txt"])
            probe.press(at: probe.point(in: item.view, at: NSPoint(x: 2, y: 2)))
            #expect(probe.selectedNames == ["note.txt"])
            #expect(tab.content.inlineRename?.path == note.path)
            await harness.close()
        }

        // A line-based wheel notch moves the Compact List 40 sideways.
        @Test func aWheelNotchMovesTheCompactListFortySideways() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let scroll = try #require(probe.pane?.scroll as? ItemGridScrollView)
            let start = scroll.contentView.bounds.origin.x
            let event = try systemWheelEvent(.line, -1)
            #expect(!event.hasPreciseScrollingDeltas)
            // One line down, as made: AppKit speeds up only precise deltas, never a line-based notch.
            #expect(event.scrollingDeltaY == -1)
            scroll.scrollWheel(with: event)
            #expect(scroll.contentView.bounds.origin.x - start == CGFloat(ItemGridScrollView.wheelLineStep))
            await harness.close()
        }

        // The details of the results on screen are read in the Icons view too, for the status line's sizes.
        @Test func theIconsViewReadsTheDetailsOfSearchResultsOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            final class Asked { var paths: [String] = [] }
            let asked = Asked()
            tab.content.loaders.metadata = { _, paths, _, _ in
                asked.paths += paths
                return []
            }
            tab.search.session.submit("note")
            #expect(tab.content.mode == .details)
            tab.perform(.viewAsIcons)
            asked.paths = []
            probe.layout()
            tab.content.contentShell.layoutSubtreeIfNeeded()
            let path = harness.folder.path + "/note.txt"
            #expect(await waitUntil { asked.paths.contains(path) })
            await harness.close()
        }
    }
}
