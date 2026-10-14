// Port of the sidebar keys of apps/desktop/src/shared/appPreferences.ts, as capture scenarios set them (`prefs` steps), and the drag seams
#if DEBUG
    import AppKit
    import FTFoundation

    /// The `prefs` keys of the sidebar: where Favorites are, the compact tree, single-click expand, the favorites and
    /// whether their sections are open. Registered from here, as P5-01 does for the window's layout.
    @MainActor
    enum AutomationSidebarPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            func flag(_ key: String) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key) }
                    controller.updatePreferences([key: .bool(on)])
                    return .applied
                }
            }
            flag("compactTreeView")
            flag("singleClickExpandTreeItems")
            flag("favoritesInitialized")
            AutomationPrefs.register("favoritesPlacement") { value, context in
                guard let name = value.string, FavoritesPlacement(rawValue: name) != nil else {
                    return .failed("favoritesPlacement \(value.string ?? "?")")
                }
                guard let controller = context.controller else { return .unsupported("favoritesPlacement") }
                controller.updatePreferences(["favoritesPlacement": .string(name)])
                return .applied
            }
            // The four compact switches together, as the capture driver sets them.
            AutomationPrefs.register("density") { value, context in
                guard let name = value.string, let density = Density(rawValue: name) else {
                    return .failed("density \(value.string ?? "?")")
                }
                guard let controller = context.controller else { return .unsupported("density") }
                let compact = JSONNode.bool(density == .compact)
                controller.updatePreferences([
                    "compactListView": compact, "compactDetailsView": compact, "compactIconView": compact,
                    "compactTreeView": compact,
                ])
                return .applied
            }
            AutomationPrefs.register("favorites") { value, context in
                guard case .array(let entries) = value else { return .failed("favorites is not a list") }
                guard let controller = context.controller else { return .unsupported("favorites") }
                let nodes = entries.compactMap { entry -> JSONNode? in
                    guard case .object(let fields) = entry, let path = fields["path"]?.string else { return nil }
                    return .object(["path": .string(path), "icon": .string(fields["icon"]?.string ?? "folder")])
                }
                controller.updatePreferences(["favorites": .array(nodes), "favoritesInitialized": .bool(true)])
                return .applied
            }
            func section(_ key: String, favorites: Bool) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key) }
                    controller.sidebarController.setSection(favorites: favorites, open: on)
                    return .applied
                }
            }
            section("favoritesExpanded", favorites: true)
            section("locationsExpanded", favorites: false)
        }
    }

    extension SidebarOutlineView: AutomationDragSource, AutomationDropTarget {
        /// A favorite's row carries the favorite's folder; the other rows are not dragged.
        func automationDragItems(at point: NSPoint) -> [URL] {
            guard let list, list.reordersFavorites else { return [] }
            let index = row(at: point)
            guard index >= 0, case .item(let state)? = list.row(at: index), state.item.kind == .favorite,
                let path = state.item.path
            else { return [] }
            list.automationDraggedFavorite = path
            list.delegate?.sidebarList(list, favoriteDragStarted: path)
            return [URL(fileURLWithPath: path)]
        }

        /// A favorite dropped on another reorders; files dropped on a row go to the drop hook (P5-08).
        func automationDrop(_ items: [URL], at point: NSPoint, allowed: NSDragOperation) -> Bool {
            guard let list else { return false }
            if let dragged = list.automationDraggedFavorite {
                list.automationDraggedFavorite = nil
                let target = list.favoriteDropTarget(at: point)
                list.delegate?.sidebarList(list, favoriteDragOver: target.flatMap { $0.path == dragged ? nil : $0 })
                list.delegate?.sidebarList(list, favoriteDropped: dragged)
                list.delegate?.sidebarListFavoriteDragEnded(list)
                return target != nil
            }
            let index = row(at: point)
            guard index >= 0, case .item(let state)? = list.row(at: index) else { return false }
            return list.fileDropURLs?(list, state, items, allowed) ?? false
        }
    }
#endif
