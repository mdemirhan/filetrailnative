// Port of the pointer and keys of the Icons and Compact List views: entryItemEvents.ts, the onMouseDown and onContextMenu
// of IconGridView.tsx (:324-347) and FlowListView (ContentPane.tsx:1270-1293), hooks/useDragSelection.ts, and the rename
// field of InlineRenameField.tsx as those views place it
import AppKit
import FTFileSystem
import FTFoundation

extension ItemGridPane {
    // MARK: Who has the keyboard

    /// Every primary press on an item or on empty space gives the keyboard to the view (B-SEL-006, B-SEL-013). A rename
    /// going on ends: leaving its field commits it.
    func giveKeyboard() {
        guard let window = collection.window else { return }
        if window.firstResponder !== collection { window.makeFirstResponder(collection) }
    }

    // MARK: Pointer

    func handleMouseDown(_ event: NSEvent) {
        guard host != nil else { return }
        let point = collection.convert(event.locationInWindow, from: nil)
        // An item being renamed takes presses everywhere on it, for its field: they do nothing else
        // (IconGridView.tsx:324-340, styles.css:2676-2688).
        if renamingItemContains(point) { return }
        giveKeyboard()
        // ⌃-click is a right click.
        if event.modifierFlags.contains(.control) {
            if let menu = collection.menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: collection) }
            return
        }
        if let index = itemIndex(at: point) {
            pressItem(at: index, event: event)
        } else {
            pressEmptySpace(event: event, at: point)
        }
    }

    /// Pointer down on an item selects it when it is not selected or ⌘ or ⇧ is held, and the click that follows narrows
    /// a selection of several to it, so pressing a selected item can still start a drag of the whole selection
    /// (B-VIEW-069, B-VIEW-070).
    private func pressItem(at index: Int, event: NSEvent) {
        guard let host else { return }
        let entry = entries[index]
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let held = ContentSelection.Modifiers(
            meta: flags.contains(.command), shift: flags.contains(.shift), control: flags.contains(.control))
        let selected = host.selection.paths.contains(entry.path)
        if let next = host.selection.afterPress(
            entryPaths: host.entryPaths, path: entry.path, selected: selected, modifiers: held)
        {
            host.selectionChanged(next)
        }
        // Follow the pointer until the button goes up: a drag is not a click.
        let start = event.locationInWindow
        var dragged = false
        while let window = collection.window,
            let next = PointerTracker.next(in: window, matching: [.leftMouseUp, .leftMouseDragged])
        {
            if next.type == .leftMouseDragged {
                let here = next.locationInWindow
                if !dragged, hypot(here.x - start.x, here.y - start.y) >= DragSelection.threshold {
                    dragged = true
                    let carried = host.selection.paths.contains(entry.path) ? selectedEntries : [entry]
                    if host.dragHooks.beginDrag?(carried, next, collection) == true { return }
                }
                continue
            }
            if dragged { return }
            let upPoint = collection.convert(next.locationInWindow, from: nil)
            guard itemIndex(at: upPoint) == index else { return }
            clicked(entry: entry, clickCount: event.clickCount, modifiers: held)
            return
        }
    }

    /// The click that completes a press on an item (`click` and `doubleClick` of `entryItemEvents.ts`).
    private func clicked(entry: DirectoryEntry, clickCount: Int, modifiers held: ContentSelection.Modifiers) {
        guard let host else { return }
        // Only the second click: `dblclick` fires once, and a third click is just a click.
        if clickCount == 2 {
            // ⌘-double-click on a folder opens it in a new tab (B-VIEW-071).
            host.activate([entry], newTab: held.meta)
            return
        }
        let selected = host.selection.paths.contains(entry.path)
        if ContentSelection.isNarrowingClick(
            button: 0, detail: clickCount, modifiers: held, selectedCount: host.selection.paths.count,
            isSelected: selected)
        {
            host.selectionChanged(.single(entry.path))
        }
    }

    /// The menu for a right-click: on an item, which keeps the selection when it is selected and otherwise selects it
    /// alone first; or on the empty space, which clears the selection (B-VIEW-072). The view gets the keyboard either
    /// way.
    func menu(forEventAt point: NSPoint) -> NSMenu? {
        guard let host, !renamingItemContains(point) else { return nil }
        giveKeyboard()
        if let index = itemIndex(at: point) {
            let path = entries[index].path
            if !host.selection.paths.contains(path) { host.selectionChanged(.single(path)) }
            return host.contextMenu(for: selectedEntries)
        }
        host.selectionChanged(.empty)
        return host.contextMenu(for: nil)
    }

    /// Whether a point of the collection is on the item being renamed.
    func renamingItemContains(_ point: NSPoint) -> Bool {
        guard let path = renamingPath, let index = indexByPath[path],
            let item = collection.item(at: IndexPath(item: index, section: 0))
        else { return false }
        return item.view.frame.contains(point)
    }

    // MARK: Empty space and the marquee

    /// A press on empty space clears the selection (unless ⇧ or ⌘ is held) and starts a marquee (B-VIEW-073).
    private func pressEmptySpace(event: NSEvent, at point: NSPoint) {
        guard let host else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let meta = flags.contains(.command)
        let shift = flags.contains(.shift)
        if !meta, !shift { host.selectionChanged(.empty) }
        runMarquee(from: event, at: point, meta: meta, shift: shift)
    }

    /// The measured sizes of the items on screen, added to those measured earlier in the drag.
    private func measureVisible(into sizes: inout [String: DragSelectionSize]) {
        forEachVisibleItem { item, entry in
            if let size = (item as? GridItemView)?.measuredSize { sizes[entry.path] = size }
        }
    }

    /// Drag-to-select (`useDragSelection`): the box follows the pointer, the selection follows the box, and the view
    /// scrolls while the pointer is past one of its edges (B-VIEW-077 to B-VIEW-082).
    private func runMarquee(from event: NSEvent, at start: NSPoint, meta: Bool, shift: Bool) {
        guard let host, let window = collection.window else { return }
        let mode = DragSelection.mode(meta: meta, shift: shift)
        let startPaths = mode == .replace ? [] : host.selection.paths
        // A replaced selection has no lead until the drag ends, so the view does not scroll to reveal one meanwhile.
        let startLead = mode == .replace ? nil : host.selection.leadPath
        let paths = host.entryPaths
        let startWindow = event.locationInWindow
        var pointer = startWindow
        var dragging = false
        var shownKey = ""
        var shownPaths = startPaths
        var hits: [DragSelectionHit] = []
        var sizes: [String: DragSelectionSize] = [:]
        var end = (x: 0.0, y: 0.0)

        func leadFor(_ picked: [String]) -> String? {
            startLead.flatMap { picked.contains($0) ? $0 : nil }
        }

        func update() {
            let visible = collection.visibleRect
            let here = collection.convert(pointer, from: nil)
            // The box ends at the pointer, kept within the part of the view on screen.
            let inArea = NSPoint(
                x: min(max(here.x, visible.minX), visible.maxX), y: min(max(here.y, visible.minY), visible.maxY))
            let box = DragSelection.box(
                from: (Double(start.x), Double(start.y)), to: (Double(inArea.x), Double(inArea.y)))
            marquee.show(NSRect(x: box.left, y: box.top, width: box.right - box.left, height: box.bottom - box.top))
            collection.addSubview(marquee, positioned: .above, relativeTo: nil)
            end = (Double(inArea.x), Double(inArea.y))
            measureVisible(into: &sizes)
            hits = marqueeHits(box: box, sizes: sizes)
            let key = hits.map(\.path).joined(separator: "\0")
            if key == shownKey { return }
            shownKey = key
            shownPaths = DragSelection.combine(startPaths: startPaths, hitPaths: hits.map(\.path), mode: mode)
            host.selectionChanged(.marquee(entryPaths: paths, picked: shownPaths, lead: leadFor(shownPaths)))
        }

        func autoScroll() {
            let visible = collection.visibleRect
            let here = collection.convert(pointer, from: nil)
            let overshootX =
                here.x < visible.minX ? Double(here.x - visible.minX) : max(0, Double(here.x - visible.maxX))
            let overshootY =
                here.y < visible.minY ? Double(here.y - visible.minY) : max(0, Double(here.y - visible.maxY))
            let before = scrollPosition
            scrollPosition = (
                top: before.top + DragSelection.autoScrollStep(overshoot: overshootY),
                left: before.left + DragSelection.autoScrollStep(overshoot: overshootX)
            )
            if scrollPosition != before { update() }
        }

        defer { marquee.hide() }
        while true {
            let next = PointerTracker.next(
                in: window, matching: [.leftMouseUp, .leftMouseDragged, .scrollWheel],
                until: Date(timeIntervalSinceNow: 1.0 / 60.0))
            if let next {
                // The wheel moves the list under a pointer that stays: the box follows (B-VIEW-081).
                if next.type == .scrollWheel {
                    if scroll.wheelScrollsSideways {
                        scroll.scrollWheel(with: next)
                    } else {
                        let (top, left) = (scrollPosition.top, scrollPosition.left)
                        scrollPosition = (top: top + next.wheelOffset.top, left: left + next.wheelOffset.left)
                    }
                    if dragging { update() }
                    continue
                }
                pointer = next.locationInWindow
                if next.type == .leftMouseUp { break }
                if !dragging {
                    guard hypot(pointer.x - startWindow.x, pointer.y - startWindow.y) >= DragSelection.threshold
                    else { continue }
                    dragging = true
                }
                update()
            } else if dragging {
                autoScroll()
            }
        }
        // The selection's lead, which the arrow keys move from: the touched item nearest the pointer, or the last item
        // selected when the box touches none.
        if !dragging || shownPaths.isEmpty || leadFor(shownPaths) != nil { return }
        let lead = DragSelection.nearestLead(hits: hits, pointer: end, shownPaths: shownPaths)
        host.selectionChanged(.marquee(entryPaths: paths, picked: shownPaths, lead: lead))
    }

    // MARK: Keys

    func handleKeyDown(_ event: NSEvent) -> Bool {
        keyboard?.keyDown(event) ?? false
    }

    // MARK: Rename

    func positionRenameField() {
        guard let field = renameField, let path = renamingPath, let index = indexByPath[path] else { return }
        let frame = renameFrame(at: index)
        if field.frame != frame { field.frame = frame }
        field.repositionError()
    }

    /// Shows the field of the rename the pane is told of, or takes it away when the rename is over or its item left the
    /// list. It lives in the collection, not in an item, so scrolling the item away neither loses what was typed nor
    /// the keyboard (B-VIEW-090, B-VIEW-091).
    func syncRename() {
        guard let host else { return }
        guard let state = host.inlineRename, let index = indexByPath[state.path] else {
            endRenameField()
            keepInView(.ask)
            return
        }
        let entry = entries[index]
        if renamingPath != state.path || renameField == nil {
            endRenameField()
            let field = InlineRenameField(
                name: entry.name, fileExtension: entry.fileExtension, isFolder: entry.isDirectoryLike,
                draftKey: state.sessionID, font: renameFont(), theme: host.theme)
            field.alignment = renameAlignment
            field.onSubmit = { [weak self] name in self?.host?.renameSubmitted(name) }
            field.onCancel = { [weak self] in self?.host?.renameCancelled() }
            renameField = field
            renamingPath = state.path
            // The item takes its renaming look (and the Compact List item its column's width) before the field goes
            // over it.
            collection.collectionViewLayout?.invalidateLayout()
            placeItems()
            refreshItem(at: index)
            collection.addSubview(field, positioned: .above, relativeTo: nil)
            field.frame = renameFrame(at: index)
            keepInView(.ask)
            field.beginEditing()
        } else {
            positionRenameField()
        }
        if let field = renameField, field.error != state.error || state.refusalCount != lastRefusalCount {
            // A refused name brings the item back into view (B-VIEW-092).
            keepInView(.ask)
            lastRefusalCount = state.refusalCount
            field.showRefusal(state.error, count: state.refusalCount)
        }
    }

    func endRenameField() {
        guard let field = renameField else { return }
        let hadKeyboard = field.currentEditor() != nil
        let path = renamingPath
        field.close()
        field.removeFromWindow()
        renameField = nil
        renamingPath = nil
        lastRefusalCount = 0
        collection.collectionViewLayout?.invalidateLayout()
        if let path, let index = indexByPath[path] { refreshItem(at: index) }
        // The keyboard goes back to the view, not to nobody.
        if hadKeyboard { collection.window?.makeFirstResponder(collection) }
    }

    func refreshItem(at index: Int) {
        guard entries.indices.contains(index), let item = visibleItem(at: index) else { return }
        refreshLook(of: item, entry: entries[index])
    }

    var isRenaming: Bool { renamingPath != nil }
}

// MARK: Keyboard layout

extension ItemGridPane {
    /// Scrolls along one axis by `delta` points, stopping at either end; whether it scrolled.
    func scrollAlong(vertical: Bool, by delta: Double) -> Bool {
        placeItems()
        let clip = scroll.contentView
        let document = collection.frame.size
        let viewport = vertical ? clip.bounds.height : clip.bounds.width
        let size = vertical ? document.height : document.width
        let offset = vertical ? clip.bounds.origin.y : clip.bounds.origin.x
        guard
            let next = PagedScroll.nextOffset(
                viewportSize: Double(viewport), scrollSize: Double(size), currentOffset: Double(offset), delta: delta)
        else { return false }
        clip.scroll(
            to: vertical
                ? NSPoint(x: clip.bounds.origin.x, y: next) : NSPoint(x: next, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
        return true
    }
}

#if DEBUG
    extension ItemGridView: AutomationDragSource, AutomationDropTarget {
        func automationDragItems(at point: NSPoint) -> [URL] {
            guard let pane else { return [] }
            let entries: [DirectoryEntry]
            if let hit = pane.entry(at: point), !pane.selectedEntries.contains(where: { $0.path == hit.path }) {
                entries = [hit]
            } else {
                entries = pane.selectedEntries
            }
            return pane.host?.dragHooks.itemsToDrag?(entries) ?? entries.map(\.url)
        }

        func automationDrop(_ items: [URL], at point: NSPoint, allowed: NSDragOperation) -> Bool {
            guard let pane, let accept = pane.host?.dragHooks.acceptDrop else { return false }
            return accept(items, pane.entry(at: point), allowed)
        }
    }
#endif
