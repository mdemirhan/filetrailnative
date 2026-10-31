// Port of the hookups of apps/desktop/src/renderer/hooks/useExplorerDragAndDrop.ts into the panes (the content rows and
// background, the tree's folders, favorites and locations), and of the capture driver's drops: what a tab plugs into
// its panes' drag seams
import AppKit
import FTFileSystem
import FTFoundation

extension MainWindowController {
    /// Plugs the clipboard's marks and the drags into the panes (P5-08).
    func installClipboardAndDrags() {
        let drags = dragDrop
        content.dragHooks.beginDrag = { [weak drags] entries, event, view in
            drags?.beginDrag(entries, event: event, from: view) ?? false
        }
        content.dragHooks.dragUpdated = { [weak drags] info, entry in
            drags?.contentDragUpdated(info, entry: entry) ?? []
        }
        content.dragHooks.performDrop = { [weak drags] info, entry in
            drags?.contentPerformDrop(info, entry: entry) ?? false
        }
        content.dragHooks.dragExited = { [weak drags] in drags?.dragExited() }
        #if DEBUG
            content.dragHooks.itemsToDrag = { [weak drags] entries in drags?.automationDragStarted(entries) ?? [] }
            content.dragHooks.acceptDrop = { [weak drags] urls, entry, allowed in
                drags?.automationDrop(urls, entry: entry, allowed: allowed) ?? false
            }
        #endif
        sidebarController.fileDrops = SidebarFileDrops(
            over: { [weak drags] row, info in drags?.sidebarDragUpdated(info, row: row) ?? [] },
            drop: { [weak drags] row, info in drags?.sidebarPerformDrop(info, row: row) ?? false },
            dropURLs: { [weak drags] row, urls, allowed in
                #if DEBUG
                    return drags?.automationDrop(urls, row: row, allowed: allowed) ?? false
                #else
                    return false
                #endif
            })
        sidebarController.installFileDrops()
        clipboardMarksChanged()
    }
}

extension SidebarViewController {
    /// Files dragged over the rows of both lists go to `fileDrops` (B-TREE-157); headings and empty space take
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
            list.fileDropURLs = { [weak self] _, row, urls, allowed in
                self?.fileDrops?.dropURLs(row, urls, allowed) ?? false
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
        /// The capture's `drag` step: the items it carries are the window's own drag until it is dropped.
        func automationDragStarted(_ entries: [DirectoryEntry]) -> [URL] {
            guard let tab, let window = tab.window, !entries.isEmpty else { return entries.map(\.url) }
            if let session = DragRules.session(
                sourceSurface: tab.searchRootPath != nil ? .search : .content, draggedPath: entries[0].path,
                selectedPathsInViewOrder: entries.map(\.path),
                kindOf: { path in
                    entries.first { samePath($0.path, path) }?.kind.rules
                })
            {
                Self.ownDrag = OwnDrag(session: session, windowNumber: window.windowNumber, tab: tab)
            }
            return entries.map(\.url)
        }

        /// The drag the step hands over: the window's own when it carries its items, else one from another app
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

        /// The keys the step held, from what the drag offers (⌥ copies, ⌘ moves, ⌥⌘ links).
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

        func automationDrop(_ urls: [URL], row: SidebarRowState, allowed: NSDragOperation) -> Bool {
            let session = automationSession(urls)
            defer { finishAutomationDrag() }
            return drop(
                session: session, target: sidebarTarget(row), offersMove: true,
                modifiers: automationModifiers(allowed), sequence: -1)
        }
    }
#endif
