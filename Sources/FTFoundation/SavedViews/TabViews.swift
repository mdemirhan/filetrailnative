import Foundation

/// How a tab view treats a folder that has a view (its own, or one from a folder above), in a pane it gives settings
/// to. It holds only while the pane stays in the folder it was on once the tab view was applied.
public enum FolderViewsChoice: String, Codable, CaseIterable, Sendable {
    /// The folder's view comes first, as in any pane.
    case folderFirst
    /// What the tab view keeps comes first; the folder's view gives the rest.
    case tabViewFirst
    /// The folder's view isn't used: the pane shows what it carries.
    case notUsed
}

/// A pane showing a file in the viewer beside the other pane's list, as Open in Other Pane shows one.
public struct PaneViewer: Codable, Equatable, Sendable {
    /// Follow, as the viewer's bar has it: the file the other pane selects, as the selection moves; off, the file
    /// selected as the tab view is applied, whatever is selected after.
    public var follows: Bool
    /// Edit, as the viewer's bar has it: the file opens to be edited, not only read.
    public var editing: Bool

    public init(follows: Bool = true, editing: Bool = false) {
        self.follows = follows
        self.editing = editing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            follows: (try? container.decode(Bool.self, forKey: .follows)) ?? true,
            editing: (try? container.decode(Bool.self, forKey: .editing)) ?? false)
    }
}

/// What a tab view keeps of one pane, each part only if kept.
public struct PaneKeeps: Codable, Equatable, Sendable {
    /// The folder the pane goes to; nil: it stays on its folder.
    @SavedPathIfAny public var folder: String?
    /// The six settings a folder's view keeps, kept the same way.
    public var view: FolderViewKeeps
    /// How folders with a view are treated; nil is `.folderFirst`, which the file doesn't write.
    public var folderViews: FolderViewsChoice?
    /// The pane shows the viewer, not a folder: then it keeps nothing else, as a folder's settings don't show in it.
    public var viewer: PaneViewer?

    public init(
        folder: String? = nil, view: FolderViewKeeps = FolderViewKeeps(), folderViews: FolderViewsChoice = .folderFirst,
        viewer: PaneViewer? = nil
    ) {
        self.viewer = viewer
        let list = viewer == nil
        self.folder = !list || folder?.isEmpty == true ? nil : folder
        self.view = list ? view : FolderViewKeeps()
        self.folderViews = !list || folderViews == .folderFirst ? nil : folderViews
    }

    /// Each part is read on its own: one that can't be read is not kept, and the others are.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            folder: (try? container.decode(SavedPathIfAny.self, forKey: .folder))?.wrappedValue,
            view: (try? container.decode(FolderViewKeeps.self, forKey: .view)) ?? FolderViewKeeps(),
            folderViews: (try? container.decode(FolderViewsChoice.self, forKey: .folderViews)) ?? .folderFirst,
            viewer: try? container.decode(PaneViewer.self, forKey: .viewer))
    }

    public var choice: FolderViewsChoice { folderViews ?? .folderFirst }

    /// Keeps nothing and changes nothing: not kept.
    public var isEmpty: Bool { folder == nil && view.isEmpty && folderViews == nil && viewer == nil }

    /// The same as a list: no viewer.
    var withoutViewer: PaneKeeps { PaneKeeps(folder: folder, view: view, folderViews: choice) }
}

/// What a tab view keeps of a tab: each setting only if kept; nil carries over from the tab it is applied to.
public struct TabViewKeeps: Codable, Equatable, Sendable {
    /// The divider between two panes.
    public enum Divider: Equatable, Sendable {
        /// The room shared evenly.
        case even
        /// The left pane's share of the room, within what a drag of the divider allows.
        case share(Double)
        /// The left pane's width in points; the right pane takes the rest.
        case leftWidth(Double)
    }

    /// One pane or two; nil: the panes are left as they are, and `pane` goes to the active one.
    public var panes: Int?
    /// Only with two panes.
    public var divider: Divider?
    public var includeHidden: Bool?
    /// The left and the right pane's, with two panes.
    public var left: PaneKeeps?
    public var right: PaneKeeps?
    /// The pane's, with one pane; or the active pane's, when `panes` is nil.
    public var pane: PaneKeeps?

    /// What makes sense of the parts is kept: a divider only with two panes, `left` and `right` only with two, `pane`
    /// only without; a share within the divider's limits; the viewer only in one of two panes, the left's when both
    /// ask, as it shows what the other's list selects; a pane that keeps nothing is not kept.
    public init(
        panes: Int? = nil, divider: Divider? = nil, includeHidden: Bool? = nil, left: PaneKeeps? = nil,
        right: PaneKeeps? = nil, pane: PaneKeeps? = nil
    ) {
        let panes = panes == 1 || panes == 2 ? panes : nil
        self.panes = panes
        self.includeHidden = includeHidden
        let two = panes == 2
        self.divider = two ? divider.flatMap(Self.valid) : nil
        self.left = two ? left.flatMap(Self.kept) : nil
        let right = left?.viewer != nil ? right?.withoutViewer : right
        self.right = two ? right.flatMap(Self.kept) : nil
        self.pane = two ? nil : pane.map(\.withoutViewer).flatMap(Self.kept)
    }

    private static func kept(_ pane: PaneKeeps) -> PaneKeeps? { pane.isEmpty ? nil : pane }

    private static func valid(_ divider: Divider) -> Divider? {
        switch divider {
        case .even: .even
        case .share(let share): share.isFinite ? .share(PaneSplit.clamp(share)) : nil
        case .leftWidth(let width): width.isFinite && width >= 1 ? .leftWidth(width.rounded()) : nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            panes: try? container.decode(Int.self, forKey: .panes),
            divider: try? container.decode(Divider.self, forKey: .divider),
            includeHidden: try? container.decode(Bool.self, forKey: .includeHidden),
            left: try? container.decode(PaneKeeps.self, forKey: .left),
            right: try? container.decode(PaneKeeps.self, forKey: .right),
            pane: try? container.decode(PaneKeeps.self, forKey: .pane))
    }

    /// Keeps nothing at all.
    public var isEmpty: Bool {
        panes == nil && divider == nil && includeHidden == nil && left == nil && right == nil && pane == nil
    }

    /// The panes it gives settings to, each with what it keeps of it: by place with one or two panes kept, the
    /// active one otherwise. `active` is the tab's active pane once the panes are as the tab view keeps them.
    public func paneKeeps(active: Int) -> [(index: Int, keeps: PaneKeeps)] {
        switch panes {
        case 2:
            [(0, left), (1, right)].compactMap { pair -> (index: Int, keeps: PaneKeeps)? in
                pair.1.map { (index: pair.0, keeps: $0) }
            }
        case 1: pane.map { [(index: 0, keeps: $0)] } ?? []
        default: pane.map { [(index: active, keeps: $0)] } ?? []
        }
    }

    /// Every folder it opens, in order of the panes.
    public var folders: [String] {
        [left, right, pane].compactMap { $0?.folder }
    }
}

extension TabViewKeeps.Divider: Codable {
    private enum CodingKeys: String, CodingKey { case even, share, leftWidth }

    /// Written as one key: `{"even": true}`, `{"share": 0.62}` or `{"leftWidth": 420}`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let share = try? container.decode(Double.self, forKey: .share) {
            self = .share(share)
        } else if let width = try? container.decode(Double.self, forKey: .leftWidth) {
            self = .leftWidth(width)
        } else if (try? container.decode(Bool.self, forKey: .even)) == true {
            self = .even
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No divider"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .even: try container.encode(true, forKey: .even)
        case .share(let share): try container.encode(share, forKey: .share)
        case .leftWidth(let width): try container.encode(width, forKey: .leftWidth)
        }
    }
}

/// A tab's settings saved by name, to be applied to a tab.
public struct TabView: Codable, Equatable, Sendable, NamedSavedView {
    /// Kept while it is renamed and moved in the list, and when it is saved over; window views name it by it.
    public var id: String
    public var name: String
    public var keeps: TabViewKeeps

    public init(id: String, name: String, keeps: TabViewKeeps) {
        self.id = id
        self.name = name
        self.keeps = keeps
    }
}

// MARK: Applying

/// One pane as a tab view sees it: the folder it shows and the six settings it carries from folder to folder, every
/// one of them set, and the viewer it shows beside the other pane, if it does.
public struct PaneState: Equatable, Sendable {
    public var folder: String?
    public var settings: FolderViewKeeps
    public var viewer: PaneViewer?

    public init(folder: String?, settings: FolderViewKeeps, viewer: PaneViewer? = nil) {
        self.folder = folder
        self.settings = settings
        self.viewer = viewer
    }
}

/// A tab as a tab view sees it: its panes, which is active, how the room is shared, hidden files, and the pane Two
/// Panes (⌘\) would bring back.
public struct TabState: Equatable, Sendable {
    /// One or two.
    public var panes: [PaneState]
    public var active: Int
    /// The left pane's share, while there are two.
    public var split: Double
    public var includeHidden: Bool
    /// The pane closed in this tab, which ⌘\ opens again where it was.
    public var closedPane: PaneState?

    public init(
        panes: [PaneState], active: Int = 0, split: Double = PaneSplit.even, includeHidden: Bool = false,
        closedPane: PaneState? = nil
    ) {
        self.panes = panes
        self.active = active
        self.split = split
        self.includeHidden = includeHidden
        self.closedPane = closedPane
    }
}

/// What a tab view applied with `.tabViewFirst` or `.notUsed` leaves on a pane: the folder it holds in, the choice,
/// and the settings the tab view kept. It holds while the pane stays in that folder.
public struct TabViewOverride: Equatable, Sendable {
    public var folder: String
    public var choice: FolderViewsChoice
    public var kept: Set<FolderViewSetting>

    public init(folder: String, choice: FolderViewsChoice, kept: Set<FolderViewSetting>) {
        self.folder = folder
        self.choice = choice
        self.kept = kept
    }

    /// Whether it holds for a pane showing `folder`: the same folder, by its path's bytes.
    public func holds(in folder: String?) -> Bool {
        guard let folder, choice != .folderFirst else { return false }
        return DiskPath(folder) == DiskPath(self.folder)
    }

    /// Whether it decides `setting`: every setting while the folder's view isn't used, the kept ones while the tab
    /// view comes first.
    public func covers(_ setting: FolderViewSetting) -> Bool {
        choice == .notUsed || (choice == .tabViewFirst && kept.contains(setting))
    }

    /// The same without `setting`, once that setting is changed by hand in the folder; nil when nothing is left that
    /// it decides.
    public func without(_ setting: FolderViewSetting) -> TabViewOverride? {
        switch choice {
        case .folderFirst:
            return nil
        case .tabViewFirst:
            var next = self
            next.kept.remove(setting)
            return next.kept.isEmpty ? nil : next
        case .notUsed:
            // Not using the folder's view is one choice: a change by hand of any setting is a change of the folder's
            // view, so the folder's view comes back for every setting.
            return nil
        }
    }
}

/// A tab view applied to a tab: the tab as it is after, and what the window has to do to show it.
public struct TabViewApplied: Equatable, Sendable {
    /// What happened to the second pane.
    public enum SecondPane: Equatable, Sendable {
        /// Opened as ⌘\ opens it: where it was last closed in the tab (`reopened`), or as a copy of the active pane.
        case opened(reopened: Bool)
        /// The pane at this place (before) closed, as ⌘\ closes it; it is the tab's closed pane now.
        case closed(Int)
    }

    public var tab: TabState
    public var secondPane: SecondPane?
    /// The panes (after) the tab view gave settings to: an override these had before is replaced by `overrides`.
    public var panesGiven: [Int]
    /// The panes (after) whose folder the tab view changed: each goes there, and Back comes back.
    public var panesMoved: [Int]
    /// The overrides the tab view leaves, by pane (after).
    public var overrides: [Int: TabViewOverride]
    /// The panes (after) that show the viewer beside the other pane, with how.
    public var viewers: [Int: PaneViewer] = [:]
    /// The panes (after) whose viewer closes: the tab view keeps a view of a folder for them.
    public var viewersClosed: [Int] = []
}

/// The rules of the tab views: applying one, and its folders that are gone.
public enum TabViews {
    /// The commands that apply the first tab views in the list (Tab View 1 to 5), in order.
    public static let slotCommands: [ShortcutCommandID] = [
        .applyTabView1, .applyTabView2, .applyTabView3, .applyTabView4, .applyTabView5,
    ]

    /// Which tab view in the list a command applies, from 0; nil for any other command.
    public static func slot(of command: ShortcutCommandID) -> Int? {
        slotCommands.firstIndex(of: command)
    }

    /// The tab with `keeps` applied: in order, the panes, the divider, hidden files, each pane's settings and folder,
    /// and the overrides it leaves. The active pane stays the active pane. `columnWidth` is the room the two panes share,
    /// which a divider kept as a width is measured against.
    public static func applying(_ keeps: TabViewKeeps, to tab: TabState, columnWidth: Double) -> TabViewApplied {
        var tab = tab
        tab.active = min(max(0, tab.active), tab.panes.count - 1)
        var secondPane: TabViewApplied.SecondPane?
        if keeps.panes == 2, tab.panes.count == 1 {
            if let closed = tab.closedPane {
                tab.panes.append(closed)
                secondPane = .opened(reopened: true)
            } else {
                tab.panes.append(tab.panes[tab.active])
                secondPane = .opened(reopened: false)
            }
            tab.closedPane = nil
        } else if keeps.panes == 1, tab.panes.count == 2 {
            let other = tab.active == 0 ? 1 : 0
            tab.closedPane = tab.panes.remove(at: other)
            tab.active = 0
            secondPane = .closed(other)
        }
        if tab.panes.count == 2, let divider = keeps.divider {
            tab.split = share(divider, columnWidth: columnWidth)
        }
        if let hidden = keeps.includeHidden { tab.includeHidden = hidden }
        var given: [Int] = []
        var moved: [Int] = []
        var overrides: [Int: TabViewOverride] = [:]
        var viewers: [Int: PaneViewer] = [:]
        var viewersClosed: [Int] = []
        for (index, paneKeeps) in keeps.paneKeeps(active: tab.active) where tab.panes.indices.contains(index) {
            given.append(index)
            if let viewer = paneKeeps.viewer {
                // The viewer shows what the other pane selects, in the other pane's folder: nothing else is the
                // tab view's in it.
                tab.panes[index].viewer = viewer
                viewers[index] = viewer
                continue
            }
            if paneKeeps.view.view != nil, tab.panes[index].viewer != nil {
                tab.panes[index].viewer = nil
                viewersClosed.append(index)
            }
            if let folder = paneKeeps.folder, tab.panes[index].folder.map({ DiskPath($0) }) != DiskPath(folder) {
                tab.panes[index].folder = folder
                moved.append(index)
            }
            for setting in paneKeeps.view.kept {
                tab.panes[index].settings.take(setting, from: paneKeeps.view)
            }
            if paneKeeps.choice != .folderFirst, let folder = tab.panes[index].folder {
                overrides[index] = TabViewOverride(
                    folder: folder, choice: paneKeeps.choice, kept: Set(paneKeeps.view.kept))
            }
        }
        return TabViewApplied(
            tab: tab, secondPane: secondPane, panesGiven: given, panesMoved: moved, overrides: overrides,
            viewers: viewers, viewersClosed: viewersClosed)
    }

    /// The left pane's share a divider gives in a column `columnWidth` wide.
    public static func share(_ divider: TabViewKeeps.Divider, columnWidth: Double) -> Double {
        switch divider {
        case .even: PaneSplit.even
        case .share(let share): PaneSplit.clamp(share)
        case .leftWidth(let width): PaneSplit.share(leftWidth: width, columnWidth: columnWidth)
        }
    }

    /// The tab view with each of its folders in `gone` replaced as `nearest` says (the nearest folder above that is
    /// there), and how many were. A folder is one by its path's bytes.
    public static func replacingGoneFolders(
        _ keeps: TabViewKeeps, gone: Set<DiskPath>, nearest: (String) -> String
    ) -> (keeps: TabViewKeeps, replaced: Int) {
        guard !gone.isEmpty else { return (keeps, 0) }
        var result = keeps
        var replaced = 0
        func fix(_ pane: inout PaneKeeps?) {
            guard let folder = pane?.folder, gone.contains(DiskPath(folder)) else { return }
            pane?.folder = nearest(folder)
            replaced += 1
        }
        fix(&result.left)
        fix(&result.right)
        fix(&result.pane)
        return (result, replaced)
    }

    // MARK: Reading

    /// Tab views from a file, kept as far as they make sense: one with no id, an id or a name another has, no name, or
    /// nothing kept is left out; past `SavedViewNames.limit` the rest are.
    public static func sanitize(_ value: JSONNode?) -> [TabView] {
        guard let candidates = value?.array else { return [] }
        var views: [TabView] = []
        for candidate in candidates {
            guard let record = candidate.object, let id = record["id"]?.string, !id.isEmpty,
                SavedViewNames.index(id: id, in: views) == nil
            else { continue }
            let name = SavedViewNames.clean(record["name"]?.string ?? "")
            guard !name.isEmpty, SavedViewNames.index(named: name, in: views) == nil,
                let keeps = try? record["keeps"]?.decode(TabViewKeeps.self), !keeps.isEmpty
            else { continue }
            views.append(TabView(id: id, name: name, keeps: keeps))
            if views.count == SavedViewNames.limit { break }
        }
        return views
    }
}
