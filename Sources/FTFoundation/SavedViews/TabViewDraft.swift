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

    /// One pane's rows: its folder, the settings with their values and whether each is kept, each view's size, the
    /// viewer's rows and its search results' view.
    public struct Pane: Equatable, Sendable {
        public var keepsFolder: Bool
        public var folder: String?
        /// Every setting set: the value each row shows. Its sizes are every view's.
        public var values: FolderViewKeeps
        /// The settings kept, never Size: each view's size is kept apart, in `sizesKept`.
        public var kept: Set<FolderViewSetting>
        public var sizesKept: Set<ViewSizeKind>
        /// Opens the Viewer, over the pane's own list.
        public var opensViewer: Bool
        /// The viewer's Follow and Read or Edit as the rows show them, and whether each is kept.
        public var viewer: PaneViewer
        public var keepsFollows: Bool
        public var keepsEditing: Bool
        /// How the pane shows search results, as it does now or as the tab view being edited keeps it; kept whole
        /// where checked.
        public var keepsSearchResults: Bool
        public var searchResults: SearchResultsKeeps

        public init(state: PaneState, keeps: PaneKeeps?) {
            keepsFolder = keeps?.folder != nil
            folder = keeps?.folder ?? state.folder
            var values = state.settings
            for setting in keeps?.view.kept ?? [] { values.take(setting, from: keeps?.view ?? FolderViewKeeps()) }
            if let sizes = keeps?.sizes, let now = values.size { values.size = sizes.applied(to: now) }
            self.values = values
            kept = Set(keeps?.view.kept ?? []).subtracting([.size])
            sizesKept = Set(keeps?.sizes?.kept ?? [])
            opensViewer = keeps?.opensViewer == true
            viewer = PaneViewer(
                follows: keeps?.viewerFollows ?? state.viewerDefaults.follows,
                editing: keeps?.viewerEditing ?? state.viewerDefaults.editing)
            keepsFollows = keeps?.viewerFollows != nil
            keepsEditing = keeps?.viewerEditing != nil
            keepsSearchResults = keeps?.searchResults != nil
            searchResults = keeps?.searchResults ?? state.searchResults
        }

        /// What it keeps: the folder where checked, each setting and each view's size checked with its value, the
        /// viewer's rows where checked.
        public var keeps: PaneKeeps {
            var view = FolderViewKeeps()
            for setting in FolderViewSetting.allCases where kept.contains(setting) && setting != .size {
                view.take(setting, from: values)
            }
            let sizes = values.size.map { ViewSizesKeeps($0, only: sizesKept) }
            return PaneKeeps(
                folder: keepsFolder ? folder : nil, view: view, sizes: sizes,
                opensViewer: opensViewer, viewerFollows: keepsFollows ? viewer.follows : nil,
                viewerEditing: keepsEditing ? viewer.editing : nil,
                searchResults: keepsSearchResults ? searchResults : nil)
        }

        /// Keep `setting` or not.
        public mutating func keep(_ setting: FolderViewSetting, _ on: Bool) {
            if on { kept.insert(setting) } else { kept.remove(setting) }
        }

        /// Keep `size` or not.
        public mutating func keep(_ size: ViewSizeKind, _ on: Bool) {
            if on { sizesKept.insert(size) } else { sizesKept.remove(size) }
        }

        /// A value chosen in a row: it is kept from then on, as choosing in Folder View Options keeps it.
        public mutating func set(_ setting: FolderViewSetting, _ change: (inout FolderViewKeeps) -> Void) {
            change(&values)
            kept.insert(setting)
        }

        /// A size chosen for a view at `density`: kept from then on.
        public mutating func set(_ size: ViewSizeKind, _ value: Int, at density: Density) {
            values.size?[size][density] = value
            sizesKept.insert(size)
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
    /// With one pane kept: the second pane the tab keeps closed is forgotten.
    public var forgetsSecondPane: Bool
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
            && lhs.panes == rhs.panes && lhs.forgetsSecondPane == rhs.forgetsSecondPane
            && lhs.keepsDivider == rhs.keepsDivider && lhs.divider == rhs.divider
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
            forgetsSecondPane = keeps.forgetsSecondPane == true
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
            forgetsSecondPane = false
            let viewOnly = { (state: PaneState) in
                PaneKeeps(
                    view: FolderViewKeeps(view: state.settings.view),
                    opensViewer: state.viewer != nil || state.viewerInPlace)
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

    /// Opens the Viewer for a pane group, or not: in any pane, each on its own.
    public mutating func setOpensViewer(_ group: PaneGroup, _ on: Bool) {
        self[group].opensViewer = on
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
            panes: keepsPanes ? panes : nil, forgetsSecondPane: keepsPanes && panes == 1 && forgetsSecondPane,
            divider: two && keepsDivider ? dividerKept : nil,
            includeHidden: keepsHidden ? hidden : nil, left: two ? left.keeps : nil, right: two ? right.keeps : nil,
            pane: two ? nil : active.keeps)
    }

    /// Reset: nothing kept, each value left as it shows.
    public mutating func reset() {
        keepsPanes = false
        forgetsSecondPane = false
        keepsDivider = false
        keepsHidden = false
        for group in [PaneGroup.left, .right, .activePane] {
            var pane = self[group]
            pane.keepsFolder = false
            pane.kept = []
            pane.sizesKept = []
            pane.opensViewer = false
            pane.keepsFollows = false
            pane.keepsEditing = false
            pane.keepsSearchResults = false
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
        if keeps.forgetsSecondPane == true { parts.append("Second pane forgotten") }
        if let divider = keeps.divider { parts.append("Divider " + dividerText(divider)) }
        if let hidden = keeps.includeHidden { parts.append(hidden ? "Hidden files shown" : "Hidden files hidden") }
        parts += paneParts(keeps.left, "Left: ") + paneParts(keeps.right, "Right: ")
        parts += paneParts(keeps.pane, keeps.panes == nil ? "Active pane: " : "")
        if keeps.folders.isEmpty { parts.append("Folders from the tab") }
        return parts
    }

    /// A view's size as the list of tab views says it.
    public static func sizeName(_ size: ViewSizeKind) -> String {
        switch size {
        case .icons: "icon size"
        case .compactList: "column width"
        case .previews: "previews at a time"
        }
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
        var parts: [String] = []
        if let folder = pane.folder { parts.append(prefix + "opens \u{201C}\(NodePath.basename(folder))\u{201D}") }
        let view = pane.view
        if let mode = view.view { parts.append(prefix + mode.menuName) }
        if pane.opensViewer == true { parts.append(prefix + "viewer") }
        if let follows = pane.viewerFollows {
            parts.append(prefix + (follows ? "viewer follows the selection" : "viewer stays on its file"))
        }
        if let editing = pane.viewerEditing { parts.append(prefix + (editing ? "edit" : "read")) }
        if let groupBy = view.groupBy {
            parts.append(prefix + (groupBy == .none ? "no groups" : "grouped by \(groupBy.title.lowercased())"))
        }
        if let sort = view.sort { parts.append(prefix + "by \(sort.by.title.lowercased())") }
        if let first = view.foldersFirst { parts.append(prefix + (first ? "folders first" : "folders mixed in")) }
        if view.columns != nil { parts.append(prefix + "columns") }
        for size in pane.sizes?.kept ?? [] { parts.append(prefix + sizeName(size)) }
        if let results = pane.searchResults { parts.append(prefix + "search view: " + results.summary) }
        return parts
    }
}
