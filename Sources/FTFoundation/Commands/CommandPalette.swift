// The command palette's list: every command, matched to what is typed and put in order
import Foundation

/// How a command of the palette runs.
public enum CommandPaletteRun: Equatable, Sendable, Hashable {
    /// As a click on the menu item with this id: the window's commands, About, Settings, a workspace.
    case menuItem(String)
    /// As the window runs a key of its own that no menu item has: the page moves, Open Selected Item.
    case windowKey(ShortcutCommandID)
    /// As one of the system's own menu items.
    case system(CommandPaletteSystemItem)
}

/// The system's own menu items, which AppKit carries out through the responder chain.
public enum CommandPaletteSystemItem: String, CaseIterable, Sendable, Hashable {
    case closeWindow, minimize, zoom, fullScreen, bringAllToFront, hide, hideOthers, showAll, quit
}

/// One command as the palette lists it.
public struct CommandPaletteEntry: Equatable, Sendable, Identifiable {
    /// What the recent commands keep: the table's id, or the menu item's for a command not in the table.
    public var id: String
    public var title: String
    /// Where the menus have it ("View > Sort By"); nil for a command only keys run.
    public var place: String?
    /// The main key, one part for each key: ["⇧", "⌘", "P"]; empty for a command with none.
    public var keys: [String]
    /// Whether it can run now; a dimmed command is listed after the others and beeps.
    public var enabled: Bool
    /// What it toggles or chooses is on (Hidden Files, the view in use).
    public var checked: Bool
    public var group: ShortcutGroup
    public var icon: CommandIcon?
    public var run: CommandPaletteRun
    /// What it does, in a line: Help's line for it, shown under the list while it is selected.
    public var help: String

    public init(
        id: String, title: String, place: String?, keys: [String], enabled: Bool = true, checked: Bool = false,
        group: ShortcutGroup, icon: CommandIcon? = nil, run: CommandPaletteRun, help: String = ""
    ) {
        self.help = help
        self.id = id
        self.title = title
        self.place = place
        self.keys = keys
        self.enabled = enabled
        self.checked = checked
        self.group = group
        self.icon = icon
        self.run = run
    }
}

/// A row of the palette: the entry, and the letters of its title to mark.
public struct CommandPaletteRow: Equatable, Sendable {
    public var entry: CommandPaletteEntry
    /// In the title's UTF-16 units.
    public var marks: [HighlightRange]

    public init(entry: CommandPaletteEntry, marks: [HighlightRange] = []) {
        self.entry = entry
        self.marks = marks
    }
}

/// A run of rows under a heading; the rows matching typed text have none.
public struct CommandPaletteSection: Equatable, Sendable {
    public var title: String?
    public var rows: [CommandPaletteRow]

    public init(title: String?, rows: [CommandPaletteRow]) {
        self.title = title
        self.rows = rows
    }
}

/// A saved workspace, as the palette names it.
public struct CommandPaletteWorkspace: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the palette lists and how it orders it. Every row of the shortcut table is a command of the palette, and so are
/// the menu items that aren't in it; `docs/process/commands.md` says what a new command needs.
public enum CommandPalette {
    /// How many recent commands are kept.
    public static let recentLimit = 20
    /// How many of them are listed while nothing is typed.
    public static let recentShown = 5
    public static let recentTitle = "Recently Used"
    public static let placeholder = "Type a command"

    // MARK: What is listed

    /// Rows of the table the palette leaves out, each with why.
    public static let excludedCommands: Set<ShortcutCommandID> = [
        // The palette itself.
        .showCommandPalette,
        // Workspace 1 to 5, in and not in this window: the palette lists every workspace by its name instead.
        .openWorkspace1, .openWorkspace2, .openWorkspace3, .openWorkspace4, .openWorkspace5,
        .openWorkspace1InThisWindow, .openWorkspace2InThisWindow, .openWorkspace3InThisWindow,
        .openWorkspace4InThisWindow, .openWorkspace5InThisWindow,
    ]

    /// Menu items with no row in the table that the palette leaves out: Services is the system's own submenu of other
    /// apps' services.
    public static let excludedMenuItems: Set<String> = ["Services"]

    /// The commands whose menu title names what they act on, or changes with what is on: the palette shows the menu's
    /// title in place of the table's label.
    public static let menuTitledCommands: Set<ShortcutCommandID> = [
        .undo, .redo, .toggleFavorite, .toggleFolderTree, .pasteAsFile, .copyContents, .compressSelection,
        .convertImages, .increaseSize, .decreaseSize, .resetSize, .editSelection, .goMacintoshHD, .closePane,
    ]

    /// A menu item with no row in the table.
    public struct MenuItem: Equatable, Sendable {
        public var id: String
        public var title: String
        public var place: String
        public var group: ShortcutGroup
        public var run: CommandPaletteRun
        public var icon: CommandIcon?
        /// What it does, in a line, as Help says it of the commands in the table.
        public var help: String
    }

    /// The menu items with no row in the table, in the menus' order. The id of a system item is its title, as the
    /// menu gives it none.
    public static let menuItems: [MenuItem] = [
        MenuItem(
            id: "about", title: "About File Trail", place: "File Trail", group: .standard, run: .menuItem("about"),
            help: "Show File Trail's version"),
        MenuItem(
            id: "Show All", title: "Show All", place: "File Trail", group: .standard, run: .system(.showAll),
            help: "Show the windows of every app that was hidden"),
        MenuItem(
            id: "Zoom", title: "Zoom", place: "Window", group: .standard, run: .system(.zoom),
            help: "Make the window as large as the screen allows, or as it was"),
        MenuItem(
            id: ApplicationMenu.manageWorkspacesItemID, title: "Manage Workspaces…", place: "Window > Workspaces",
            group: .tabs, run: .menuItem(ApplicationMenu.manageWorkspacesItemID),
            help: "Rename, remove or reorder the saved workspaces, in Settings"),
        MenuItem(
            id: "Bring All to Front", title: "Bring All to Front", place: "Window", group: .standard,
            run: .system(.bringAllToFront), help: "Bring every File Trail window in front of other apps' windows"),
    ]

    /// How a row of the table runs from the palette; nil for one it leaves out.
    public static func run(of id: ShortcutCommandID) -> CommandPaletteRun? {
        if excludedCommands.contains(id) { return nil }
        switch id {
        case .cut: return .menuItem(AppCommand.editCut.rawValue)
        case .copy: return .menuItem(AppCommand.editCopy.rawValue)
        case .paste: return .menuItem(AppCommand.editPaste.rawValue)
        case .selectAll: return .menuItem(AppCommand.editSelectAll.rawValue)
        case .settings: return .menuItem("settings")
        case .closeWindow: return .system(.closeWindow)
        case .minimize: return .system(.minimize)
        case .fullScreen: return .system(.fullScreen)
        case .hide: return .system(.hide)
        case .hideOthers: return .system(.hideOthers)
        case .quit: return .system(.quit)
        case .pageUp, .pageDown, .halfPageUp, .halfPageDown, .openSelectedItem: return .windowKey(id)
        default:
            return AppCommand(rawValue: id.rawValue).map { .menuItem($0.rawValue) }
        }
    }

    /// Where a table row's `menuPath` puts it: the path without the item's own name.
    public static func place(_ menuPath: String?) -> String? {
        guard let menuPath else { return nil }
        let parts = menuPath.components(separatedBy: " > ")
        guard parts.count > 1 else { return nil }
        // "Window > Workspaces, with Option" names a variant, not a place.
        return parts.dropLast().joined(separator: " > ").components(separatedBy: ",")[0]
    }

    /// Where the menus have the standard commands, whose table rows name no place (their keys are the same in every
    /// app).
    public static let standardPlaces: [ShortcutCommandID: String] = [
        .undo: "Edit", .redo: "Edit", .cut: "Edit", .copy: "Edit", .paste: "Edit", .selectAll: "Edit",
        .settings: "File Trail", .hide: "File Trail", .hideOthers: "File Trail", .quit: "File Trail",
        .closeWindow: "File", .minimize: "Window", .fullScreen: "View",
    ]

    /// The main key of a command, in parts.
    static func keys(_ bindings: ShortcutBindings, _ id: ShortcutCommandID) -> [String] {
        bindings[id]?.first.map(ShortcutLabels.parts) ?? []
    }

    /// Every command of the palette, in the table's order with the other menu items after their group, and the
    /// workspaces after Window's.
    ///
    /// - Parameters:
    ///   - bindings: the keys as Settings has them.
    ///   - states: what `ApplicationMenu.itemStates` says of each menu item, by id, for the window the palette opens
    ///     over: dimmed, checked, its title. A command it says nothing of can run.
    ///   - menuTitles: the menu items' titles as the menu shows them now, by id (the text editor, the startup disk, a
    ///     workspace).
    ///   - workspaces: the saved workspaces in their order.
    ///   - templates: the files of the Templates folder File ▸ New File lists, in its order.
    public static func entries(
        bindings: ShortcutBindings, states: [String: ApplicationMenuItemState], menuTitles: [String: String] = [:],
        workspaces: [CommandPaletteWorkspace] = [], templates: [String] = []
    ) -> [CommandPaletteEntry] {
        var result: [CommandPaletteEntry] = []
        // In a tab with one pane the menu names Close Pane "Close Tab", as that is what it closes: Close Tab, which
        // would do the same there, is not listed a second time under the same name.
        let closePaneClosesTab =
            menuTitles[ShortcutCommandID.closePane.rawValue] == ShortcutCommands.definition(.closeTab).label
        for definition in ShortcutCommands.all {
            guard let run = run(of: definition.id) else { continue }
            if definition.id == .closeTab, closePaneClosesTab { continue }
            let itemID: String? = if case .menuItem(let id) = run { id } else { nil }
            let state = itemID.flatMap { states[$0] }
            let menuTitle = menuTitledCommands.contains(definition.id) ? itemID.flatMap { menuTitles[$0] } : nil
            result.append(
                CommandPaletteEntry(
                    id: definition.id.rawValue, title: menuTitle ?? definition.label,
                    place: place(definition.menuPath) ?? standardPlaces[definition.id],
                    keys: keys(bindings, definition.id),
                    enabled: state?.enabled ?? true, checked: state?.checked ?? false, group: definition.group,
                    icon: icon(definition.id), run: run,
                    help: HelpContent.line(of: definition.id) ?? ""))
        }
        // A template is on where New File ▸ Text File is, as in the menu.
        let newFileState = states[AppCommand.newTextFile.rawValue]
        for name in templates {
            let itemID = ApplicationMenu.templateItemID(name)
            result.append(
                CommandPaletteEntry(
                    id: itemID, title: "New File \u{201C}\(name)\u{201D}", place: "File > New File", keys: [],
                    enabled: newFileState?.enabled ?? true, group: .files, icon: .newFile, run: .menuItem(itemID),
                    help: "Make a copy of this template in the folder you are in, and name it"))
        }
        for (index, workspace) in workspaces.enumerated() {
            for inThisWindow in [false, true] {
                let itemID = ApplicationMenu.workspaceItemID(workspace.id, inThisWindow: inThisWindow)
                let slots = inThisWindow ? Workspaces.inThisWindowSlotCommands : Workspaces.slotCommands
                let name = "Workspace \u{201C}\(workspace.name)\u{201D}"
                result.append(
                    CommandPaletteEntry(
                        id: itemID, title: inThisWindow ? "\(name) in This Window" : name,
                        place: "Window > Workspaces",
                        keys: slots.indices.contains(index) ? keys(bindings, slots[index]) : [],
                        enabled: states[itemID]?.enabled ?? true, group: .tabs, run: .menuItem(itemID),
                        help: inThisWindow
                            ? "Open the workspace as it was saved, in place of this window"
                            : "Open the workspace as it was saved, in a new window"))
            }
        }
        for item in menuItems {
            result.append(
                CommandPaletteEntry(
                    id: item.id, title: item.title, place: item.place, keys: [],
                    enabled: states[item.id]?.enabled ?? true, group: item.group, icon: item.icon, run: item.run,
                    help: item.help))
        }
        // In the groups' order, each keeping its own.
        let groups = ShortcutGroup.allCases
        return result.enumerated().sorted { left, right in
            let a = groups.firstIndex(of: left.element.group) ?? 0
            let b = groups.firstIndex(of: right.element.group) ?? 0
            return a != b ? a < b : left.offset < right.offset
        }.map(\.element)
    }

    // MARK: Matching and order

    /// The rows for what is typed. With nothing typed: the recent commands that are listed, then every command under
    /// its group. With text: the commands whose title has its letters in order, then those whose place and title hold
    /// each word typed, the ones that can run first, the best fit first. Among those that fit alike, the command named
    /// just what was typed comes first ("copy" is Copy, not Copy to Other Pane), then the most recently run, then the
    /// table's order, but for a command whose whole name begins another's, which comes before it ("dup" is Duplicate
    /// before Duplicate Tab).
    public static func sections(_ entries: [CommandPaletteEntry], query: String, recent: [String])
        -> [CommandPaletteSection]
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let matcher = NameMatcher(trimmed, mode: .fuzzy) else {
            return browsingSections(entries, recent: recent)
        }
        let words = trimmed.split(whereSeparator: { $0 == " " }).compactMap {
            NameMatcher(String($0), mode: .contains)
        }
        struct Hit {
            var row: CommandPaletteRow
            var score: Int
            var order: Int
            var isNamedSo = false
        }
        /// A title as it is compared with what was typed: without the "…" of a command that asks more.
        func name(_ title: String) -> String {
            title.hasSuffix("\u{2026}") ? String(title.dropLast()) : title
        }
        let exact = NameMatcher(trimmed, mode: .contains)
        var hits: [Hit] = []
        for (order, entry) in entries.enumerated() {
            if let score = matcher.score(entry.title) {
                hits.append(
                    Hit(
                        row: CommandPaletteRow(entry: entry, marks: matcher.marks(in: entry.title)), score: score,
                        order: order,
                        isNamedSo: name(entry.title).count == trimmed.count
                            && exact?.isContained(in: entry.title) == true))
                continue
            }
            // Below every title that fits: each word in the place or the title.
            guard let place = entry.place, !words.isEmpty else { continue }
            let text = place + " " + entry.title
            guard words.allSatisfy({ $0.isContained(in: text) }) else { continue }
            let marks = words.flatMap { $0.isContained(in: entry.title) ? $0.marks(in: entry.title) : [] }
            hits.append(
                Hit(row: CommandPaletteRow(entry: entry, marks: merged(marks)), score: Int.min / 2, order: order))
        }
        let recency = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        hits.sort { left, right in
            if left.row.entry.enabled != right.row.entry.enabled { return left.row.entry.enabled }
            if left.score != right.score { return left.score > right.score }
            if left.isNamedSo != right.isNamedSo { return left.isNamedSo }
            let a = recency[left.row.entry.id] ?? Int.max
            let b = recency[right.row.entry.id] ?? Int.max
            if a != b { return a < b }
            return left.order < right.order
        }
        // A command whose whole name begins another's comes before it where the two fit alike and neither was run
        // more recently: "dup" is Duplicate before Duplicate Tab, "open" Open before Open in New Tab.
        func alike(_ a: Hit, _ b: Hit) -> Bool {
            a.row.entry.enabled == b.row.entry.enabled && a.score == b.score
                && recency[a.row.entry.id] == recency[b.row.entry.id]
        }
        var at = 0
        while at < hits.count {
            let longer = name(hits[at].row.entry.title)
            let shorter = hits.indices.dropFirst(at + 1).first { index in
                alike(hits[at], hits[index]) && longer.hasPrefix(name(hits[index].row.entry.title) + " ")
            }
            if let shorter {
                hits.insert(hits.remove(at: shorter), at: at)
            } else {
                at += 1
            }
        }
        return [CommandPaletteSection(title: nil, rows: hits.map(\.row))]
    }

    private static func browsingSections(_ entries: [CommandPaletteEntry], recent: [String])
        -> [CommandPaletteSection]
    {
        var sections: [CommandPaletteSection] = []
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recentRows = recent.compactMap { byID[$0] }.prefix(recentShown).map { CommandPaletteRow(entry: $0) }
        if !recentRows.isEmpty {
            sections.append(CommandPaletteSection(title: recentTitle, rows: Array(recentRows)))
        }
        for group in ShortcutGroup.allCases {
            let rows = entries.filter { $0.group == group }.map { CommandPaletteRow(entry: $0) }
            if !rows.isEmpty { sections.append(CommandPaletteSection(title: group.label, rows: rows)) }
        }
        return sections
    }

    /// Marks that touch or overlap are one.
    private static func merged(_ marks: [HighlightRange]) -> [HighlightRange] {
        var result: [HighlightRange] = []
        for mark in marks.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end >= mark.start {
                result[result.count - 1].end = max(last.end, mark.end)
            } else {
                result.append(mark)
            }
        }
        return result
    }

    // MARK: Recent commands

    /// The recent commands with `id` run just now: first, once, the oldest let go of past the limit.
    public static func remembering(_ id: String, in recent: [String]) -> [String] {
        Array(([id] + recent.filter { $0 != id }).prefix(recentLimit))
    }

    /// The recent commands as read from their file: strings, each once, the first `recentLimit`.
    public static func sanitizeRecent(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for case let id as String in list where !id.isEmpty && seen.insert(id).inserted {
            result.append(id)
            if result.count == recentLimit { break }
        }
        return result
    }

    // MARK: Symbols

    /// The command's symbol, where the toolbar or the right-click menus have one for it.
    public static func icon(_ id: ShortcutCommandID) -> CommandIcon? {
        switch id {
        case .goBack: .back
        case .goForward: .forward
        case .goEnclosingFolder: .up
        case .openLocationSheet: .goTo
        case .refreshOrApplySearchSort: .refresh
        case .newTab, .openSelectionInNewTab: .newTab
        case .openSelectionInNewWindow: .openInNewWindow
        case .rootTreeAtSelection: .rootTreeHere
        case .toggleTwoPanes: .twoPanes
        case .duplicatePane: .duplicatePane
        case .openSelection, .openSelectedItem: .open
        case .editSelection: .edit
        case .quickLookSelection: .quickLook
        case .calculateSize: .calculateSize
        case .renameSelection: .rename
        case .duplicateSelection: .duplicate
        case .convertImages: .convertImages
        case .moveSelection, .moveToOtherPane: .move
        case .compressSelection: .compress
        case .extractSelection, .extractSelectionTo: .extract
        case .newFolder, .newFolderWithSelection: .newFolder
        case .pasteAsFile: .pasteAsFile
        case .newTextFile, .saveAsTemplate: .newFile
        case .trashSelection: .trash
        case .ejectVolume: .eject
        case .emptyTrash: .emptyTrash
        case .copyPath: .copyPath
        case .copyContents: .copyContents
        case .shareSelection: .share
        case .openInTerminal: .terminal
        case .showInFinder: .showInFinder
        case .toggleFavorite: .favorite
        case .focusFileSearch, .showLastSearchResults: .search
        case .revealInFolder: .revealInFolder
        case .viewAsIcons: .icons
        case .viewAsDetails: .details
        case .viewAsList: .list
        case .viewAsPreviews, .showPreviews9, .showPreviews4, .showPreviews2, .showPreviews1: .previews
        case .sortByName, .sortByKind, .sortByModified, .sortByCreated, .sortByAdded, .sortByLastOpened, .sortBySize:
            .sortBy
        case .groupByNone, .groupByName, .groupByModified, .groupByCreated, .groupByLastOpened, .groupByAdded,
            .groupBySize, .groupByKind, .groupByTags, .groupByFolder, .reverseGroupOrder:
            .groupBy
        case .toggleFoldersFirst: .foldersFirst
        case .folderViewOptions: .folderView
        case .toggleHiddenFiles: .hiddenShown
        case .toggleFolderTree: .folderTree
        case .toggleInfoPanel: .infoPanel
        case .toggleInfoRow: .infoRow
        case .openHelp, .openKeyboardShortcuts: .help
        case .undo: .undo
        case .redo: .redo
        case .cut: .cut
        case .copy, .copyToOtherPane: .copy
        case .paste: .paste
        case .settings: .settings
        default: nil
        }
    }
}
