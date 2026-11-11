// What follows a write: the folder read again, what is selected, where the tree goes, and what left the folder
import FTFoundation
import FTOperations
import Foundation

/// What a window does after a write: which folder it reads again, what it selects, where the tree selection goes and
/// which branches it reads again.
enum AfterWrite {
    /// `isUndoOrRedo`.
    static func isUndoOrRedo(_ action: WriteOperationAction) -> Bool {
        action == .undo || action == .redo
    }

    /// `movedItems`: a write that gave items new paths, a rename or move, or a paste that moved what was cut.
    static func movedItems(_ result: WriteOperationResult) -> Bool {
        WriteEffects.movedItems(result.action, cut: result.mode == .cut)
    }

    /// The folder the items a write made are selected in: a rename's,
    /// a new folder's or an Undo's is the folder of the first; a paste's is where it pasted.
    static func selectionDirectoryPath(_ result: WriteOperationResult, selectedPaths: [String]) -> String? {
        guard let first = selectedPaths.first, !first.isEmpty else { return nil }
        if result.action == .rename || result.action == .batchRename || result.action == .newFolder
            || isUndoOrRedo(result.action)
        {
            return ExplorerTabs.parentDirectoryPath(first)
        }
        return result.targetPath
    }

    /// The folder on screen after a write: where a folder renamed or moved went,
    /// the folder holding one trashed or deleted.
    static func refreshPath(_ result: WriteOperationResult, currentPath: String) -> String {
        if result.action == .trash || result.action == .deleteImmediately {
            guard let impacted = deepestMatchingPath(sourcePaths(result.items), currentPath) else {
                return currentPath
            }
            return ExplorerTabs.parentDirectoryPath(impacted) ?? currentPath
        }
        // An Undo may have moved the folder on screen to the Trash (a New Folder undone).
        if isUndoOrRedo(result.action), let removed = deepestMatchingPath(trashedByUndo(result), currentPath) {
            return ExplorerTabs.parentDirectoryPath(removed) ?? currentPath
        }
        // A folder renamed or moved (by Move To, a drag, or Cut and Paste) is followed.
        if movedItems(result) {
            guard let impacted = deepestMatchingSourceItem(result.items, currentPath) else { return currentPath }
            return replacePathPrefix(currentPath, impacted.source, impacted.destination)
        }
        return currentPath
    }

    /// Where the tree selection goes after a write; nil to leave it.
    static func treeSelectionPath(_ result: WriteOperationResult, selectedTreePath: String?) -> String? {
        guard let selected = selectedTreePath, !selected.isEmpty else { return nil }
        if result.action == .trash || result.action == .deleteImmediately {
            return deepestMatchingPath(sourcePaths(result.items), selected).flatMap(ExplorerTabs.parentDirectoryPath)
        }
        if isUndoOrRedo(result.action), let removed = deepestMatchingPath(trashedByUndo(result), selected) {
            return ExplorerTabs.parentDirectoryPath(removed)
        }
        if movedItems(result) {
            guard let impacted = deepestMatchingSourceItem(result.items, selected) else { return nil }
            return replacePathPrefix(selected, impacted.source, impacted.destination)
        }
        return nil
    }

    /// `pathsLeftByWrite`: what a write took out of the folder it was in: what it moved to the Trash or deleted, and
    /// what it moved into another folder (not what it renamed in place).
    static func pathsLeftByWrite(_ result: WriteOperationResult) -> [String] {
        var left = WriteEffects.removedPaths(
            result.action, items: result.items, replacedPaths: result.replacedPaths ?? [])
        var inLeft = Set(left.map(NameKeys.Exact.init))
        if movedItems(result) {
            for move in WriteEffects.followedMoves(result.action, items: result.items)
            where ExplorerTabs.parentDirectoryPath(move.from) != ExplorerTabs.parentDirectoryPath(move.to)
                && inLeft.insert(NameKeys.Exact(move.from)).inserted
            {
                left.append(move.from)
            }
        }
        return left
    }

    /// What an Undo or Redo moved to the Trash, a Replace's aside.
    private static func trashedByUndo(_ result: WriteOperationResult) -> [String] {
        WriteEffects.removedPaths(result.action, items: result.items, replacedPaths: [])
    }

    /// The parents of what a write took and made, and what it made.
    static func treeReloadPaths(_ result: WriteOperationResult) -> [String] {
        let completed = result.items.filter { $0.status == .completed }
        let sourceRoots = collapseNestedPaths(completed.compactMap { nonEmpty($0.sourcePath) })
        let destinationRoots = collapseNestedPaths(completed.compactMap { nonEmpty($0.destinationPath) })
        let parents = uniqued((sourceRoots + destinationRoots).compactMap(ExplorerTabs.parentDirectoryPath))
        return uniqued(parents + destinationRoots).sorted(by: shorterFirst)
    }

    /// `replacePathPrefix`.
    static func replacePathPrefix(_ path: String, _ sourcePrefix: String, _ destinationPrefix: String) -> String {
        if path.utf16.elementsEqual(sourcePrefix.utf16) { return destinationPrefix }
        guard path.utf16.starts(with: (sourcePrefix + "/").utf16) else { return path }
        let rest = path.utf16.index(path.utf16.startIndex, offsetBy: sourcePrefix.utf16.count)
        return destinationPrefix + path[rest...]
    }

    /// The selection a write leaves: the items it made or moved, when they are in the
    /// folder on screen, nothing is searched, and the person didn't pick something else meanwhile.
    static func selection(
        _ result: WriteOperationResult, currentPath: String, isSearching: Bool, selectionChanged: Bool
    ) -> [String]? {
        let made = result.items.compactMap { $0.status == .completed ? $0.destinationPath : nil }
        guard !isSearching, let folder = selectionDirectoryPath(result, selectedPaths: made),
            currentPath.utf16.elementsEqual(folder.utf16), !selectionChanged, !made.isEmpty
        else { return nil }
        return made
    }

    private static func isAtOrInside(_ path: String, _ folder: String) -> Bool {
        path.utf16.elementsEqual(folder.utf16) || path.utf16.starts(with: (folder + "/").utf16)
    }

    private static func sourcePaths(_ items: [WriteOperationItem]) -> [String] {
        items.compactMap { nonEmpty($0.sourcePath) }
    }

    private static func deepestMatchingPath(_ paths: [String], _ currentPath: String) -> String? {
        paths.filter { isAtOrInside(currentPath, $0) }.max { $0.utf16.count < $1.utf16.count }
    }

    private static func deepestMatchingSourceItem(_ items: [WriteOperationItem], _ currentPath: String)
        -> (source: String, destination: String)?
    {
        items.compactMap { item -> (source: String, destination: String)? in
            guard let source = nonEmpty(item.sourcePath), let destination = nonEmpty(item.destinationPath),
                isAtOrInside(currentPath, source)
            else { return nil }
            return (source, destination)
        }
        .max { $0.source.utf16.count < $1.source.utf16.count }
    }

    /// The paths with no other of them above them, shorter first. A path is looked up by each folder above it, so
    /// the cost grows with the paths times their depth, not with the square of their number.
    private static func collapseNestedPaths(_ paths: [String]) -> [String] {
        var roots: [String] = []
        var rootKeys = Set<NameKeys.Exact>()
        for path in uniqued(paths).sorted(by: shorterFirst) where !hasAncestor(path, in: rootKeys) {
            roots.append(path)
            rootKeys.insert(NameKeys.Exact(path))
        }
        return roots
    }

    /// Whether a folder above `path` is in `keys`: each start of it that ends before a "/", the leading one aside,
    /// as `isAtOrInside` takes a folder to hold what starts with it and a "/".
    private static func hasAncestor(_ path: String, in keys: Set<NameKeys.Exact>) -> Bool {
        let bytes = Array(path.utf8)
        var index = bytes.count - 1
        while index > 0 {
            if bytes[index] == UInt8(ascii: "/"),
                keys.contains(NameKeys.Exact(String(decoding: bytes[..<index], as: UTF8.self)))
            {
                return true
            }
            index -= 1
        }
        return false
    }

    /// Each path once, at its first place; paths are the same only when spelled the same, NFC and NFD apart.
    private static func uniqued(_ paths: [String]) -> [String] {
        var seen = Set<NameKeys.Exact>()
        return paths.filter { seen.insert(NameKeys.Exact($0)).inserted }
    }

    /// Shorter first; of the same length, in the current locale's order.
    private static func shorterFirst(_ left: String, _ right: String) -> Bool {
        let leftCount = left.utf16.count
        let rightCount = right.utf16.count
        if leftCount != rightCount { return leftCount < rightCount }
        return left.compare(right, options: [], range: nil, locale: .current) == .orderedAscending
    }

    private static func nonEmpty(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
