// The Icons view's and the Compact List's parts P5-04's review left to P5-07: a renaming item takes presses everywhere
// on it (IconGridView.tsx:324-340, styles.css:2676-2688), a wheel notch moves the Compact List 40 sideways (B-VIEW-035),
// and both views read the details of search results on screen (App.tsx onVisiblePathsChange)
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
        // F-778: a press beside the tile of an item being renamed keeps the selection and the field.
        // B-SEL-136
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

        // B-SEL-136
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

        // B-VIEW-035: a line-based wheel notch moves the Compact List 40 sideways, as Chromium moves it.
        // B-SEL-069
        @Test func aWheelNotchMovesTheCompactListFortySideways() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let scroll = try #require(probe.pane?.scroll as? ItemGridScrollView)
            let start = scroll.contentView.bounds.origin.x
            let cgEvent = try #require(
                CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
            let event = try #require(NSEvent(cgEvent: cgEvent))
            #expect(!event.hasPreciseScrollingDeltas)
            scroll.scrollWheel(with: event)
            // The notch's lines as the event reports them: macOS may accelerate wheel events made close together, as
            // suites running side by side make them.
            let lines = -event.scrollingDeltaY
            #expect(lines >= 1)
            #expect(scroll.contentView.bounds.origin.x - start == lines * CGFloat(ItemGridScrollView.wheelLineStep))
            await harness.close()
        }

        // The details of the results on screen are read in the Icons view too, for the status line's sizes.
        // B-VIEW-012
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
            tab.content.loaders.metadata = { _, paths in
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
