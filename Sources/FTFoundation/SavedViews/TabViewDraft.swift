import Foundation

/// Tab View Options as it is being filled in: what each row shows and whether it is kept. Every value starts at what
/// the tab shows now; a saved tab view being edited shows what it keeps over that. `keeps` is what Save saves.
public struct TabViewDraft: Equatable, Sendable {
    /// The Divider row's choices.
    public enum Divider: Equatable, Sendable {
        case even
        /// The share the tab has now.
        case shareNow
        /// The left pane's width now.
        case widthNow
        /// What the tab view being edited keeps.
        case saved
        /// A share typed in.
        case custom
    }

    /// One pane's rows: its folder, the six settings with their values and whether each is kept, and the
    /// folder-views choice.
    public struct Pane: Equatable, Sendable {
        public var keepsFolder: Bool
        public var folder: String?
        /// Every setting set: the value each row shows.
        public var values: FolderViewKeeps
        public var kept: Set<FolderViewSetting>
        public var folderViews: FolderViewsChoice
        /// The View row's choice is Viewer, with how it follows and opens; nil: one of the folder's views, `values`'.
        public var viewer: PaneViewer?

        public init(state: PaneState, keeps: PaneKeeps?) {
            keepsFolder = keeps?.folder != nil
            folder = keeps?.folder ?? state.folder
            var values = state.settings
            for setting in keeps?.view.kept ?? [] { values.take(setting, from: keeps?.view ?? FolderViewKeeps()) }
            self.values = values
            kept = Set(keeps?.view.kept ?? [])
            folderViews = keeps?.choice ?? .folderFirst
            if let viewer = keeps?.viewer {
                self.viewer = viewer
                kept.insert(.view)
            } else {
                // A view kept is the view the pane gets; else the row shows what the pane shows now.
                self.viewer = keeps?.view.view == nil ? state.viewer : nil
            }
        }

        /// What it keeps: the folder where checked, each setting checked with its value, and the choice; or the viewer
        /// alone, where `viewerAllowed` and View is checked with Viewer chosen.
        public func keeps(viewerAllowed: Bool) -> PaneKeeps {
            if viewerAllowed, kept.contains(.view), let viewer { return PaneKeeps(viewer: viewer) }
            var view = FolderViewKeeps()
            for setting in FolderViewSetting.allCases where kept.contains(setting) { view.take(setting, from: values) }
            return PaneKeeps(folder: keepsFolder ? folder : nil, view: view, folderViews: folderViews)
        }

        /// Keep `setting` or not.
        public mutating func keep(_ setting: FolderViewSetting, _ on: Bool) {
            if on { kept.insert(setting) } else { kept.remove(setting) }
        }

        /// A value chosen in a row: it is kept from then on, as choosing in Folder View Options keeps it.
        public mutating func set(_ setting: FolderViewSetting, _ change: (inout FolderViewKeeps) -> Void) {
            change(&values)
            kept.insert(setting)
        }
    }

    /// The pane groups the sheet shows: left and right with two panes kept, the one pane with one, the active pane
    /// with panes not kept.
    public enum PaneGroup: Equatable, Sendable {
        case left, right, onePane, activePane

        public var title: String {
            switch self {
            case .left: "Left Pane"
            case .right: "Right Pane"
            case .onePane: "The Pane"
            case .activePane: "The Active Pane"
            }
        }
    }

    public var name: String
    /// The tab view being edited; nil for a new one.
    public var editingID: String?

    public var keepsPanes: Bool
    public var panes: Int
    public var keepsDivider: Bool
    public var divider: Divider
    /// The left pane's share typed in, within what a drag of the divider allows.
    public var customShare: Double {
        didSet { customShare = PaneSplit.clamp(customShare) }
    }
    public var keepsHidden: Bool
    public var hidden: Bool
    public var left: Pane
    public var right: Pane
    /// The pane with one pane kept, or the active one with panes not kept.
    public var active: Pane

    /// What the tab has now, for the "as now" choices.
    public let shareNow: Double
    public let widthNow: Double
    /// The divider the tab view being edited keeps.
    public let savedDivider: TabViewKeeps.Divider?
    /// The folders each pane shows now, with which pane: offered first in each Folder row.
    public let foldersNow: [(path: String, pane: String)]

    public static func == (lhs: TabViewDraft, rhs: TabViewDraft) -> Bool {
        lhs.name == rhs.name && lhs.editingID == rhs.editingID && lhs.keepsPanes == rhs.keepsPanes
            && lhs.panes == rhs.panes && lhs.keepsDivider == rhs.keepsDivider && lhs.divider == rhs.divider
            && lhs.customShare == rhs.customShare && lhs.keepsHidden == rhs.keepsHidden && lhs.hidden == rhs.hidden
            && lhs.left == rhs.left && lhs.right == rhs.right && lhs.active == rhs.active
            && lhs.shareNow == rhs.shareNow && lhs.widthNow == rhs.widthNow && lhs.savedDivider == rhs.savedDivider
            && lhs.foldersNow.map(\.path) == rhs.foldersNow.map(\.path)
    }

    /// The sheet for `tab` as it is, `columnWidth` the room its panes share; for a new tab view, or for `editing`.
    public init(tab: TabState, columnWidth: Double, editing: TabView? = nil, name: String = "") {
        let keeps = editing?.keeps
        self.name = editing?.name ?? name
        editingID = editing?.id
        let activeState = tab.panes[min(max(0, tab.active), tab.panes.count - 1)]
        let leftState = tab.panes[0]
        let rightState = tab.panes.count > 1 ? tab.panes[1] : (tab.closedPane ?? activeState)
        if let keeps {
            keepsPanes = keeps.panes != nil
            panes = keeps.panes ?? tab.panes.count
            left = Pane(state: leftState, keeps: keeps.left)
            right = Pane(state: rightState, keeps: keeps.right)
            active = Pane(state: activeState, keeps: keeps.pane)
            keepsHidden = keeps.includeHidden != nil
            hidden = keeps.includeHidden ?? tab.includeHidden
            keepsDivider = keeps.divider != nil
            switch keeps.divider {
            case .even?: divider = .even
            case .share?, .leftWidth?: divider = .saved
            case nil: divider = .shareNow
            }
            savedDivider = keeps.divider
        } else {
            // A new tab view keeps the panes and each pane's view to begin with; the rest is checked by hand.
            keepsPanes = true
            panes = tab.panes.count
            let viewOnly = { (state: PaneState) in
                state.viewer.map { PaneKeeps(viewer: $0) }
                    ?? PaneKeeps(view: FolderViewKeeps(view: state.settings.view))
            }
            left = Pane(state: leftState, keeps: viewOnly(leftState))
            right = Pane(state: rightState, keeps: viewOnly(rightState))
            active = Pane(state: activeState, keeps: viewOnly(activeState))
            keepsHidden = false
            hidden = tab.includeHidden
            keepsDivider = false
            divider = .shareNow
            savedDivider = nil
        }
        let room = columnWidth - PaneSplit.dividerWidth
        shareNow = tab.panes.count == 2 ? tab.split : PaneSplit.even
        widthNow = max(1, (room * shareNow).rounded())
        customShare = shareNow
        if case .share(let share)? = keeps?.divider { customShare = share }
        var now: [(path: String, pane: String)] = []
        if tab.panes.count == 2 {
            if let path = tab.panes[0].folder { now.append((path, "the Left Pane Now")) }
            if let path = tab.panes[1].folder { now.append((path, "the Right Pane Now")) }
        } else if let path = tab.panes[0].folder {
            now.append((path, "the Pane Now"))
        }
        foldersNow = now
    }

    /// The pane groups shown, in order.
    public var paneGroups: [PaneGroup] {
        guard keepsPanes else { return [.activePane] }
        return panes == 2 ? [.left, .right] : [.onePane]
    }

    /// The rows of a pane group.
    public subscript(group: PaneGroup) -> Pane {
        get {
            switch group {
            case .left: left
            case .right: right
            case .onePane, .activePane: active
            }
        }
        set {
            switch group {
            case .left: left = newValue
            case .right: right = newValue
            case .onePane, .activePane: active = newValue
            }
        }
    }

    /// Whether a group's View row offers Viewer: in either of two panes, beside the other's list.
    public static func offersViewer(_ group: PaneGroup) -> Bool { group == .left || group == .right }

    /// The pane group shows the viewer (`viewer`) or a view of its folder (nil, `values`'), kept from then on. One pane
    /// of two shows the viewer: choosing it in one gives the other back its folder.
    public mutating func setViewer(_ group: PaneGroup, _ viewer: PaneViewer?) {
        self[group].viewer = viewer
        self[group].kept.insert(.view)
        guard viewer != nil else { return }
        switch group {
        case .left: right.viewer = nil
        case .right: left.viewer = nil
        case .onePane, .activePane: break
        }
    }

    /// The divider as Save keeps it.
    public var dividerKept: TabViewKeeps.Divider {
        switch divider {
        case .even: .even
        case .shareNow: .share(shareNow)
        case .widthNow: .leftWidth(widthNow)
        case .saved: savedDivider ?? .share(shareNow)
        case .custom: .share(customShare)
        }
    }

    /// What Save saves.
    public var keeps: TabViewKeeps {
        let two = keepsPanes && panes == 2
        return TabViewKeeps(
            panes: keepsPanes ? panes : nil, divider: two && keepsDivider ? dividerKept : nil,
            includeHidden: keepsHidden ? hidden : nil, left: two ? left.keeps(viewerAllowed: true) : nil,
            right: two ? right.keeps(viewerAllowed: true) : nil, pane: two ? nil : active.keeps(viewerAllowed: false))
    }

    /// Reset: nothing kept, each value left as it shows.
    public mutating func reset() {
        keepsPanes = false
        keepsDivider = false
        keepsHidden = false
        for group in [PaneGroup.left, .right, .activePane] {
            var pane = self[group]
            pane.keepsFolder = false
            pane.kept = []
            pane.folderViews = .folderFirst
            self[group] = pane
        }
    }
}

/// What the tab views and window views say of themselves.
public enum SavedViewText {
    /// What a tab view keeps, a part for each: "Two panes", "Divider 62% / 38%", "Left: List", "Left: opens
    /// Downloads"; "Folders from the tab" when it opens none.
    public static func parts(_ keeps: TabViewKeeps) -> [String] {
        var parts: [String] = []
        if let panes = keeps.panes { parts.append(panes == 2 ? "Two panes" : "One pane") }
        if let divider = keeps.divider { parts.append("Divider " + dividerText(divider)) }
        if let hidden = keeps.includeHidden { parts.append(hidden ? "Hidden files shown" : "Hidden files hidden") }
        parts += paneParts(keeps.left, "Left: ") + paneParts(keeps.right, "Right: ")
        parts += paneParts(keeps.pane, keeps.panes == nil ? "Active pane: " : "")
        if keeps.folders.isEmpty { parts.append("Folders from the tab") }
        return parts
    }

    /// A divider as the sheet and the list say it.
    public static func dividerText(_ divider: TabViewKeeps.Divider) -> String {
        switch divider {
        case .even: "even"
        case .share(let share):
            "\(Int((share * 100).rounded()))% / \(100 - Int((share * 100).rounded()))%"
        case .leftWidth(let width): "left pane \(Int(width)) pt"
        }
    }

    private static func paneParts(_ pane: PaneKeeps?, _ prefix: String) -> [String] {
        guard let pane else { return [] }
        if let viewer = pane.viewer {
            return [
                prefix + (viewer.follows ? "Viewer, following the selection" : "Viewer, on the file selected"),
                prefix + (viewer.editing ? "edit" : "read"),
            ]
        }
        var parts: [String] = []
        if let folder = pane.folder { parts.append(prefix + "opens \u{201C}\(NodePath.basename(folder))\u{201D}") }
        let view = pane.view
        if let mode = view.view { parts.append(prefix + mode.menuName) }
        if let groupBy = view.groupBy {
            parts.append(prefix + (groupBy == .none ? "no groups" : "grouped by \(groupBy.title.lowercased())"))
        }
        if let sort = view.sort { parts.append(prefix + "by \(sort.by.title.lowercased())") }
        if let first = view.foldersFirst { parts.append(prefix + (first ? "folders first" : "folders mixed in")) }
        if view.columns != nil { parts.append(prefix + "columns") }
        if view.size != nil { parts.append(prefix + "sizes") }
        switch pane.choice {
        case .folderFirst: break
        case .tabViewFirst: parts.append(prefix + "over folder views")
        case .notUsed: parts.append(prefix + "folder views not used")
        }
        return parts
    }
}
