import Foundation

/// Window View Options as it is being filled in: the tabs and the tab view each opens with, the tab in front, and the
/// window's own settings, each kept only if checked. `windowView(id:)` is what Save saves.
public struct WindowViewDraft: Equatable, Sendable {
    /// The Size row's choices.
    public enum SizeChoice: Equatable, Sendable {
        /// The window's size now.
        case now
        /// What the window view being edited keeps.
        case saved
        /// A width and height typed in.
        case custom
    }

    public var name: String
    /// The window view being edited; nil for a new one.
    public var editingID: String?
    /// A tab view's id for each tab; nil: a plain new tab.
    public private(set) var tabs: [String?]
    public var front: Int {
        didSet { front = min(max(0, front), tabs.count - 1) }
    }
    public var keepsSize: Bool
    public var sizeChoice: SizeChoice
    public let sizeNow: WindowView.Size
    public let savedSize: WindowView.Size?
    /// A width and height typed in, held between the smallest a window can be and `largestSize`.
    public var customSize: WindowView.Size {
        didSet { customSize = held(customSize) }
    }
    /// The room the screen gives a window: the largest size that can be typed in. Nil: no limit known.
    public let largestSize: WindowView.Size?
    public var keepsFolderTree: Bool
    public var folderTreeOpen: Bool
    public var keepsInfoPanel: Bool
    public var propertiesOpen: Bool

    /// A new window view, from a window: its tabs, the one in front, its size and panels as they are. Nothing of the
    /// window's own is kept to begin with: what isn't checked comes from the window it is opened from.
    public init(
        tabs: [String?], front: Int, size: WindowView.Size, folderTreeOpen: Bool, propertiesOpen: Bool,
        largestSize: WindowView.Size? = nil
    ) {
        name = ""
        editingID = nil
        self.tabs = tabs.isEmpty ? [nil] : Array(tabs.prefix(AppPreferenceLimits.openTabsLimit))
        self.front = min(max(0, front), self.tabs.count - 1)
        keepsSize = false
        sizeChoice = .now
        sizeNow = size
        savedSize = nil
        self.largestSize = largestSize
        customSize = Self.held(size, largest: largestSize)
        keepsFolderTree = false
        self.folderTreeOpen = folderTreeOpen
        keepsInfoPanel = false
        self.propertiesOpen = propertiesOpen
    }

    /// A window view being edited: what it keeps, over the window it is edited from.
    public init(
        editing view: WindowView, sizeNow: WindowView.Size, folderTreeOpen: Bool, propertiesOpen: Bool,
        largestSize: WindowView.Size? = nil
    ) {
        name = view.name
        editingID = view.id
        tabs = view.tabs
        front = view.frontTab
        keepsSize = view.size != nil
        sizeChoice = view.size == nil ? .now : .saved
        self.sizeNow = sizeNow
        savedSize = view.size
        self.largestSize = largestSize
        customSize = Self.held(view.size ?? sizeNow, largest: largestSize)
        keepsFolderTree = view.folderTreeOpen != nil
        self.folderTreeOpen = view.folderTreeOpen ?? folderTreeOpen
        keepsInfoPanel = view.propertiesOpen != nil
        self.propertiesOpen = view.propertiesOpen ?? propertiesOpen
    }

    /// The smallest size a window can be.
    public static var smallestSize: WindowView.Size { WindowView.minimumSize }

    /// `size` held between `smallestSize` and `largestSize`.
    public func held(_ size: WindowView.Size) -> WindowView.Size { Self.held(size, largest: largestSize) }

    private static func held(_ size: WindowView.Size, largest: WindowView.Size?) -> WindowView.Size {
        let low = smallestSize
        let high = largest ?? WindowView.Size(width: Int.max, height: Int.max)
        return WindowView.Size(
            width: min(max(size.width, low.width), max(low.width, high.width)),
            height: min(max(size.height, low.height), max(low.height, high.height)))
    }

    /// As many tabs as `count` (1 to the tab limit): the first ones keep their tab views, new ones are plain tabs.
    public mutating func setTabCount(_ count: Int) {
        let count = min(max(1, count), AppPreferenceLimits.openTabsLimit)
        if count < tabs.count {
            tabs.removeLast(tabs.count - count)
        } else {
            tabs += Array(repeating: nil, count: count - tabs.count)
        }
        front = min(front, count - 1)
    }

    /// Tab `index` opens with the tab view `id`, or as a plain new tab.
    public mutating func setTab(_ index: Int, to id: String?) {
        guard tabs.indices.contains(index) else { return }
        tabs[index] = id
    }

    /// The size Save keeps; nil while Size isn't checked.
    public var sizeKept: WindowView.Size? {
        guard keepsSize else { return nil }
        switch sizeChoice {
        case .now: return sizeNow
        case .saved: return savedSize ?? sizeNow
        case .custom: return customSize
        }
    }

    /// What Save saves, under `id`.
    public func windowView(id: String) -> WindowView {
        WindowView(
            id: id, name: SavedViewNames.clean(name), tabs: tabs, frontTab: front, size: sizeKept,
            folderTreeOpen: keepsFolderTree ? folderTreeOpen : nil,
            propertiesOpen: keepsInfoPanel ? propertiesOpen : nil)
    }
}

extension SavedViewText {
    /// What a window view keeps, a part for each: "3 tabs", "1: Compare", "2: New tab", "Size 1440 × 900".
    public static func parts(_ view: WindowView, tabViews: [TabView]) -> [String] {
        var parts = [view.tabs.count == 1 ? "1 tab" : "\(view.tabs.count) tabs"]
        for (index, tabView) in view.resolvedTabs(in: tabViews).enumerated() {
            parts.append("\(index + 1): \(tabView?.name ?? "New tab")")
        }
        if view.frontTab > 0 { parts.append("Tab \(view.frontTab + 1) in front") }
        if let size = view.size { parts.append("Size \(size.width) \u{00D7} \(size.height)") }
        if let tree = view.folderTreeOpen { parts.append(tree ? "Folder tree shown" : "Folder tree hidden") }
        if let info = view.propertiesOpen { parts.append(info ? "Info panel shown" : "Info panel hidden") }
        return parts
    }
}
