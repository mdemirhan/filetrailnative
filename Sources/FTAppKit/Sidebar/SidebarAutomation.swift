#if DEBUG
    import AppKit
    import FTFoundation

    extension SidebarViewController {
        /// Whether the selected row is in the tree yet: the tree reads its folders after the window opens.
        var selectedRowIsListed: Bool {
            guard let selected = model.selected else { return false }
            return tree.index(ofItem: selected) != nil
        }

        /// The density comes after the tree has been filled in, so the folder is revealed again with the row heights of
        /// that density.
        func revealSelectionFromTheTop() {
            guard let selected = model.selected, let index = tree.index(ofItem: selected) else { return }
            tree.scrollTop = 0
            tree.reveal(index)
        }
    }

    /// The `prefs` keys of the sidebar: where Favorites are, single-click expand, the favorites and
    /// whether their sections are open. Registered from here.
    @MainActor
    enum AutomationSidebarPrefs {
        private static var registered = false

        static func registerOnce() {
            guard !registered else { return }
            registered = true
            func flag(_ key: PreferenceKey) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool = value else { return .failed("\(key.rawValue) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    AutomationPrefs.set(key, value, on: controller)
                    return .applied
                }
            }
            flag(.singleClickExpandTreeItems)
            flag(.favoritesInitialized)
            AutomationPrefs.register(.favoritesPlacement) { value, context in
                guard let placement = value.string.flatMap(FavoritesPlacement.init(rawValue:)) else {
                    return .failed("favoritesPlacement \(value.string ?? "?")")
                }
                guard let controller = context.controller else { return .unsupported("favoritesPlacement") }
                controller.updatePreferences { $0.favoritesPlacement = placement }
                return .applied
            }
            AutomationPrefs.register(.favorites) { value, context in
                guard case .array(let entries) = value else { return .failed("favorites is not a list") }
                guard let controller = context.controller else { return .unsupported("favorites") }
                let listed = Scenario.PrefValue.array(
                    entries.compactMap { entry in
                        guard case .object(let fields) = entry, let path = fields["path"]?.string else { return nil }
                        return .object(["path": .string(path), "icon": .string(fields["icon"]?.string ?? "folder")])
                    })
                let read = AutomationPrefs.read(.favorites, listed)
                controller.updatePreferences {
                    $0.take(.favorites, from: read)
                    $0.favoritesInitialized = true
                }
                return .applied
            }
            func section(_ key: PreferenceKey, favorites: Bool) {
                AutomationPrefs.register(key) { value, context in
                    guard case .bool(let on) = value else { return .failed("\(key.rawValue) is not true or false") }
                    guard let controller = context.controller else { return .unsupported(key.rawValue) }
                    controller.sidebarController.setSection(favorites: favorites, open: on)
                    return .applied
                }
            }
            section(.favoritesExpanded, favorites: true)
            section(.locationsExpanded, favorites: false)
        }
    }

    extension SidebarOutlineView: AutomationPasteboardDragSource {
        /// A favorite's row carries what its real drag writes.
        func automationPasteboardDrag(at point: NSPoint) -> AutomationPasteboardDrag? {
            guard let list, list.reordersFavorites else { return nil }
            let index = row(at: point)
            guard index >= 0, case .item(let state)? = list.row(at: index), state.item.kind == .favorite,
                let path = state.item.path
            else { return nil }
            list.delegate?.sidebarList(list, favoriteDragStarted: path)
            return AutomationPasteboardDrag(item: SidebarPasteboard.item(favorite: path)) { [weak list] in
                guard let list else { return }
                list.delegate?.sidebarListFavoriteDragEnded(list)
            }
        }

    }
#endif
