// Port of apps/desktop/src/renderer/lib/internalDragAndDrop.ts
import Foundation

/// Where a drag comes from: the file list, search results, or Finder and other apps (`InternalMoveSourceSurface`).
public enum DragSourceSurface: String, Sendable, Codable {
    case content, search, external
}

/// What takes a drop (`InternalDropTargetSurface`): a row or the background of the file list, a folder of the tree,
/// a favorite or a location, a tab.
public enum DropTargetSurface: String, Sendable, Codable {
    case content, tree, favorite, tab
}

/// What a drop does with the dragged items, and the cursor it shows (`InternalDropOperation`).
public enum DropOperation: String, Sendable, Codable {
    case move, copy
}

/// Why a drop is refused (`InternalDropValidationResult`'s codes).
public enum DropRefusal: String, Sendable, Codable {
    case blocked, empty
    case targetMissing = "target_missing"
    case unsupportedTarget = "unsupported_target"
    case invalidTarget = "invalid_target"
    case targetSelected = "target_selected"
    case samePath = "same_path"
    case alreadyInTarget = "already_in_target"
    case parentIntoChild = "parent_into_child"
}

/// A dragged item (`InternalDragItem`).
public struct DragItem: Equatable, Sendable, Codable {
    public var path: String
    public var kind: EntryKind

    public init(path: String, kind: EntryKind) {
        self.path = path
        self.kind = kind
    }
}

/// A drag going on (`InternalDragSession`). The facts its drag-overs ask about are worked out once, with it.
public final class DragSession: Sendable {
    public let sourceSurface: DragSourceSurface
    public let sourceItems: [DragItem]
    public let leadPath: String
    public let leadKind: EntryKind
    public let facts: DragFacts

    public init(sourceSurface: DragSourceSurface, sourceItems: [DragItem], leadPath: String, leadKind: EntryKind) {
        self.sourceSurface = sourceSurface
        self.sourceItems = sourceItems
        self.leadPath = leadPath
        self.leadKind = leadKind
        facts = DragFacts(sourceItems)
    }
}

/// What the drag-overs of a drag ask about its items (`DragFacts`).
public struct DragFacts: Sendable {
    public let sourcePaths: [String]
    let paths: Set<ExactKey>
    /// The folders whose disks decide a move (`getSourceFolderPaths`).
    public let folderPaths: [String]
    /// The folder each item is in; "" stands for none ("/").
    let parentPaths: Set<ExactKey>
    let parentCount: Int
    /// The folders, apps and packages among the items, which can't go into themselves.
    let containerPaths: Set<ExactKey>
    /// The disks the items are on, by their paths.
    let volumeRoots: Set<ExactKey>

    init(_ items: [DragItem]) {
        sourcePaths = items.map(\.path)
        paths = Set(sourcePaths.map(ExactKey.init))
        folderPaths = DragRules.sourceFolderPaths(items)
        let parents = Set(sourcePaths.map { ExactKey(DragRules.parentDirectoryPath($0) ?? "\u{0}") })
        parentPaths = parents
        parentCount = parents.count
        containerPaths = Set(
            items.filter { $0.kind == .directory || $0.kind == .bundle }.map { ExactKey($0.path) })
        volumeRoots = Set(sourcePaths.map { ExactKey(DragRules.volumeRootPath($0)) })
    }

    func holdsParent(_ path: String) -> Bool { parentPaths.contains(ExactKey(path)) }
    func holds(_ path: String) -> Bool { paths.contains(ExactKey(path)) }
}

/// Finder's rules for a drag of files.
public enum DragRules {
    /// `isRealDirectoryEntry`: a folder, not an alias of one.
    public static func isRealDirectory(kind: EntryKind?, isSymlink: Bool) -> Bool {
        kind == .directory && !isSymlink
    }

    /// `buildInternalDragSession`: the whole selection (in view order) when the dragged row is part of it,
    /// otherwise only the dragged row; nil when the dragged entry isn't known.
    public static func session(
        sourceSurface: DragSourceSurface, draggedPath: String, selectedPathsInViewOrder: [String],
        kindOf: (String) -> EntryKind?
    ) -> DragSession? {
        guard let leadKind = kindOf(draggedPath) else { return nil }
        let paths =
            selectedPathsInViewOrder.contains(where: { JSString.equals($0, draggedPath) })
            ? selectedPathsInViewOrder : [draggedPath]
        let items = paths.compactMap { path in kindOf(path).map { DragItem(path: path, kind: $0) } }
        guard !items.isEmpty else { return nil }
        return DragSession(sourceSurface: sourceSurface, sourceItems: items, leadPath: draggedPath, leadKind: leadKind)
    }

    /// `resolveInternalDropOperation`: Option copies and Command moves, whatever the disks (Option-Command copies);
    /// otherwise the disks decide once they have answered, and the paths until then.
    public static func operation(
        sourcePaths: [String], targetPath: String, option: Bool, command: Bool, onSameDisk: Bool? = nil
    ) -> DropOperation {
        if option { return .copy }
        if command { return .move }
        if let onSameDisk { return onSameDisk ? .move : .copy }
        let target = DragRules.volumeRootPath(targetPath)
        for path in sourcePaths where !JSString.equals(DragRules.volumeRootPath(path), target) { return .copy }
        return .move
    }

    /// The same, from the facts of a drag.
    public static func operation(
        _ facts: DragFacts, targetPath: String, option: Bool, command: Bool, onSameDisk: Bool? = nil
    ) -> DropOperation {
        if option { return .copy }
        if command { return .move }
        if let onSameDisk { return onSameDisk ? .move : .copy }
        let target = DragRules.volumeRootPath(targetPath)
        return facts.volumeRoots.allSatisfy { $0 == ExactKey(target) } ? .move : .copy
    }

    /// `allowedBySource`: another app's drag that offers no move gets a copy, without a question.
    public static func allowedBySource(_ operation: DropOperation, offersMove: Bool) -> DropOperation {
        operation == .move && !offersMove ? .copy : operation
    }

    /// `getSourceFolderPaths`: the folders holding the items, once each, and dragged folders themselves (never
    /// aliases): a disk's own folder is on that disk.
    public static func sourceFolderPaths(_ items: [DragItem]) -> [String] {
        var seen = Set<ExactKey>()
        var paths: [String] = []
        func add(_ path: String) {
            if seen.insert(ExactKey(path)).inserted { paths.append(path) }
        }
        for item in items {
            let units = Array(item.path.utf16)
            if let slash = JSString.lastIndex(of: 0x2F, in: units), slash > 0 {
                add(JSString.string(units[..<slash]))
            } else {
                add("/")
            }
            if item.kind == .directory { add(item.path) }
        }
        return paths
    }

    /// `resolveOnSameDisk`: whether the items' folders and the target are all on one disk; nil while one is unknown
    /// or can't be read (an id of nil).
    public static func onSameDisk(sourceFolderPaths: [String], targetPath: String, diskIds: [String: Int64?])
        -> Bool?
    {
        onSameDisk(sourceFolderPaths: sourceFolderPaths, targetPath: targetPath) { diskIds[$0] }
    }

    /// The same, with the ids known so far looked up by `diskId` (nil: not answered; `.some(nil)`: unreadable).
    public static func onSameDisk(sourceFolderPaths: [String], targetPath: String, diskId: (String) -> Int64??)
        -> Bool?
    {
        guard let targetEntry = diskId(targetPath), let target = targetEntry else { return nil }
        var same = true
        for folder in sourceFolderPaths {
            guard let entry = diskId(folder), let id = entry else { return nil }
            same = same && id == target
        }
        return same
    }

    /// `EFFECTS_WITH_MOVE`: whether another app's drag (`effectAllowed`) offers a move; nil (not said) does.
    public static func offersMove(effectAllowed: String?) -> Bool {
        guard let effectAllowed else { return true }
        return ["move", "copyMove", "linkMove", "all", "uninitialized"].contains(effectAllowed)
    }

    /// `validateInternalDrop`: nil when the drop is allowed, else why not; the first failure in this order wins.
    public static func validate(
        session: DragSession?, blocked: Bool, targetSurface: DropTargetSurface, targetPath: String?,
        targetSupportsMove: Bool, targetIsSelected: Bool = false, operation: DropOperation = .move
    ) -> DropRefusal? {
        if blocked { return .blocked }
        guard let session, !session.sourceItems.isEmpty else { return .empty }
        guard let targetPath, !targetPath.isEmpty else { return .targetMissing }
        if !targetSupportsMove { return .invalidTarget }
        if session.sourceSurface == .search, targetSurface == .content { return .unsupportedTarget }
        if targetSurface == .content, targetIsSelected { return .targetSelected }
        let facts = session.facts
        if facts.holds(targetPath) { return .samePath }
        // Moving items into their own folder does nothing; copying them there makes "name copy" duplicates.
        if operation == .move, facts.parentCount == 1, facts.holdsParent(targetPath) { return .alreadyInTarget }
        if isInsideAny(targetPath, facts.containerPaths) { return .parentIntoChild }
        return nil
    }

    /// Whether `path` is one of the folders or inside one, looked up along its own path.
    static func isInsideAny(_ path: String, _ folders: Set<ExactKey>) -> Bool {
        guard !folders.isEmpty else { return false }
        if folders.contains(ExactKey(path)) { return true }
        let units = Array(path.utf16)
        var index = 1
        while index < units.count {
            if units[index] == 0x2F, folders.contains(ExactKey(JSString.string(units[..<index]))) { return true }
            index += 1
        }
        return false
    }

    /// `getVolumeRootPath` (volumes.ts), by code units: `/Volumes/<name>` for a path on another disk, else `/`.
    public static func volumeRootPath(_ path: String) -> String {
        let prefix = Array("/Volumes/".utf16)
        let units = Array(path.utf16)
        guard units.starts(with: prefix) else { return "/" }
        let name = units[prefix.count...].prefix { $0 != 0x2F }
        return name.isEmpty ? "/" : JSString.string(prefix + name)
    }

    /// `parentDirectoryPath` (explorerNavigation.ts): nil for "/", "/" for a top folder.
    public static func parentDirectoryPath(_ path: String) -> String? {
        if JSString.equals(path, "/") { return nil }
        let parts = JSString.components(path, separator: 0x2F).filter { !$0.isEmpty }
        if parts.count <= 1 { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }
}
