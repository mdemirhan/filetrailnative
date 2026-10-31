// Covers by feature what Chromium's drag autoscroll gives the original's Icons view, Compact List and tree: a drag held
// at an edge scrolls, on a window that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// What AppKit hands a destination during a drag, at a point of the window.
@MainActor
final class StubDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    var draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSequenceNumber: Int
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any?
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(paths: [String] = [], at location: NSPoint = .zero, sequence: Int = 1, window: NSWindow?) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingSequenceNumber = sequence
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct DragEdgeScrollTests {
        /// Holds a drag at `spot` (in the clip view's coordinates) through drag-overs 0.05 s apart, `duration` long.
        private func hold(
            at spot: (NSRect) -> NSPoint, in clip: NSClipView, duration: TimeInterval, sequence: Int = 1,
            over: (StubDraggingInfo) -> Void, setClock: (@escaping () -> TimeInterval) -> Void
        ) {
            let time = Box(0.0)
            setClock { time.value }
            let info = StubDraggingInfo(
                at: clip.convert(spot(clip.bounds), to: nil), sequence: sequence, window: clip.window)
            defer { info.draggingPasteboard.releaseGlobally() }
            while time.value <= duration {
                info.draggingLocation = clip.convert(spot(clip.bounds), to: nil)
                over(info)
                time.value += 0.05
            }
        }

        private final class Box {
            var value: Double
            init(_ value: Double) { self.value = value }
        }

        // A drag held at the bottom edge of the Icons view scrolls it, after a moment; at the top edge back up; in the
        // middle, or only passing by, not at all.
        @Test func theIconsViewScrollsUnderADragHeldAtItsEdge() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsIcons, files: 400)
            let grid = try #require(probe.grid)
            let clip = try #require(grid.enclosingScrollView?.contentView)
            func run(_ spot: (NSRect) -> NSPoint, _ duration: TimeInterval, sequence: Int) {
                hold(
                    at: spot, in: clip, duration: duration, sequence: sequence,
                    over: { _ = grid.draggingUpdated($0) }, setClock: { grid.edgeScroll.clock = $0 })
                grid.draggingExited(nil)
            }
            let bottom: (NSRect) -> NSPoint = { NSPoint(x: $0.midX, y: $0.maxY - 4) }
            let top: (NSRect) -> NSPoint = { NSPoint(x: $0.midX, y: $0.minY + 4) }
            #expect(clip.bounds.minY == 0)
            run(bottom, 0.1, sequence: 1)
            #expect(clip.bounds.minY == 0)
            run({ NSPoint(x: $0.midX, y: $0.midY) }, 1, sequence: 2)
            #expect(clip.bounds.minY == 0)
            run(bottom, 1, sequence: 3)
            let scrolled = clip.bounds.minY
            #expect(scrolled > 100)
            run(top, 0.5, sequence: 4)
            #expect(clip.bounds.minY < scrolled)
            await harness.close()
        }

        // The Compact List runs sideways, and scrolls at its right edge.
        @Test func theCompactListScrollsSideways() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsList, files: 400)
            let grid = try #require(probe.grid)
            let clip = try #require(grid.enclosingScrollView?.contentView)
            hold(
                at: { NSPoint(x: $0.maxX - 4, y: $0.midY) }, in: clip, duration: 1,
                over: { _ = grid.draggingUpdated($0) }, setClock: { grid.edgeScroll.clock = $0 })
            #expect(clip.bounds.minX > 100)
            await harness.close()
        }

        // A long list in the sidebar scrolls at its bottom edge.
        @Test func theSidebarScrollsUnderADragHeldAtItsEdge() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let paths = (0..<100).map { "/tmp/favorite-\($0)" }
            tab.updatePreferences([
                "favoritesPlacement": .string("separate"), "favoritesInitialized": .bool(true),
                "favoritesExpanded": .bool(true),
                "favorites": .array(
                    paths.map { .object(["path": .string($0), "icon": .string(FavoriteIconID.folder.rawValue)]) }),
            ])
            let controller = tab.sidebarController
            #expect(await waitUntil { controller.model.favorites.count == 100 })
            harness.layout(tab)
            let outline = controller.sections.outline
            let clip = try #require(outline.enclosingScrollView?.contentView)
            hold(
                at: { NSPoint(x: $0.midX, y: $0.maxY - 4) }, in: clip, duration: 1,
                over: { _ = outline.draggingUpdated($0) }, setClock: { outline.edgeScroll.clock = $0 })
            #expect(clip.bounds.minY > 100)
            await harness.close()
        }
    }
}
