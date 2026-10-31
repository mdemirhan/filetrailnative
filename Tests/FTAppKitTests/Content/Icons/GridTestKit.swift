// Helpers for the windowless suites of the Icons view and the Compact List: a probe of the grid of a window, and the
// pointer and keys that reach it as a person's do
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// The Icons view or the Compact List of a window.
@MainActor
struct GridProbe {
    let tab: MainWindowController

    var grid: ItemGridView? { descendants(of: tab.window?.contentView, ItemGridView.self).first }
    var pane: ItemGridPane? { grid?.pane }
    var icons: IconViewController? { pane as? IconViewController }
    var compact: CompactListViewController? { pane as? CompactListViewController }
    var window: NSWindow { tab.window ?? NSWindow() }

    func layout() {
        tab.window?.contentView?.layoutSubtreeIfNeeded()
        pane?.root.layoutSubtreeIfNeeded()
        grid?.layoutSubtreeIfNeeded()
    }

    /// The items on screen, by name.
    var iconItems: [String: IconItem] {
        guard let grid else { return [:] }
        var found: [String: IconItem] = [:]
        for path in grid.indexPathsForVisibleItems() {
            if let item = grid.item(at: path) as? IconItem, let name = item.textField?.stringValue {
                found[name] = item
            }
        }
        return found
    }

    var compactItems: [String: CompactListItem] {
        guard let grid else { return [:] }
        var found: [String: CompactListItem] = [:]
        for path in grid.indexPathsForVisibleItems() {
            if let item = grid.item(at: path) as? CompactListItem { found[item.label.stringValue] = item }
        }
        return found
    }

    var selectedNames: [String] {
        let paths = tab.content.selection.paths
        return tab.content.entries.filter { paths.contains($0.path) }.map(\.name)
    }

    /// A point of a view, in window coordinates.
    func point(in view: NSView, at local: NSPoint? = nil) -> NSPoint {
        let spot = local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        return view.convert(spot, to: nil)
    }

    /// A press and the release where it went down (or at the last move); the events that follow the press are handed to
    /// the pane the way its event loop would take them.
    func press(at point: NSPoint, moves: [NSPoint] = [], count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        guard let grid else { return }
        for number in 1...max(1, count) {
            var queue: [NSEvent] = []
            for move in moves {
                if let event = MouseEvents.event(.leftMouseDragged, at: move, in: window, modifiers: modifiers) {
                    queue.append(event)
                }
            }
            if let up = MouseEvents.event(
                .leftMouseUp, at: moves.last ?? point, in: window, clickCount: number, modifiers: modifiers)
            {
                queue.append(up)
            }
            PointerTracker.source = { _, _, _ in queue.isEmpty ? nil : queue.removeFirst() }
            if let down = MouseEvents.event(
                .leftMouseDown, at: point, in: window, clickCount: number, modifiers: modifiers)
            {
                grid.mouseDown(with: down)
            }
        }
        PointerTracker.source = { window, mask, until in
            window.nextEvent(matching: mask, until: until ?? .distantFuture, inMode: .eventTracking, dequeue: true)
        }
    }

    /// A key pressed with the grid focused.
    func key(_ name: String, modifiers: NSEvent.ModifierFlags = []) {
        guard let key = KeyEvents.key(named: name) else {
            Issue.record("no key \(name)")
            return
        }
        for event in KeyEvents.events(key, modifiers: modifiers, window: window) where event.type == .keyDown {
            grid?.keyDown(with: event)
        }
    }
}

extension ExplorerHarness {
    /// A window on a folder of `count` files named item-000…, in a view mode.
    func openGrid(_ mode: RendererCommand, files count: Int? = nil) async throws -> (MainWindowController, GridProbe) {
        let path = try count.map { try makeFolder(named: "Many", files: $0).path }
        let tab = try await open(path)
        tab.perform(mode)
        let probe = GridProbe(tab: tab)
        let expected = count ?? 4
        #expect(await waitUntil { tab.content.entries.count == expected && probe.pane != nil })
        layout(tab)
        probe.layout()
        return (tab, probe)
    }
}
