// Checks that a row's box draws again when its cell is given another row
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SidebarRowBoxTests {
    // The list hands a cell to another row as it scrolls: the box has its own layer, and keeps a selection's fill until
    // told, which left rows highlighted that weren't selected. A layer's view always says it has nothing to draw, so the
    // layer is asked.
    @Test func aCellGivenAnotherRowDrawsItsBoxAgain() throws {
        let item = TreePresentationItem(
            id: .filesystem("/x"), kind: .filesystem, label: "Row", depth: 0, path: "/x", parentID: nil,
            expanded: false, canExpand: false)
        var state = SidebarRowState(
            item: item, subview: .tree, selection: .focused, menuTarget: false, drop: nil, ejecting: false,
            dragging: false, dropLine: nil, showsLoading: false, density: .comfortable, hasDisclosure: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 26), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cell = SidebarItemCell(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        window.contentView = cell
        cell.configure(state, width: 240)
        cell.layoutSubtreeIfNeeded()
        // A window never shown makes no layers, so the box is given the one it has on screen.
        cell.box.wantsLayer = true
        let layer = try #require(cell.box.layer)
        layer.displayIfNeeded()
        #expect(!layer.needsDisplay())

        state.selection = .none
        cell.configure(state, width: 240)
        #expect(layer.needsDisplay())
    }
}
