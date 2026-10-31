// Port of the List's pointer and keys: entryItemEvents.ts, the DetailsView handlers of components/ContentPane.tsx
// (:1822-1833) and hooks/useDragSelection.ts
import AppKit
import FTFileSystem
import FTFoundation

extension ListViewController {
    // MARK: Who has the keyboard

    /// Every primary press on an item or on empty space gives the keyboard to the list, whatever the gesture
    /// (B-SEL-006, B-SEL-013). A rename going on ends: leaving its field commits it.
    func giveKeyboard() {
        guard let window = table.window else { return }
        if window.firstResponder !== table { window.makeFirstResponder(table) }
    }

    // MARK: Pointer

    func handleMouseDown(_ event: NSEvent) {
        guard host != nil else { return }
        giveKeyboard()
        let point = table.convert(event.locationInWindow, from: nil)
        // ⌃-click is a right click.
        if event.modifierFlags.contains(.control) {
            if let menu = table.menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: table) }
            return
        }
        let row = table.row(at: point)
        if entries.indices.contains(row) {
            pressItem(at: row, event: event)
        } else {
            pressEmptySpace(event: event, at: point)
        }
    }

    /// Pointer down on an item selects it when it is not selected or ⌘ or ⇧ is held, and the click that follows narrows
    /// a selection of several to it, so pressing a selected item can still start a drag of the whole selection.
    private func pressItem(at row: Int, event: NSEvent) {
        guard let host else { return }
        let entry = entries[row]
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
        while let window = table.window,
            let next = PointerTracker.next(in: window, matching: [.leftMouseUp, .leftMouseDragged])
        {
            if next.type == .leftMouseDragged {
                let here = next.locationInWindow
                if !dragged, hypot(here.x - start.x, here.y - start.y) >= DragSelection.threshold {
                    dragged = true
                    let carried = host.selection.paths.contains(entry.path) ? selectedEntries : [entry]
                    if host.dragHooks.beginDrag?(carried, next, table) == true { return }
                }
                continue
            }
            if dragged { return }
            let upPoint = table.convert(next.locationInWindow, from: nil)
            guard table.row(at: upPoint) == row else { return }
            clicked(entry: entry, clickCount: event.clickCount, modifiers: held)
            return
        }
    }

    /// The click that completes a press on an item (`click` and `doubleClick` of `entryItemEvents.ts`).
    private func clicked(entry: DirectoryEntry, clickCount: Int, modifiers held: ContentSelection.Modifiers) {
        guard let host else { return }
        // Only the second click: `dblclick` fires once, and a third click is just a click.
        if clickCount == 2 {
            // ⌘-double-click on a folder opens it in a new tab.
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

    // MARK: Empty space and the marquee

    /// A press on empty space clears the selection (unless ⇧ or ⌘ is held) and starts a marquee.
    private func pressEmptySpace(event: NSEvent, at point: NSPoint) {
        guard let host else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let meta = flags.contains(.command)
        let shift = flags.contains(.shift)
        if !meta, !shift { host.selectionChanged(.empty) }
        runMarquee(from: event, at: point, meta: meta, shift: shift)
    }

    /// Drag-to-select (`useDragSelection`): the box follows the pointer, the selection follows the box, and the list
    /// scrolls while the pointer is past one of its edges. Points are kept in the table's own coordinates, which stay
    /// put as it scrolls.
    private func runMarquee(from event: NSEvent, at start: NSPoint, meta: Bool, shift: Bool) {
        guard let host, let window = table.window else { return }
        let mode = DragSelection.mode(meta: meta, shift: shift)
        let startPaths = mode == .replace ? [] : host.selection.paths
        // A replaced selection has no lead until the drag ends, so the list does not scroll to reveal one meanwhile.
        let startLead = mode == .replace ? nil : host.selection.leadPath
        let paths = host.entryPaths
        let rowHeight = Double(table.rowHeight)
        let startWindow = event.locationInWindow
        var pointer = startWindow
        var dragging = false
        var shownKey = ""
        var shownPaths = startPaths
        var hits: [DragSelectionHit] = []
        var end = (x: 0.0, y: 0.0)

        func leadFor(_ picked: [String]) -> String? {
            startLead.flatMap { picked.contains($0) ? $0 : nil }
        }

        func update() {
            let visible = table.visibleRect
            let here = table.convert(pointer, from: nil)
            // The box ends at the pointer, kept within the part of the list on screen.
            let inArea = NSPoint(
                x: min(max(here.x, visible.minX), visible.maxX), y: min(max(here.y, visible.minY), visible.maxY))
            let box = DragSelection.box(
                from: (Double(start.x), Double(start.y)), to: (Double(inArea.x), Double(inArea.y)))
            marquee.show(NSRect(x: box.left, y: box.top, width: box.right - box.left, height: box.bottom - box.top))
            table.addSubview(marquee, positioned: .above, relativeTo: nil)
            end = (Double(inArea.x), Double(inArea.y))
            hits = DragSelection.detailsItems(box: box, entryPaths: paths, rowHeight: rowHeight)
            let key = hits.map(\.path).joined(separator: "\0")
            if key == shownKey { return }
            shownKey = key
            shownPaths = DragSelection.combine(startPaths: startPaths, hitPaths: hits.map(\.path), mode: mode)
            host.selectionChanged(.marquee(entryPaths: paths, picked: shownPaths, lead: leadFor(shownPaths)))
        }

        func autoScroll() {
            let visible = table.visibleRect
            let here = table.convert(pointer, from: nil)
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
                    let (top, left) = (scrollPosition.top, scrollPosition.left)
                    scrollPosition = (top: top + next.wheelOffset.top, left: left + next.wheelOffset.left)
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
}

extension ListViewController: LayoutNavigation {
    var navigationViewMode: ExplorerViewMode { .details }
    var itemsPerLine: Int { 1 }

    var pageGeometry: (viewportSize: Double, lineExtent: Double) {
        (Double(scroll.contentView.bounds.height), layoutMetrics.rowHeight)
    }

    func isWhollyInView(index: Int) -> Bool {
        guard index >= 0, index < table.numberOfRows else { return false }
        let row = table.rect(ofRow: index)
        let visible = scroll.contentView.bounds
        return row.minY >= visible.minY && row.maxY <= visible.maxY
    }

    @discardableResult
    func scroll(by delta: Double) -> Bool {
        let clip = scroll.contentView
        let document = scroll.documentView?.frame.size ?? .zero
        guard
            let next = PagedScroll.nextOffset(
                viewportSize: Double(clip.bounds.height), scrollSize: Double(document.height),
                currentOffset: Double(clip.bounds.origin.y), delta: delta)
        else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
        scroll.reflectScrolledClipView(clip)
        return true
    }
}

// MARK: Rename

extension ListViewController {
    /// The frame of the rename field over a row's name (`.inline-rename-input`: 20 tall, 5 to the left of the label it
    /// replaces, 3 short of the cell's right edge).
    private func renameFrame(row: Int) -> NSRect {
        let metrics = layoutMetrics
        let rowRect = table.rect(ofRow: row)
        let layout = SelectionLayout.Rename.self
        let cellX = metrics.rowInset + metrics.rowPaddingInline
        let labelX = cellX + metrics.iconSize + metrics.nameIconGap
        let x = labelX + layout.marginLeft
        let right = cellX + fitted.width(.name) - layout.marginRight
        return NSRect(
            x: x, y: rowRect.minY + (rowRect.height - layout.height) / 2, width: max(0, right - x),
            height: layout.height)
    }

    func positionRenameField() {
        guard let field = renameField, let path = renamingPath, let row = rowByPath[path] else { return }
        let frame = renameFrame(row: row)
        if field.frame != frame { field.frame = frame }
        field.repositionError()
    }

    /// Shows the field of the rename the pane is told of, or takes it away when the rename is over or its item left the
    /// list. It lives in the table, not in a row, so scrolling the row away neither loses what was typed nor the
    /// keyboard.
    func syncRename() {
        guard let host else { return }
        guard let state = host.inlineRename, let row = rowByPath[state.path] else {
            endRenameField()
            keepInView(.ask)
            return
        }
        let entry = entries[row]
        if renamingPath != state.path || renameField == nil {
            endRenameField()
            let font = ListFonts.row(layoutMetrics)
            let field = InlineRenameField(
                name: entry.name, fileExtension: entry.fileExtension, isFolder: entry.isDirectoryLike,
                draftKey: state.sessionID, font: font, theme: host.theme)
            field.onSubmit = { [weak self] name in self?.host?.renameSubmitted(name) }
            field.onCancel = { [weak self] in self?.host?.renameCancelled() }
            field.ringClippedToHeight = true
            renameField = field
            renamingPath = state.path
            table.addSubview(field)
            field.frame = renameFrame(row: row)
            setRenaming(true, row: row)
            keepInView(.ask)
            field.beginEditing()
        } else {
            positionRenameField()
        }
        if let field = renameField, field.error != state.error || state.refusalCount != lastRefusalCount {
            // A refused name brings the item back into view.
            keepInView(.ask)
            lastRefusalCount = state.refusalCount
            field.showRefusal(state.error, count: state.refusalCount)
        }
    }

    func endRenameField() {
        guard let field = renameField else { return }
        let hadKeyboard = field.currentEditor() != nil
        if let path = renamingPath, let row = rowByPath[path] { setRenaming(false, row: row) }
        field.close()
        field.removeFromWindow()
        renameField = nil
        renamingPath = nil
        lastRefusalCount = 0
        // The keyboard goes back to the list, not to nobody.
        if hadKeyboard { table.window?.makeFirstResponder(table) }
    }

    private func setRenaming(_ renaming: Bool, row: Int) {
        bar(atRow: row)?.refreshCells()
    }
}
