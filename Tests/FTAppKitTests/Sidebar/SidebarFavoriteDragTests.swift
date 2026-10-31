// Ports the favorites' drag of components/TreePane.tsx (F-738) past the automation seam: what a real drag carries, on a
// real pasteboard, through the outline's dragging destination, the preference channel and back into the rows
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// What AppKit hands a destination during a drag: the pasteboard is the part that matters here.
@MainActor
private final class FavoriteDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    var draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSequenceNumber: Int { 1 }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(favorite path: String, window: NSWindow?) {
        draggingDestinationWindow = window
        draggingLocation = .zero
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects([SidebarPasteboard.item(favorite: path)])
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
    @Suite struct SidebarFavoriteDragTests: SidebarTesting {
        private let paths = ["/Applications", "/Library", "/System", "/Users", "/tmp"]

        private func open(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            tab.updatePreferences([
                "favoritesPlacement": .string("separate"), "favoritesInitialized": .bool(true),
                "favoritesExpanded": .bool(true),
                "favorites": .array(
                    paths.map { .object(["path": .string($0), "icon": .string(FavoriteIconID.folder.rawValue)]) }),
            ])
            let controller = sidebar(tab)
            _ = await waitUntil { controller.model.favorites.map(\.path) == paths }
            harness.layout(tab)
            return tab
        }

        private func order(_ controller: SidebarViewController) -> [String] {
            cells(controller).compactMap { $0.state?.item.kind == .favorite ? $0.state?.item.path : nil }
        }

        /// A point in the top or bottom half of a favorite's row, in window coordinates, as `draggingLocation` is.
        private func location(of path: String, _ position: Favorites.DropPosition, in list: SidebarListView) throws
            -> NSPoint
        {
            let index = try #require(list.index(ofItem: .favorite(path)))
            let rect = list.outline.rect(ofRow: index)
            let y = position == .before ? rect.minY + 2 : rect.minY + rect.height * 0.75
            return list.outline.convert(NSPoint(x: rect.midX, y: y), to: nil)
        }

        // F-738: AppKit drops data put under a type that isn't a valid UTI, so a favorite's drag has to reach the
        // destination with the path on it, under a type the outline registered.
        // B-TREE-041
        @Test func aFavoritesDragCarriesItsPathOnThePasteboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await open(harness)
            let info = FavoriteDraggingInfo(favorite: "/tmp", window: tab.window)
            defer { info.draggingPasteboard.releaseGlobally() }
            #expect(info.draggingPasteboard.types?.contains(SidebarPasteboard.favoriteType) == true)
            #expect(info.draggingPasteboard.string(forType: SidebarPasteboard.favoriteType) == "/tmp")
            #expect(sidebar(tab).sections.outline.registeredDraggedTypes.contains(SidebarPasteboard.favoriteType))
            await harness.close()
        }

        // F-738: a scenario's `drag` step goes through the real pasteboard: what the row's drag writes, offered to the row
        // AppKit would ask, which reorders and saves.
        @Test func theDriversFavoriteDragGoesThroughARealPasteboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await open(harness)
            let controller = sidebar(tab)
            let list = controller.sections
            let first = try #require(order(controller).first)
            let last = try #require(order(controller).last)
            #expect(first != last)
            let start = list.outline.convert(try location(of: first, .before, in: list), from: nil)
            let drag = try #require(list.outline.automationPasteboardDrag(at: start))
            #expect(drag.item.string(forType: SidebarPasteboard.favoriteType) == first)
            let result = AutomationDrag.play(
                drag, over: list.outline, at: try location(of: last, .after, in: list))
            #expect(result == .dropped)
            #expect(order(controller).last == first)
            await harness.close()
        }

        // F-738 B-TREE-043: the whole way, past the automation seam: the top half of a row drops before it, the bottom
        // half after it, the line marks the spot, the dragged row dims; the new order is saved, and stays when the
        // channel's save comes back into the sidebar.
        // B-TREE-034 B-TREE-041 B-TREE-042
        @Test func draggingAFavoriteOverAnotherPutsItThereAndSavesIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await open(harness)
            let controller = sidebar(tab)
            let list = controller.sections
            let info = FavoriteDraggingInfo(favorite: "/tmp", window: tab.window)
            defer { info.draggingPasteboard.releaseGlobally() }

            controller.sidebarList(list, favoriteDragStarted: "/tmp")
            #expect(cells(controller).first { $0.state?.item.path == "/tmp" }?.state?.dragging == true)

            info.draggingLocation = try location(of: "/Library", .before, in: list)
            #expect(list.outline.draggingEntered(info) == .move)
            #expect(list.outline.draggingUpdated(info) == .move)
            #expect(controller.dropTarget?.path == "/Library" && controller.dropTarget?.position == .before)
            #expect(cells(controller).first { $0.state?.item.path == "/Library" }?.state?.dropLine == .before)

            #expect(list.outline.prepareForDragOperation(info))
            #expect(list.outline.performDragOperation(info))
            controller.sidebarListFavoriteDragEnded(list)

            let moved = ["/Applications", "/tmp", "/Library", "/System", "/Users"]
            #expect(controller.model.favorites.map(\.path) == moved)
            #expect(harness.store.preferences().favorites.map(\.path) == moved)
            #expect(order(controller) == moved)
            #expect(controller.draggedFavorite == nil && controller.dropTarget == nil)

            // And down the list, on a row's bottom half.
            info.draggingPasteboard.clearContents()
            info.draggingPasteboard.writeObjects([SidebarPasteboard.item(favorite: "/Applications")])
            controller.sidebarList(list, favoriteDragStarted: "/Applications")
            info.draggingLocation = try location(of: "/System", .after, in: list)
            #expect(list.outline.draggingUpdated(info) == .move)
            #expect(list.outline.performDragOperation(info))
            controller.sidebarListFavoriteDragEnded(list)
            let again = ["/tmp", "/Library", "/System", "/Applications", "/Users"]
            #expect(harness.store.preferences().favorites.map(\.path) == again)
            #expect(order(controller) == again)
            await harness.close()
        }

        // F-738: over the dragged row itself nothing is marked and nothing moves.
        // B-TREE-042
        @Test func droppingAFavoriteOnItselfChangesNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await open(harness)
            let controller = sidebar(tab)
            let list = controller.sections
            let info = FavoriteDraggingInfo(favorite: "/System", window: tab.window)
            defer { info.draggingPasteboard.releaseGlobally() }
            controller.sidebarList(list, favoriteDragStarted: "/System")
            info.draggingLocation = try location(of: "/System", .after, in: list)
            #expect(list.outline.draggingUpdated(info) == .move)
            #expect(controller.dropTarget == nil)
            #expect(list.outline.performDragOperation(info))
            controller.sidebarListFavoriteDragEnded(list)
            #expect(controller.model.favorites.map(\.path) == paths)
            await harness.close()
        }
    }
}
