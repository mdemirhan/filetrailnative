import Foundation

/// The five settings a folder's view can keep (View ▸ Folder View).
public enum FolderViewSetting: String, CaseIterable, Sendable, Hashable {
    case view, sort, foldersFirst, columns, size

    /// What Folder View Options calls it, and the unsaved changes popover.
    public var label: String {
        switch self {
        case .view: "View"
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
}

/// What a folder's view keeps: a setting that is nil is not kept, and follows the pane.
public struct FolderViewKeeps: Codable, Equatable, Sendable {
    public var view: ExplorerViewMode?
    public var sort: FolderViewSort?
    public var foldersFirst: Bool?
    public var columns: FolderViewColumns?
    public var size: FolderViewSizes?

    public init(
        view: ExplorerViewMode? = nil, sort: FolderViewSort? = nil, foldersFirst: Bool? = nil,
        columns: FolderViewColumns? = nil, size: FolderViewSizes? = nil
    ) {
        self.view = view
        self.sort = sort
        self.foldersFirst = foldersFirst
        self.columns = columns
        self.size = size
    }

    public var isEmpty: Bool { kept.isEmpty }

    /// The settings kept, in the order Folder View Options lists them.
    public var kept: [FolderViewSetting] { FolderViewSetting.allCases.filter(keeps) }

    public func keeps(_ setting: FolderViewSetting) -> Bool {
        switch setting {
        case .view: view != nil
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

/// One folder's view: where the folder is, whether its view covers the folders inside, and what it keeps.
public struct FolderView: Codable, Equatable, Sendable {
    /// The canonical path.
    public var path: String
    /// The disk's volume UUID; nil where none could be read (a share, or a disk that has none).
    public var volume: String?
    /// The folder's file ID, to find it again after it was renamed or moved outside the app.
    public var fileID: UInt64?
    /// Whether the folders inside with no view of their own use this one.
    public var subfolders: Bool
    public var keeps: FolderViewKeeps

    public init(
        path: String, volume: String? = nil, fileID: UInt64? = nil, subfolders: Bool = false,
        keeps: FolderViewKeeps = FolderViewKeeps()
    ) {
        self.path = path
        self.volume = volume
        self.fileID = fileID
        self.subfolders = subfolders
        self.keeps = keeps
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
    /// A view kept for another disk at the same path (`volume` differs, both known) isn't this folder's.
    public func use(for path: String, volume: String? = nil) -> FolderViewUse? {
        if let own = byPath[path], Self.sameDisk(own, volume) {
            return FolderViewUse(view: own, own: true)
        }
        var parent = Self.parent(of: path)
        while let current = parent {
            if let view = byPath[current], view.subfolders, Self.sameDisk(view, volume) {
                return FolderViewUse(view: view, own: false)
            }
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

    /// A folder renamed or moved by the app: its view and every view inside it go with it.
    public mutating func moved(from old: String, to new: String) {
        guard old != new, !old.isEmpty, !new.isEmpty else { return }
        let prefix = old + "/"
        let moving = byPath.values.filter { $0.path == old || $0.path.hasPrefix(prefix) }
        guard !moving.isEmpty else { return }
        for view in moving {
            byPath[view.path] = nil
        }
        for var view in moving {
            view.path = new + view.path.dropFirst(old.count)
            byPath[view.path] = view
        }
    }

    /// A folder opened with no view of its own whose file ID is that of a view whose folder is gone: the folder was
    /// renamed or moved outside the app, and takes the view over. `exists` says whether a path is still a folder.
    public mutating func adopt(path: String, volume: String?, fileID: UInt64, exists: (String) -> Bool)
        -> Bool
    {
        guard byPath[path] == nil else { return false }
        guard
            let lost = byPath.values.first(where: {
                $0.fileID == fileID && $0.volume == volume && $0.path != path && !exists($0.path)
            })
        else { return false }
        moved(from: lost.path, to: path)
        return true
    }

    private static func sameDisk(_ view: FolderView, _ volume: String?) -> Bool {
        guard let kept = view.volume, let volume else { return true }
        return kept == volume
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

    /// Read leniently: a file that can't be read is no views, and a view that can't be read is left out.
    public static func parse(_ data: Data) -> FolderViews {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return FolderViews() }
        return FolderViews(file.views.compactMap(\.view).filter { $0.path.hasPrefix("/") })
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

    public var hasUnsavedChanges: Bool { !unsaved.isEmpty || subfoldersUnsaved }

    /// The view saved in its place (Save in another pane): what is changed here and not saved stays as on screen; the
    /// rest shows what is saved.
    public func taking(_ use: FolderViewUse) -> FolderViewOnScreen {
        var next = FolderViewOnScreen(use)
        guard next.use.view.path == self.use.view.path else { return next }
        for setting in unsaved {
            next.shown.take(setting, from: shown)
        }
        if subfoldersUnsaved { next.shownSubfolders = shownSubfolders }
        return next
    }
}
