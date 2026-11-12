import AppKit
import FTFoundation

extension SidebarViewController {
    // MARK: Pointer

    func sidebarList(_ list: SidebarListView, pointerDown state: SidebarRowState, event: NSEvent) {
        model.setSubview(state.subview)
        // A heading is never selected.
        if state.item.id.isHeading { return }
        let meta = event.modifierFlags.contains(.command)
        let isCurrent = state.selection != .none
        if meta, isCurrent {
            model.markPressed(nil)
            return
        }
        // ⌘-click on a folder that is not on screen opens it in a new tab and selects nothing.
        if meta, state.item.path != nil { return }
        model.markPressed(state.item.id)
    }

    func sidebarListPressCancelled(_ list: SidebarListView) {
        model.markPressed(nil)
    }

    func sidebarList(_ list: SidebarListView, click state: SidebarRowState, event: NSEvent, clickCount: Int) {
        model.setSubview(state.subview)
        let item = state.item
        if item.id.isHeading {
            // A click on the Favorites or Locations heading opens or closes it; the folder on screen stays. The second
            // click of a double-click does not undo the first.
            if clickCount <= 1 { toggleHeading(item.id) }
            return
        }
        let meta = event.modifierFlags.contains(.command)
        let isCurrent = state.selection != .none
        if meta, isCurrent {
            model.clearSelection()
            return
        }
        if meta, let path = item.path {
            openInNewTab(path)
            return
        }
        // A click opens the folder at once; the second click of a double-click only opens or closes its branch.
        guard clickCount <= 1 else { return }
        activate(state, expandFirst: model.singleClickExpand)
    }

    func sidebarList(_ list: SidebarListView, doubleClick state: SidebarRowState) {
        model.setSubview(state.subview)
        let item = state.item
        // Its clicks have already opened or closed a heading. With single-click expand on, the first click has already
        // opened or closed the branch.
        guard !item.id.isHeading, !model.singleClickExpand, item.kind == .filesystem, item.canExpand,
            let path = item.path
        else { return }
        model.toggleByHand(path)
    }

    /// Opens the row's folder; a folder of the tree toggles first when asked to.
    private func activate(_ state: SidebarRowState, expandFirst: Bool) {
        let item = state.item
        guard let path = item.path else { return }
        if expandFirst, item.kind == .filesystem, item.canExpand { model.toggleByHand(path) }
        model.selectItem(item.id)
    }

    private func toggleHeading(_ id: TreeItemID) {
        if id == .favoritesRoot { model.toggleFavorites() } else { model.toggleLocations() }
    }

    func sidebarList(_ list: SidebarListView, pressEmptySpaceIn subview: SidebarSubview) {
        model.setSubview(subview)
        model.clearSelection()
    }

    func sidebarList(_ list: SidebarListView, toggle state: SidebarRowState) {
        model.setSubview(state.subview)
        let item = state.item
        if item.id.isHeading {
            toggleHeading(item.id)
        } else if item.kind == .filesystem, let path = item.path {
            model.toggleByHand(path)
        }
    }

    func sidebarList(_ list: SidebarListView, pressHeader state: SidebarHeaderState) {
        // A mouse press anywhere in a section counts as a press on empty space (the section's capture handler): the
        // selection is cleared and the file list emptied, and the click then toggles the section.
        model.setSubview(.favorites)
        model.clearSelection()
    }

    func sidebarList(_ list: SidebarListView, toggleHeader state: SidebarHeaderState) {
        if state.section == .favorites { model.toggleFavorites() } else { model.toggleLocations() }
    }

    func sidebarList(_ list: SidebarListView, eject state: SidebarRowState) {
        guard let path = state.item.path, !state.ejecting else { return }
        eject(path)
    }

    func sidebarList(_ list: SidebarListView, focusChanged focused: Bool) {
        if focused {
            setFocused(true)
        } else {
            // Focus moving to the other list of the sidebar is not focus lost.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.recheckFocus() }
            }
        }
    }

    func recheckFocus() {
        let responder = view.window?.firstResponder as? NSView
        setFocused(responder?.isDescendant(of: view) == true)
    }

    private func setFocused(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        if !focused { model.clearTypeahead() }
        refresh()
        selectionChanged()
    }

    // MARK: Context menus

    func sidebarList(_ list: SidebarListView, menuFor state: SidebarRowState, event: NSEvent) -> NSMenu? {
        // Headings have no context menu.
        if state.item.id.isHeading { return nil }
        let kind: SidebarMenuTarget.Kind =
            state.item.kind == .favorite || state.item.kind == .location ? .favorite : .treeFolder
        guard let provider = contextMenuProvider,
            let menu = provider(SidebarContextMenuRequest(item: state.item, subview: state.subview, kind: kind))
        else { return nil }
        model.setSubview(state.subview)
        if let path = state.item.path {
            // The menu acts on this row, but the selection stays on the folder being shown: the row is ringed while the
            // menu is open.
            model.menuTarget = SidebarMenuTarget(path: path, subview: state.subview, kind: kind)
            observeEnd(of: menu)
        }
        return menu
    }

    private func observeEnd(of menu: NSMenu) {
        let box = ObserverBox()
        box.token = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main
        ) { [weak self, box] _ in
            MainActor.assumeIsolated { self?.model.menuTarget = nil }
            if let token = box.token { NotificationCenter.default.removeObserver(token) }
        }
    }

    // MARK: Keys

    func sidebarList(_ list: SidebarListView, keyDown event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let plain = flags.subtracting(.shift).isEmpty
        let key = TreeKey.from(event)
        switch key {
        case .arrow(let direction):
            guard plain else { break }
            model.clearTypeahead()
            if model.handle(direction) { return true }
            return true
        case .tab:
            guard flags.subtracting(.shift).isEmpty else { break }
            focusContent()
            return true
        case .returnKey:
            guard flags.isEmpty else { break }
            model.clearTypeahead()
            return model.openSelected() || true
        case .space:
            guard flags.isEmpty else { break }
            if let state = currentRowState() { sidebarList(list, click: state, event: event, clickCount: 1) }
            return true
        case .escape, .other:
            break
        }
        if let moved = pageMove(for: event) { return moved }
        // A key that has a command (?, or one chosen in Settings) goes on to the window's table; Quick Look's is matched
        // only with the list focused (`quickLook`).
        if let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)),
            let command = ShortcutCommands.resolve(preferences().shortcutOverrides).commandByShortcut[pressed],
            command != .quickLookSelection
        {
            return false
        }
        // Typing selects the first row whose name starts with it.
        if flags.intersection([.command, .control, .option]).isEmpty, !event.modifierFlags.contains(.function),
            let characters = event.characters, Typeahead.isCharacterKey(characters)
        {
            model.type(characters)
            return true
        }
        return false
    }

    /// The row the keyboard is on, as a state to click.
    private func currentRowState() -> SidebarRowState? {
        guard let id = model.selected else { return nil }
        for list in [tree, sections] {
            if let index = list.index(ofItem: id), case .item(let state)? = list.row(at: index) { return state }
        }
        return nil
    }

    /// Page Up/Down and Ctrl+U/Ctrl+D (or what Settings gives them): a page or half a page of rows. With ⇧ too, when ⇧
    /// and the key are not a command's keys of their own: the tree has one selection, so it
    /// moves as without ⇧.
    private func pageMove(for event: NSEvent) -> Bool? {
        guard let shortcut = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)) else { return nil }
        let resolved = ShortcutCommands.resolve(preferences().shortcutOverrides)
        guard
            let command = resolved.commandByShortcut[shortcut]
                ?? Shortcuts.withoutShift(shortcut).flatMap({ resolved.commandByShortcut[$0] })
        else { return nil }
        let forward: Bool
        let size: SidebarKeyboard.PageSize
        switch command {
        case .pageUp: (forward, size) = (false, .full)
        case .pageDown: (forward, size) = (true, .full)
        case .halfPageUp: (forward, size) = (false, .half)
        case .halfPageDown: (forward, size) = (true, .half)
        default: return nil
        }
        return movePage(forward: forward, size: size)
    }

    /// The selection moves a page; the sidebar scrolls only if the target would be outside, by the
    /// distance between the old and new row tops.
    func movePage(forward: Bool, size: SidebarKeyboard.PageSize) -> Bool {
        model.clearTypeahead()
        let list = outlineList(for: model.subview)
        let lines = SidebarKeyboard.pageStepLines(
            viewportHeight: Double(list.scroll.contentView.bounds.height), rowHeight: layout.rowHeight, size: size)
        guard let target = SidebarKeyboard.pageTarget(forward: forward, lines: lines, model.keyContext) else {
            return false
        }
        if let from = model.selected.flatMap({ list.index(ofItem: $0) }), let to = list.index(ofItem: target) {
            let fromRect = list.frame(ofRow: from)
            let toRect = list.frame(ofRow: to)
            let visible = list.scroll.contentView.bounds
            if toRect.minY < visible.minY || toRect.maxY > visible.maxY {
                list.scrollTop += Double(toRect.minY - fromRect.minY)
            }
        }
        model.selectItem(target)
        return true
    }

    func outlineList(for subview: SidebarSubview) -> SidebarListView {
        if model.placement == .separate, subview == .favorites, !sections.isHidden { return sections }
        return tree
    }

    // MARK: Putting the favorites in order

    func sidebarList(_ list: SidebarListView, favoriteDragStarted path: String) {
        draggedFavorite = path
        dropTarget = nil
        // The press that began the drag opens nothing.
        model.markPressed(nil)
        refresh()
    }

    func sidebarList(
        _ list: SidebarListView, favoriteDragOver target: (path: String, position: Favorites.DropPosition)?
    ) {
        let changed = dropTarget?.path != target?.path || dropTarget?.position != target?.position
        guard changed else { return }
        dropTarget = target
        refresh()
    }

    func sidebarList(_ list: SidebarListView, favoriteDropped path: String) {
        defer {
            draggedFavorite = nil
            dropTarget = nil
            refresh()
        }
        guard let target = dropTarget else { return }
        model.reorder(moved: path, target: target.path, position: target.position)
    }

    func sidebarListFavoriteDragEnded(_ list: SidebarListView) {
        guard draggedFavorite != nil || dropTarget != nil else { return }
        draggedFavorite = nil
        dropTarget = nil
        refresh()
    }
}

private final class ObserverBox: @unchecked Sendable {
    var token: (any NSObjectProtocol)?
}

/// A key press as the sidebar reads it.
enum TreeKey {
    case arrow(SidebarKeyboard.Key)
    case tab, returnKey, space, escape, other

    static func from(_ event: NSEvent) -> TreeKey {
        switch event.keyCode {
        case 126: .arrow(.up)
        case 125: .arrow(.down)
        case 123: .arrow(.left)
        case 124: .arrow(.right)
        case 115: .arrow(.home)
        case 119: .arrow(.end)
        case 48: .tab
        case 36, 76: .returnKey
        case 49: .space
        case 53: .escape
        default: .other
        }
    }
}
