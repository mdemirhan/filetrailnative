import Foundation

/// A window saved by name, made of tab views: how many tabs it opens, the tab view each one is opened with, which is in
/// front, and the window's own settings, each kept only if checked.
public struct WindowView: Codable, Equatable, Sendable, NamedSavedView {
    /// A window's size: never its place on screen.
    public struct Size: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var id: String
    public var name: String
    /// A tab view's id for each tab, in order; nil: a plain new tab, as New Tab opens it.
    public var tabs: [String?]
    public var frontTab: Int
    /// Nil: a new window's size, as a new window has.
    public var size: Size?
    /// Nil: as in the window it is opened from.
    public var folderTreeOpen: Bool?
    public var propertiesOpen: Bool?

    /// What makes sense is kept: at least one tab and at most the tab limit, the front tab one of them, a size of a
    /// window at least `minimumSize`.
    public init(
        id: String, name: String, tabs: [String?], frontTab: Int = 0, size: Size? = nil,
        folderTreeOpen: Bool? = nil, propertiesOpen: Bool? = nil
    ) {
        self.id = id
        self.name = name
        var tabs = Array(tabs.prefix(AppPreferenceLimits.openTabsLimit)).map { $0?.isEmpty == true ? nil : $0 }
        if tabs.isEmpty { tabs = [nil] }
        self.tabs = tabs
        self.frontTab = tabs.indices.contains(frontTab) ? frontTab : 0
        self.size = size.map {
            Size(width: max($0.width, Self.minimumSize.width), height: max($0.height, Self.minimumSize.height))
        }
        self.folderTreeOpen = folderTreeOpen
        self.propertiesOpen = propertiesOpen
    }

    /// The smallest size kept: the smallest an explorer window can be made.
    public static let minimumSize = Size(width: 760, height: 480)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = (try? container.decode([JSONNode].self, forKey: .tabs))?.map(\.string) ?? []
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            tabs: tabs,
            frontTab: (try? container.decode(Int.self, forKey: .frontTab)) ?? 0,
            size: try? container.decode(Size.self, forKey: .size),
            folderTreeOpen: try? container.decode(Bool.self, forKey: .folderTreeOpen),
            propertiesOpen: try? container.decode(Bool.self, forKey: .propertiesOpen))
    }

    /// The tab views it opens tabs with, by id: one that names no tab view in `tabViews` is a plain new tab.
    public func resolvedTabs(in tabViews: [TabView]) -> [TabView?] {
        tabs.map { id in id.flatMap { id in SavedViewNames.index(id: id, in: tabViews).map { tabViews[$0] } } }
    }

    /// A size kept, held to `visible` (the screen's room a window can have), and no smaller than `minimumSize`.
    public static func held(_ size: Size, within visible: Size) -> Size {
        Size(
            width: max(minimumSize.width, min(size.width, visible.width)),
            height: max(minimumSize.height, min(size.height, visible.height)))
    }
}

/// The rules of the window views: their references to tab views, and reading them.
public enum WindowViews {
    /// The commands that open the first window views in the list (Window View 1 to 5), in order.
    public static let slotCommands: [ShortcutCommandID] = [
        .openWindowView1, .openWindowView2, .openWindowView3, .openWindowView4, .openWindowView5,
    ]

    /// The commands that open the same five in place of the window the menu acts on, in order.
    public static let inThisWindowSlotCommands: [ShortcutCommandID] = [
        .openWindowView1InThisWindow, .openWindowView2InThisWindow, .openWindowView3InThisWindow,
        .openWindowView4InThisWindow, .openWindowView5InThisWindow,
    ]

    /// Which window view in the list a command opens in a new window, from 0; nil for any other command.
    public static func slot(of command: ShortcutCommandID) -> Int? {
        slotCommands.firstIndex(of: command)
    }

    /// Which window view in the list a command opens in place of the window, from 0; nil for any other command.
    public static func inThisWindowSlot(of command: ShortcutCommandID) -> Int? {
        inThisWindowSlotCommands.firstIndex(of: command)
    }

    /// The window views that open a tab with the tab view `id`.
    public static func using(_ id: String, in views: [WindowView]) -> [WindowView] {
        views.filter { view in view.tabs.contains { $0.map { $0.utf16.elementsEqual(id.utf16) } ?? false } }
    }

    /// `views` with every tab that opened with the tab view `id` made a plain new tab: what is left once it is
    /// removed.
    public static func forgetting(_ id: String, in views: [WindowView]) -> [WindowView] {
        views.map { view in
            var view = view
            view.tabs = view.tabs.map { tab in tab.map { $0.utf16.elementsEqual(id.utf16) } == true ? nil : tab }
            return view
        }
    }

    /// Window views from a file, kept as far as they make sense: one with no id, an id or a name another has, or no
    /// name is left out, as are those past `SavedViewNames.limit`. What is left of each is as `WindowView`'s reading
    /// keeps it.
    public static func sanitize(_ value: JSONNode?) -> [WindowView] {
        guard let candidates = value?.array else { return [] }
        var views: [WindowView] = []
        for candidate in candidates {
            guard var view = try? candidate.decode(WindowView.self), !view.id.isEmpty,
                SavedViewNames.index(id: view.id, in: views) == nil
            else { continue }
            view.name = SavedViewNames.clean(view.name)
            guard !view.name.isEmpty, SavedViewNames.index(named: view.name, in: views) == nil else { continue }
            views.append(view)
            if views.count == SavedViewNames.limit { break }
        }
        return views
    }
}
