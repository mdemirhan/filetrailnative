import Foundation

/// The six settings a folder's view can keep (View ▸ Folder View), in the order Folder Customization lists them.
public enum FolderViewSetting: String, CaseIterable, Sendable, Hashable {
    case view, groupBy, sort, foldersFirst, columns, size

    /// What Folder View Options calls it, and the unsaved changes popover.
    public var label: String {
        switch self {
        case .view: "View"
        case .groupBy: "Group By"
        case .sort: "Sort"
        case .foldersFirst: "Folders First"
        case .columns: "Columns"
        case .size: "Size"
        }
    }
}

/// An order: the field and its direction, kept together.
public struct FolderViewSort: Codable, Equatable, Sendable {
    public var by: SortByPreference
    public var direction: SortDirectionPreference

    public init(by: SortByPreference, direction: SortDirectionPreference) {
        self.by = by
        self.direction = direction
    }
}

/// The List's columns: which are shown, in what order (hidden ones keep their place), and their widths.
public struct FolderViewColumns: Codable, Equatable, Sendable {
    public var visibility: DetailColumnVisibility
    public var order: [OptionalDetailColumnKey]
    public var widths: DetailColumnWidths

    public init(visibility: DetailColumnVisibility, order: [OptionalDetailColumnKey], widths: DetailColumnWidths) {
        self.visibility = visibility
        self.order = order
        self.widths = widths
    }

    /// Read column by column, as the app's own columns are: a column the file doesn't have (one added since it was
    /// written) is as it first is, and one the app doesn't know is passed over, so a new column costs no folder the
    /// columns it keeps.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var visibility = DetailColumnVisibility.defaults
        if let saved = try? container.nestedContainer(keyedBy: FolderViewFileKey.self, forKey: .visibility) {
            for key in OptionalDetailColumnKey.allCases {
                if let shown = try? saved.decode(Bool.self, forKey: FolderViewFileKey(key.rawValue)) {
                    visibility[key] = shown
                }
            }
        }
        var order: [OptionalDetailColumnKey] = []
        for name in (try? container.decode([String].self, forKey: .order)) ?? [] {
            if let key = OptionalDetailColumnKey(rawValue: name), !order.contains(key) { order.append(key) }
        }
        order += OptionalDetailColumnKey.menuOrder.filter { !order.contains($0) }
        var widths = DetailColumnWidths.defaults
        if let saved = try? container.nestedContainer(keyedBy: FolderViewFileKey.self, forKey: .widths) {
            for key in DetailColumnKey.allCases {
                if let width = try? saved.decode(Double.self, forKey: FolderViewFileKey(key.rawValue)) {
                    widths[key] = AppPreferenceLimits.clampDetailColumnWidth(key, width)
                }
            }
        }
        self.init(visibility: visibility, order: order, widths: widths)
    }
}

/// A key of `folder-views.json` read by its name: a column's, or a density's.
private struct FolderViewFileKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// The three sizes, each at both densities: kept together, as Make Bigger changes the one of the view on screen.
public struct FolderViewSizes: Codable, Equatable, Sendable {
    public var iconSizes: DensitySizes
    public var compactListWidths: DensitySizes
    public var previewCounts: DensitySizes

    public init(iconSizes: DensitySizes, compactListWidths: DensitySizes, previewCounts: DensitySizes) {
        self.iconSizes = iconSizes
        self.compactListWidths = compactListWidths
        self.previewCounts = previewCounts
    }

    /// Read size by size and density by density, each checked as the app's own sizes are; one the file doesn't have
    /// is as it first is.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func sizes(_ key: CodingKeys, _ defaults: DensitySizes, _ valid: (Double) -> Int) -> DensitySizes {
            var sizes = defaults
            guard let saved = try? container.nestedContainer(keyedBy: FolderViewFileKey.self, forKey: key) else {
                return sizes
            }
            for density in Density.allCases {
                if let size = try? saved.decode(Double.self, forKey: FolderViewFileKey(density.rawValue)) {
                    sizes[density] = valid(size)
                }
            }
            return sizes
        }
        self.init(
            iconSizes: sizes(.iconSizes, .iconDefaults) { AppPreferenceLimits.clampIconSize($0) },
            compactListWidths: sizes(.compactListWidths, .compactListDefaults) {
                AppPreferenceLimits.clampPaneWidth($0, AppPreferenceLimits.compactListWidthRange)
            },
            previewCounts: sizes(.previewCounts, .previewCountDefaults) { PreviewGrid.valid(read: $0) })
    }
}

/// What a folder's view keeps: a setting that is nil is not kept, and follows the pane.
public struct FolderViewKeeps: Codable, Equatable, Sendable {
    public var view: ExplorerViewMode?
    public var groupBy: GroupByPreference?
    public var sort: FolderViewSort?
    public var foldersFirst: Bool?
    public var columns: FolderViewColumns?
    public var size: FolderViewSizes?

    public init(
        view: ExplorerViewMode? = nil, groupBy: GroupByPreference? = nil, sort: FolderViewSort? = nil,
        foldersFirst: Bool? = nil, columns: FolderViewColumns? = nil, size: FolderViewSizes? = nil
    ) {
        self.view = view
        // Folder is search results' own: a folder's view can't keep it.
        self.groupBy = groupBy?.isForFolders == false ? nil : groupBy
        self.sort = sort
        self.foldersFirst = foldersFirst
        self.columns = columns
        self.size = size
    }

    /// Each setting is read on its own: one that can't be read (a view or a field the app doesn't know) is not
    /// kept, and the others are.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            view: try? container.decode(ExplorerViewMode.self, forKey: .view),
            groupBy: try? container.decode(GroupByPreference.self, forKey: .groupBy),
            sort: try? container.decode(FolderViewSort.self, forKey: .sort),
            foldersFirst: try? container.decode(Bool.self, forKey: .foldersFirst),
            columns: try? container.decode(FolderViewColumns.self, forKey: .columns),
            size: try? container.decode(FolderViewSizes.self, forKey: .size))
    }

    public var isEmpty: Bool { kept.isEmpty }

    /// The settings kept, in the order Folder View Options lists them.
    public var kept: [FolderViewSetting] { FolderViewSetting.allCases.filter(keeps) }

    public func keeps(_ setting: FolderViewSetting) -> Bool {
        switch setting {
        case .view: view != nil
        case .groupBy: groupBy != nil
        case .sort: sort != nil
        case .foldersFirst: foldersFirst != nil
        case .columns: columns != nil
        case .size: size != nil
        }
    }

    /// Takes `setting` from `other`: kept there, kept here with its value; not kept there, not kept here.
    public mutating func take(_ setting: FolderViewSetting, from other: FolderViewKeeps) {
        switch setting {
        case .view: view = other.view
        case .groupBy: groupBy = other.groupBy
        case .sort: sort = other.sort
        case .foldersFirst: foldersFirst = other.foldersFirst
        case .columns: columns = other.columns
        case .size: size = other.size
        }
    }

    public mutating func forget(_ setting: FolderViewSetting) {
        take(setting, from: FolderViewKeeps())
    }

    /// The settings kept here or in `other` that differ: kept in one only, or with another value.
    public func differences(from other: FolderViewKeeps) -> [FolderViewSetting] {
        FolderViewSetting.allCases.filter { setting in
            guard keeps(setting) || other.keeps(setting) else { return false }
            var mine = FolderViewKeeps()
            mine.take(setting, from: self)
            var theirs = FolderViewKeeps()
            theirs.take(setting, from: other)
            return mine != theirs
        }
    }
}

/// One folder's view: where the folder is, whether its view covers the folders inside, and what it keeps. The path
/// alone says whose it is, so finding a folder's view asks nothing of the disk.
public struct FolderView: Codable, Equatable, Sendable {
    /// The folder's full path, as its listing gives it (links resolved).
    public var path: String
    /// Whether the folders inside with no view of their own use this one.
    public var subfolders: Bool
    public var keeps: FolderViewKeeps

    public init(path: String, subfolders: Bool = false, keeps: FolderViewKeeps = FolderViewKeeps()) {
        self.path = path
        self.subfolders = subfolders
        self.keeps = keeps
    }

    /// Only the path is needed; what else the file has for a view and the app doesn't use (a disk and a file ID,
    /// in a file that kept them) is passed over.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            subfolders: (try? container.decode(Bool.self, forKey: .subfolders)) ?? false,
            keeps: (try? container.decode(FolderViewKeeps.self, forKey: .keeps)) ?? FolderViewKeeps())
    }

    /// A view that keeps nothing and covers nothing does nothing, and is not kept.
    public var isEmpty: Bool { keeps.isEmpty && !subfolders }
}

/// The view a folder uses, and whether it is the folder's own or one from a folder above.
public struct FolderViewUse: Equatable, Sendable {
    public var view: FolderView
    public var own: Bool

    public init(view: FolderView, own: Bool) {
        self.view = view
        self.own = own
    }
}

/// Every folder's view, by path (`folder-views.json`).
public struct FolderViews: Equatable, Sendable {
    public private(set) var byPath: [String: FolderView]

    public init(_ views: [FolderView] = []) {
        byPath = [:]
        for view in views where !view.isEmpty && !view.path.isEmpty {
            byPath[view.path] = view
        }
    }

    /// Sorted by path, so a parent comes before the folders inside it.
    public var all: [FolderView] { byPath.values.sorted { $0.path < $1.path } }

    public var isEmpty: Bool { byPath.isEmpty }

    /// The folder's own view, if it has one.
    public func own(_ path: String) -> FolderView? { byPath[path] }

    /// The one view a folder uses: its own, or else the nearest folder above whose view covers the folders inside.
    /// Found by the path alone, with no call to the disk.
    public func use(for path: String) -> FolderViewUse? {
        if let own = byPath[path] {
            return FolderViewUse(view: own, own: true)
        }
        return covering(path).map { FolderViewUse(view: $0, own: false) }
    }

    /// The view of the nearest folder above `path` that covers the folders inside it, whatever view `path` has itself.
    public func covering(_ path: String) -> FolderView? {
        var parent = Self.parent(of: path)
        while let current = parent {
            if let view = byPath[current], view.subfolders { return view }
            parent = Self.parent(of: current)
        }
        return nil
    }

    /// Puts `view` in place of the folder's; an empty view removes it.
    public mutating func set(_ view: FolderView) {
        if view.isEmpty {
            byPath[view.path] = nil
        } else {
            byPath[view.path] = view
        }
    }

    public mutating func remove(_ path: String) {
        byPath[path] = nil
    }

    /// The views of the folders inside `path`, at any depth, sorted by path.
    public func inside(_ path: String) -> [FolderView] {
        let prefix = path == "/" ? "/" : path + "/"
        return all.filter { $0.path.hasPrefix(prefix) && $0.path != path }
    }

    /// A folder renamed or moved by the app: its view and every view inside it go with it, to another disk too.
    public mutating func moved(from old: String, to new: String) {
        moved([(from: old, to: new)])
    }

    /// The folders one operation renamed or moved, each from where it was before any of them went: every view goes
    /// with the one move it belongs to, the deepest that holds its folder, so a folder moved out of a folder renamed
    /// in the same operation goes where it went. All of them are taken out before any is put in: a batch rename that
    /// hands names along (1 to 2, 2 to 3) or swaps them puts a view on a path another move starts from, and that move
    /// is not to carry it on, nor is it to replace the view still waiting there. `destination` gives where a move
    /// that carries a view ended as views are found (its links resolved), asked once for each such move and for no
    /// other.
    public mutating func moved(_ moves: [(from: String, to: String)], destination: (String) -> String = { $0 }) {
        let moves = moves.filter { $0.from != $0.to && !$0.from.isEmpty && !$0.to.isEmpty }
        guard !moves.isEmpty, !byPath.isEmpty else { return }
        let inside = moves.map { $0.from + "/" }
        let lengths = moves.map(\.from.count)
        var carried: [(view: FolderView, move: Int)] = []
        for view in all {
            var deepest: Int?
            for (index, move) in moves.enumerated()
            where lengths[index] > deepest.map({ lengths[$0] }) ?? 0
                && (view.path == move.from || view.path.hasPrefix(inside[index]))
            {
                deepest = index
            }
            if let deepest { carried.append((view, deepest)) }
        }
        guard !carried.isEmpty else { return }
        for (view, _) in carried {
            byPath[view.path] = nil
        }
        var destinations: [Int: String] = [:]
        for (view, index) in carried {
            let to = destinations[index] ?? destination(moves[index].to)
            destinations[index] = to
            var view = view
            view.path = to + view.path.dropFirst(lengths[index])
            byPath[view.path] = view
        }
    }

    static func parent(of path: String) -> String? {
        guard path.count > 1, let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    // MARK: The file

    private struct File: Codable {
        var version: Int
        var views: [Lenient]
    }

    // A view that can't be read is skipped, not the whole file.
    private struct Lenient: Codable {
        var view: FolderView?

        init(_ view: FolderView) { self.view = view }

        init(from decoder: Decoder) throws {
            view = try? FolderView(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try view?.encode(to: encoder)
        }
    }

    public static let fileVersion = 1

    /// Sorted keys and sorted views, so a file whose views haven't changed is written the same.
    public func serialize() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = File(version: Self.fileVersion, views: all.map(Lenient.init))
        guard let data = try? encoder.encode(file), let text = String(data: data, encoding: .utf8) else {
            return "{\"version\":\(Self.fileVersion),\"views\":[]}\n"
        }
        return text + "\n"
    }

    /// Read leniently: a view that can't be read (it has no path) is left out, and a setting of a view that can't be
    /// read is not kept. Throws when the file as a whole isn't one of the app's.
    public static func read(_ data: Data) throws -> FolderViews {
        let file = try JSONDecoder().decode(File.self, from: data)
        return FolderViews(file.views.compactMap(\.view).filter { $0.path.hasPrefix("/") })
    }

    /// As `read`, a file that can't be read being no views.
    public static func parse(_ data: Data) -> FolderViews {
        (try? read(data)) ?? FolderViews()
    }
}

/// A folder's view as a pane shows it: the view it uses, and what it keeps as it is on screen, which differs from what
/// is saved until Save (Update Folder View) or Revert. What is on screen may keep other settings than what is saved (a
/// Keep box checked or unchecked, not saved yet) and cover the subfolders or not.
public struct FolderViewOnScreen: Equatable, Sendable {
    public var use: FolderViewUse
    /// The settings kept, as on screen.
    public var shown: FolderViewKeeps
    /// Whether this folder's view covers the folders inside, as on screen. In a folder using a view from above, off
    /// until changed: covering the folders inside is the folder above's.
    public var shownSubfolders: Bool
    /// A folder with no view saved, given one on screen and not saved yet.
    public private(set) var isDraft: Bool
    /// A folder using a view from above that is to have one of its own at Save, though nothing of the view is
    /// changed (Keep Columns for … chosen there): a change on screen as any other. Never set on a folder's own view.
    public var becomesOwn = false

    public init(_ use: FolderViewUse) {
        self.use = use
        shown = use.view.keeps
        shownSubfolders = use.own && use.view.subfolders
        isDraft = false
    }

    /// A view for a folder that has none, nothing kept yet: a change on screen makes it, and Save saves it.
    public static func draft(_ view: FolderView) -> FolderViewOnScreen {
        var draft = FolderViewOnScreen(FolderViewUse(view: view, own: true))
        draft.isDraft = true
        return draft
    }

    public var saved: FolderViewKeeps { use.view.keeps }

    /// Whether the folder has a view of its own, saved.
    public var isOwnSaved: Bool { use.own && !isDraft }

    /// The settings whose values on screen, or whether they are kept, aren't what is saved.
    public var unsaved: [FolderViewSetting] { shown.differences(from: saved) }

    /// Whether this folder's view, as saved, covers the folders inside; never one used from above.
    public var savedSubfolders: Bool { use.own && use.view.subfolders }

    public var subfoldersUnsaved: Bool { shownSubfolders != savedSubfolders }

    public var hasUnsavedChanges: Bool { !unsaved.isEmpty || subfoldersUnsaved || becomesOwn }

    /// The view saved in its place (Save in another pane): what is changed here and not saved stays as on screen; the
    /// rest shows what is saved.
    public func taking(_ use: FolderViewUse) -> FolderViewOnScreen {
        var next = FolderViewOnScreen(use)
        guard next.use.view.path == self.use.view.path else { return next }
        for setting in unsaved {
            next.shown.take(setting, from: shown)
        }
        if subfoldersUnsaved { next.shownSubfolders = shownSubfolders }
        if becomesOwn, !next.use.own { next.becomesOwn = true }
        return next
    }
}
