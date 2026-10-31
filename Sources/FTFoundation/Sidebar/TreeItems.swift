// Port of the item ids, locations and rows of apps/desktop/src/renderer/lib/favorites.ts and TreeNodeState of components/TreePane.tsx
import Foundation

/// A row of the sidebar, by what it is: a heading, a favorite, a place under Locations or a folder of the tree. The
/// raw form (`favorite:<path>`, `fs:<path>`) is what a tab keeps as its selection.
public enum TreeItemID: Hashable, Sendable {
    case favoritesRoot
    case locationsRoot
    case favorite(String)
    case location(String)
    case filesystem(String)

    static let favoritePrefix = "favorite:"
    static let locationPrefix = "location:"
    static let filesystemPrefix = "fs:"

    public init?(rawValue: String) {
        if rawValue == "favorites-root" {
            self = .favoritesRoot
        } else if rawValue == "locations-root" {
            self = .locationsRoot
        } else if rawValue.hasPrefix(Self.favoritePrefix) {
            self = .favorite(String(rawValue.dropFirst(Self.favoritePrefix.count)))
        } else if rawValue.hasPrefix(Self.locationPrefix) {
            self = .location(String(rawValue.dropFirst(Self.locationPrefix.count)))
        } else if rawValue.hasPrefix(Self.filesystemPrefix) {
            self = .filesystem(String(rawValue.dropFirst(Self.filesystemPrefix.count)))
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .favoritesRoot: "favorites-root"
        case .locationsRoot: "locations-root"
        case .favorite(let path): Self.favoritePrefix + path
        case .location(let path): Self.locationPrefix + path
        case .filesystem(let path): Self.filesystemPrefix + path
        }
    }

    /// Favorites root and Locations root: section heads, not places.
    public var isHeading: Bool {
        self == .favoritesRoot || self == .locationsRoot
    }

    public var favoritePath: String? {
        if case .favorite(let path) = self { return path }
        return nil
    }

    public var locationPath: String? {
        if case .location(let path) = self { return path }
        return nil
    }

    public var filesystemPath: String? {
        if case .filesystem(let path) = self { return path }
        return nil
    }

    /// A favorite or a location: a sidebar row that goes to its folder (`getShortcutItemPath`).
    public var shortcutPath: String? {
        favoritePath ?? locationPath
    }

    /// The folder a row stands for, whatever the row (nil for a heading).
    public var path: String? {
        shortcutPath ?? filesystemPath
    }

    public static func == (left: TreeItemID, right: TreeItemID) -> Bool {
        left.rawValue.utf8.elementsEqual(right.rawValue.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in rawValue.utf8 { hasher.combine(byte) }
    }
}

/// What a sidebar row is (`TreePresentationItem["kind"]`).
public enum TreeItemKind: String, Sendable, Hashable {
    case favoritesRoot = "favorites-root"
    case favorite
    case locationsRoot = "locations-root"
    case location
    case filesystem
}

/// A place in the sidebar's Locations, as in Finder's: the home folder (under the account's name), Macintosh HD, the
/// other disks mounted, and the Trash. Like a favorite it is a place to go to, not a folder to expand. A disk Finder
/// would eject has an Eject button after its name.
public struct SidebarLocation: Equatable, Sendable {
    public var path: String
    public var label: String
    public var icon: FavoriteIconID
    public var canEject: Bool

    public init(path: String, label: String, icon: FavoriteIconID, canEject: Bool = false) {
        self.path = path
        self.label = label
        self.icon = icon
        self.canEject = canEject
    }
}

/// What the sidebar needs of a mounted disk (`buildSidebarLocations`' parameter).
public struct SidebarVolume: Equatable, Sendable {
    public var path: String
    public var name: String
    public var isLocal: Bool
    public var canEject: Bool

    public init(path: String, name: String, isLocal: Bool, canEject: Bool) {
        self.path = path
        self.name = name
        self.isLocal = isLocal
        self.canEject = canEject
    }
}

/// A folder of the tab's tree (`TreeNodeState`). A link to a folder is listed but never expands.
public struct TreeNodeState: Equatable, Sendable {
    public var path: String
    public var name: String
    public var isHidden: Bool
    public var isSymlink: Bool
    public var expanded: Bool
    public var loading: Bool
    public var loaded: Bool
    public var loadedIncludeHidden: Bool
    public var forcedVisibleHiddenChildPath: String?
    public var forcedVisiblePackageChildPath: String?
    public var error: String?
    public var childPaths: [String]

    public init(
        path: String, name: String, isHidden: Bool = false, isSymlink: Bool = false, expanded: Bool = false,
        loading: Bool = false, loaded: Bool = false, loadedIncludeHidden: Bool = false,
        forcedVisibleHiddenChildPath: String? = nil, forcedVisiblePackageChildPath: String? = nil,
        error: String? = nil, childPaths: [String] = []
    ) {
        self.path = path
        self.name = name
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.expanded = expanded
        self.loading = loading
        self.loaded = loaded
        self.loadedIncludeHidden = loadedIncludeHidden
        self.forcedVisibleHiddenChildPath = forcedVisibleHiddenChildPath
        self.forcedVisiblePackageChildPath = forcedVisiblePackageChildPath
        self.error = error
        self.childPaths = childPaths
    }

    /// `createTreeNode`: a folder not read yet; "Macintosh HD" for `/`.
    public init(path: String, expanded: Bool) {
        self.init(
            path: path, name: path == "/" ? "Macintosh HD" : (JSString.components(path, separator: 0x2F).last ?? path),
            expanded: expanded)
    }
}

/// The folders of a tab's tree by path, keyed by the exact code units of the path as a `Map` is (the NFC and NFD
/// spellings of a name are two folders).
public struct TreeNodes: Equatable, Sendable {
    private var storage: [ExactKey: TreeNodeState] = [:]

    public init() {}

    public init(_ nodes: [TreeNodeState]) {
        for node in nodes { storage[ExactKey(node.path)] = node }
    }

    public subscript(path: String) -> TreeNodeState? {
        get { storage[ExactKey(path)] }
        set { storage[ExactKey(path)] = newValue }
    }

    public var isEmpty: Bool { storage.isEmpty }
    public var all: [TreeNodeState] { Array(storage.values) }
}

/// A row as the sidebar presents it (`TreePresentationItem`).
public struct TreePresentationItem: Equatable, Sendable {
    public var id: TreeItemID
    public var kind: TreeItemKind
    public var label: String
    public var depth: Int
    public var path: String?
    public var parentID: TreeItemID?
    public var expanded: Bool
    public var canExpand: Bool
    public var loading: Bool
    public var error: String?
    public var isSymlink: Bool
    public var childIDs: [TreeItemID]
    public var icon: FavoriteIconID?
    /// A disk's row in Locations that has an Eject button.
    public var canEject: Bool

    public init(
        id: TreeItemID, kind: TreeItemKind, label: String, depth: Int, path: String?, parentID: TreeItemID?,
        expanded: Bool, canExpand: Bool, loading: Bool = false, error: String? = nil, isSymlink: Bool = false,
        childIDs: [TreeItemID] = [], icon: FavoriteIconID? = nil, canEject: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.depth = depth
        self.path = path
        self.parentID = parentID
        self.expanded = expanded
        self.canExpand = canExpand
        self.loading = loading
        self.error = error
        self.isSymlink = isSymlink
        self.childIDs = childIDs
        self.icon = icon
        self.canEject = canEject
    }
}

/// The rows to draw, in order, and each by id.
public struct TreePresentation: Equatable, Sendable {
    public var items: [TreeItemID: TreePresentationItem]
    public var visibleItemIDs: [TreeItemID]

    public init(items: [TreeItemID: TreePresentationItem] = [:], visibleItemIDs: [TreeItemID] = []) {
        self.items = items
        self.visibleItemIDs = visibleItemIDs
    }

    public var visibleItems: [TreePresentationItem] { visibleItemIDs.compactMap { items[$0] } }
}
