// Port of the props TreeItemRow (apps/desktop/src/renderer/components/TreePane.tsx) draws a row from
import AppKit
import FTFoundation

/// A section header of the separate layout: the button that opens and closes Favorites or Locations.
struct SidebarHeaderState: Equatable {
    enum Section { case favorites, locations }
    var section: Section
    var title: String
    var expanded: Bool
    /// The first header sits just below the toolbar's bottom edge (`margin-top: 2px`).
    var first: Bool
    var density: Density
}

/// How a row would take what is dragged over it.
enum SidebarDropState: Equatable {
    case valid, invalid
}

/// Everything a row is drawn from: it is drawn again only when this changes (`memo`).
struct SidebarRowState: Equatable {
    enum Selection: Equatable {
        case none
        /// The accent selection: the sidebar has the keyboard in the active window.
        case focused
        /// The gray one: the sidebar has not, or the window is in the background.
        case inactive
    }

    var item: TreePresentationItem
    var subview: SidebarSubview
    var selection: Selection
    /// A context menu is open for this row.
    var menuTarget: Bool
    var drop: SidebarDropState?
    /// Its disk is being ejected.
    var ejecting: Bool
    /// A favorite being dragged to a new place.
    var dragging: Bool
    /// Where the dragged favorite would land, drawn as a line on this row's edge.
    var dropLine: Favorites.DropPosition?
    /// "Loading folder…" shows (the read has lasted 400 ms).
    var showsLoading: Bool
    var density: Density
    /// Favorites and Locations of the separate lists are flat rows without a disclosure button.
    var hasDisclosure: Bool

    var isFolder: Bool { item.kind == .filesystem }
}

/// One row of a list: padding, a section header, or a row.
enum SidebarListRow: Equatable {
    case spacer(id: String, height: Double)
    case header(SidebarHeaderState)
    case item(SidebarRowState)

    var id: String {
        switch self {
        case .spacer(let id, _): id
        case .header(let state): "header:\(state.section == .favorites ? "favorites" : "locations")"
        case .item(let state): "\(state.subview.rawValue):\(state.item.id.rawValue)"
        }
    }

    var itemID: TreeItemID? {
        if case .item(let state) = self { return state.item.id }
        return nil
    }
}

/// Colors the sidebar draws with, from the app's accent and the look of the view it is drawn in.
enum SidebarColors {
    @MainActor private static var cache: [String: Theme] = [:]

    /// The theme for a view: the palette of its appearance, the app's accent.
    @MainActor
    static func theme(for view: NSView?) -> Theme {
        let appearance = ChromeColors.appearance(of: view)
        let hex = AppearanceModel.shared.accentHex
        let key = "\(appearance)-\(hex)"
        if let known = cache[key] { return known }
        let made = Theme(appearance: appearance, accentHex: hex)
        cache[key] = made
        return made
    }
}
