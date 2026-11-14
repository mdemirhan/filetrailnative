// What a tab plugs into its panes' drag seams
import AppKit
import FTFileSystem
import FTFoundation

extension MainWindowController {
    /// Plugs the clipboard's marks and the drags into the panes.
    func installClipboardAndDrags() {
        let drags = dragDrop
        installDrags(on: activePane)
        sidebarController.fileDrops = SidebarFileDrops(
            over: { [weak drags] row, info in drags?.sidebarDragUpdated(info, row: row) ?? [] },
            drop: { [weak drags] row, info in drags?.sidebarPerformDrop(info, row: row) ?? false })
        sidebarController.installFileDrops()
        clipboardMarksChanged()
    }

    /// The drags out of a pane's list and over it.
    func installDrags(on pane: BrowserPane) {
        let drags = dragDrop
        let content = pane.content
        // A drag starts in the pane pressed, which is the active one; a drag over a list is over its pane.
        content.dragHooks.beginDrag = { [weak self, weak drags, weak pane] entries, event, view in
            if let pane { self?.activate(pane) }
            return drags?.beginDrag(entries, event: event, from: view) ?? false
        }
        content.dragHooks.dragUpdated = { [weak drags, weak pane] info, entry in
            drags?.paneUnderDrag = pane
            return drags?.contentDragUpdated(info, entry: entry) ?? []
        }
        content.dragHooks.performDrop = { [weak drags, weak pane] info, entry in
            drags?.paneUnderDrag = pane
            return drags?.contentPerformDrop(info, entry: entry) ?? false
        }
        content.dragHooks.dragExited = { [weak drags] in drags?.dragExited() }
    }
}

extension SidebarViewController {
    /// Files dragged over the rows of both lists go to `fileDrops`; headings and empty space take
    /// nothing.
    func installFileDrops() {
        for list in [sections, tree] {
            list.fileDropOperation = { [weak self] list, info, point in
                guard let drops = self?.fileDrops else { return [] }
                return drops.over(Self.rowState(list, at: point), info)
            }
            list.fileDrop = { [weak self] list, info, point in
                guard let drops = self?.fileDrops, let row = Self.rowState(list, at: point) else { return false }
                return drops.drop(row, info)
            }
        }
    }

    private static func rowState(_ list: SidebarListView, at point: NSPoint) -> SidebarRowState? {
        let index = list.outline.row(at: point)
        guard index >= 0, case .item(let state)? = list.row(at: index) else { return nil }
        return state
    }

    /// The clipboard changed: the rows mark it again, and the marked ones flash for a new Copy or Cut.
    func clipboardMarksChanged(_ marks: ClipboardMarks?, flash: Bool) {
        guard marks != clipboardMarks || flash else { return }
        clipboardMarks = marks
        refresh()
        guard flash else { return }
        for list in [sections, tree] {
            let outline = list.outline
            let rows = outline.rows(in: outline.visibleRect)
            guard rows.length > 0 else { continue }
            for row in rows.location..<(rows.location + rows.length) {
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarItemCell)?.flashClipboardMark()
            }
        }
    }
}

#if DEBUG
    extension TabDragDrop {
        /// A drag through the debug seams: the items it carries are the window's own drag until it is dropped.
        func automationDragStarted(_ entries: [DirectoryEntry]) -> [URL] {
            guard let tab, let window = tab.window, !entries.isEmpty else { return entries.map(\.url) }
            if let session = DragRules.session(
                sourceSurface: tab.searchRootPath != nil ? .search : .content, draggedPath: entries[0].path,
                selectedPathsInViewOrder: entries.map(\.path),
                kindOf: { path in
                    entries.first { samePath($0.path, path) }?.kind.rules
                })
            {
                Self.ownDrag = OwnDrag(
                    session: session, windowNumber: window.windowNumber, tab: tab, pane: tab.activePane)
            }
            return entries.map(\.url)
        }

        /// The drag the seam hands over: the window's own when it carries its items, else one from another app
        /// (another window of the app included).
        private func automationSession(_ urls: [URL]) -> DragSession? {
            let paths = urls.map(\.path)
            if let own = Self.ownDrag, own.windowNumber == tab?.window?.windowNumber,
                own.session.facts.sourcePaths.count == paths.count,
                zip(own.session.facts.sourcePaths, paths).allSatisfy({ samePath($0, $1) })
            {
                return own.session
            }
            let read = DragPasteboard.draggedIn(DragPasteboardContents(changeCount: 0, paths: paths))
            let items = read.items.map { DragItem(path: $0.path, kind: $0.kind.rules) }
            guard let lead = items.first else { return nil }
            return DragSession(sourceSurface: .external, sourceItems: items, leadPath: lead.path, leadKind: lead.kind)
        }

        /// The keys held, from what the drag offers (⌥ copies, ⌘ moves, ⌥⌘ links).
        private func automationModifiers(_ allowed: NSDragOperation) -> NSEvent.ModifierFlags {
            switch allowed {
            case .copy: [.option]
            case .move: [.command]
            case .link: [.option, .command]
            default: []
            }
        }

        private func finishAutomationDrag() {
            Self.ownDrag = nil
        }

        func automationDrop(_ urls: [URL], entry: DirectoryEntry?, allowed: NSDragOperation) -> Bool {
            let session = automationSession(urls)
            defer { finishAutomationDrag() }
            let folder = entry.flatMap { $0.kind == .directory || $0.kind == .symlinkDirectory ? $0 : nil }
            let target = session.flatMap { contentTarget($0, entry: folder) }
            return drop(
                session: session, target: target, offersMove: true, modifiers: automationModifiers(allowed),
                sequence: -1)
        }

    }
#endif
