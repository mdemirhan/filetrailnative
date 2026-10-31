// Helpers for the GUI suites of the selection, keyboard, rename and navigation package: a probe of the List on screen, and
// the pointer and keys that reach it as a person's do
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
func descendants<T: NSView>(of root: NSView?, _ type: T.Type) -> [T] {
    guard let root else { return [] }
    var found: [T] = []
    if let match = root as? T, !root.isHidden { found.append(match) }
    for child in root.subviews where !child.isHidden { found += descendants(of: child, type) }
    return found
}

/// The views with this accessibility identifier that show.
@MainActor
func identified(_ id: String, in root: NSView?) -> [NSView] {
    guard let root else { return [] }
    var found: [NSView] = root.accessibilityIdentifier() == id && !root.isHidden ? [root] : []
    for child in root.subviews where !child.isHidden { found += identified(id, in: child) }
    return found
}

/// The List of a window: where its rows are on screen, and what is selected in it.
@MainActor
struct ListProbe {
    let tab: MainWindowController

    var table: ListTableView? {
        descendants(of: tab.window?.contentView, ListTableView.self).first
    }

    var window: NSWindow { tab.window ?? NSWindow() }

    /// The center of a row, in window coordinates.
    func center(ofRow row: Int) -> NSPoint {
        guard let table else { return .zero }
        let rect = table.convert(table.rect(ofRow: row), to: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// A point over the list below its last row, in window coordinates.
    func emptyPoint(belowRows rows: Int) -> NSPoint {
        guard let table else { return .zero }
        let rect = table.convert(table.rect(ofRow: max(0, rows - 1)), to: nil)
        return NSPoint(x: rect.midX, y: rect.minY - 40)
    }

    var selectedNames: [String] {
        let paths = tab.content.selection.paths
        return tab.content.entries.filter { paths.contains($0.path) }.map(\.name)
    }

    var rowNames: [String] { tab.content.entries.map(\.name) }

    var hasKeyboard: Bool { window.firstResponder === table }

    /// A press, the pointer moving through `moves`, and the release at the last of them (or where it went down). The
    /// events that follow the press are handed to the pane the way its event loop would take them.
    func press(
        at point: NSPoint, moves: [NSPoint] = [], count: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let table else { return }
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
                table.mouseDown(with: down)
            }
        }
        PointerTracker.source = { window, mask, until in
            window.nextEvent(matching: mask, until: until ?? .distantFuture, inMode: .eventTracking, dequeue: true)
        }
    }

    func click(row: Int, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) async {
        press(at: center(ofRow: row), count: count, modifiers: modifiers)
    }

    func click(at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) async {
        press(at: point, modifiers: modifiers)
    }

    /// A drag from one point to another in a few steps.
    func drag(from start: NSPoint, to end: NSPoint, modifiers: NSEvent.ModifierFlags = []) async {
        let steps = 6
        let moves = (1...steps).map { step -> NSPoint in
            let fraction = Double(step) / Double(steps)
            return NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        }
        press(at: start, moves: moves, modifiers: modifiers)
    }

    func click(name: String, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) async {
        guard let row = tab.content.entries.firstIndex(where: { $0.name == name }) else {
            Issue.record("no row \(name)")
            return
        }
        await click(row: row, count: count, modifiers: modifiers)
    }

    func key(_ name: String, modifiers: NSEvent.ModifierFlags = []) {
        guard let key = KeyEvents.key(named: name) else {
            Issue.record("no key \(name)")
            return
        }
        for event in KeyEvents.events(key, modifiers: modifiers, window: window) { window.sendEvent(event) }
    }

    func type(_ text: String) {
        for character in text { key(String(character)) }
    }
}

extension ExplorerHarness {
    /// The app's file operations over the harness's windows, as the app always has them: F2 and the rename field go
    /// through them. They act while the value is kept; their journal is in a folder of their own, not in the list.
    func writeOperations() throws -> AppWriteOperations {
        let userData = FileManager.default.temporaryDirectory.appendingPathComponent(
            "filetrail-selection-writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        return AppWriteOperations(
            userData: userData, directoryService: services.directoryService, windows: windows, trash: .standIn,
            log: { _ in })
    }

    /// A folder of `count` files named item-000…, for the cases that need a list that scrolls.
    func makeFolder(named name: String, files count: Int) throws -> URL {
        let url = folder.appending(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for index in 0..<count {
            try "x".write(
                to: url.appendingPathComponent(String(format: "item-%03d.txt", index)), atomically: true,
                encoding: .utf8)
        }
        return url
    }

    /// The window shown as the List, with its rows read.
    func openList(_ path: String? = nil) async throws -> (tab: MainWindowController, list: ListProbe) {
        let tab = try await open(path)
        tab.perform(.viewAsDetails)
        // An empty folder never has rows, so this gives up soon.
        _ = await waitUntil(timeout: .seconds(5)) { !tab.content.entries.isEmpty }
        layout(tab)
        let list = ListProbe(tab: tab)
        _ = await waitUntil { list.table != nil }
        return (tab, list)
    }
}
