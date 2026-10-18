// Port of the after-write cases of apps/desktop/src/renderer/lib/explorerAppUtils.ts:
// resolveWriteOperationSelectionDirectoryPath, resolveWriteOperationRefreshPath, resolveWriteOperationTreeSelectionPath,
// isUndoOrRedo, pathsLeftByWrite, removedByWrite, onlyRemoved, resolveWriteOperationTreeReloadPaths, replacePathPrefix,
// findDeepestMatchingSourcePath, findDeepestMatchingSourceItem and collapseNestedPaths
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
        ExplorerTabs.isRenameOrMove(result.action.rawValue) || result.mode == .cut
    }

    /// `resolveWriteOperationSelectionDirectoryPath`: the folder the items a write made are selected in: a rename's,
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

    /// `resolveWriteOperationRefreshPath`: the folder on screen after a write: where a folder renamed or moved went,
    /// the folder holding one trashed or deleted.
    static func refreshPath(_ result: WriteOperationResult, currentPath: String) -> String {
        if result.action == .trash || result.action == .deleteImmediately {
            guard let impacted = deepestMatchingSourcePath(result.items, currentPath) else { return currentPath }
            return ExplorerTabs.parentDirectoryPath(impacted) ?? currentPath
        }
        // An Undo may have moved the folder on screen to the Trash (a New Folder undone).
        if isUndoOrRedo(result.action), let removed = deepestMatchingSourcePath(onlyRemoved(result), currentPath) {
            return ExplorerTabs.parentDirectoryPath(removed) ?? currentPath
        }
        // A folder renamed or moved (by Move To, a drag, or Cut and Paste) is followed.
        if movedItems(result) {
            guard let impacted = deepestMatchingSourceItem(result.items, currentPath) else { return currentPath }
            return replacePathPrefix(currentPath, impacted.source, impacted.destination)
        }
        return currentPath
    }

    /// `resolveWriteOperationTreeSelectionPath`: where the tree selection goes after a write; nil to leave it.
    static func treeSelectionPath(_ result: WriteOperationResult, selectedTreePath: String?) -> String? {
        guard let selected = selectedTreePath, !selected.isEmpty else { return nil }
        if result.action == .trash || result.action == .deleteImmediately {
            return deepestMatchingSourcePath(result.items, selected).flatMap(ExplorerTabs.parentDirectoryPath)
        }
        if isUndoOrRedo(result.action), let removed = deepestMatchingSourcePath(onlyRemoved(result), selected) {
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
        var left = removedByWrite(result)
        if movedItems(result) {
            let outcome = WriteOperationOutcome(
                action: result.action.rawValue, mode: result.mode.flatMap { CopyPasteMode(rawValue: $0.rawValue) },
                items: result.items.map(\.effect))
            for move in ExplorerTabs.collectFollowedMoves(outcome)
            where ExplorerTabs.parentDirectoryPath(move.from) != ExplorerTabs.parentDirectoryPath(move.to)
                && !left.contains(move.from)
            {
                left.append(move.from)
            }
        }
        return left
    }

    /// `removedByWrite`: everything a Trash or delete was asked to remove, what an Undo moved to the Trash, and what
    /// a Replace removed (another item has its path now).
    static func removedByWrite(_ result: WriteOperationResult) -> [String] {
        let replaced = result.replacedPaths ?? []
        if result.action == .trash || result.action == .deleteImmediately {
            return result.items.compactMap { $0.status == .completed ? nonEmpty($0.sourcePath) : nil }
        }
        if isUndoOrRedo(result.action) {
            return onlyRemoved(result).compactMap { nonEmpty($0.sourcePath) } + replaced
        }
        return replaced
    }

    /// `onlyRemoved`: an Undo's items that went to the Trash: done, and with nowhere else to be.
    private static func onlyRemoved(_ result: WriteOperationResult) -> [WriteOperationItem] {
        result.items.filter { $0.status == .completed && $0.destinationPath == nil }
    }

    /// `resolveWriteOperationTreeReloadPaths`: the parents of what a write took and made, and what it made.
    static func treeReloadPaths(_ result: WriteOperationResult) -> [String] {
        let completed = result.items.filter { $0.status == .completed }
        let sourceRoots = collapseNestedPaths(completed.compactMap { nonEmpty($0.sourcePath) })
        let destinationRoots = collapseNestedPaths(completed.compactMap { nonEmpty($0.destinationPath) })
        var parents: [String] = []
        for path in sourceRoots + destinationRoots {
            if let parent = ExplorerTabs.parentDirectoryPath(path), !parents.contains(parent) {
                parents.append(parent)
            }
        }
        var paths: [String] = []
        for path in parents + destinationRoots where !paths.contains(path) {
            paths.append(path)
        }
        return paths.sorted(by: shorterFirst)
    }

    /// `replacePathPrefix`.
    static func replacePathPrefix(_ path: String, _ sourcePrefix: String, _ destinationPrefix: String) -> String {
        if path.utf16.elementsEqual(sourcePrefix.utf16) { return destinationPrefix }
        guard path.utf16.starts(with: (sourcePrefix + "/").utf16) else { return path }
        let rest = path.utf16.index(path.utf16.startIndex, offsetBy: sourcePrefix.utf16.count)
        return destinationPrefix + path[rest...]
    }

    /// The selection a write leaves (`queueWriteOperationSelection`): the items it made or moved, when they are in the
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

    private static func deepestMatchingSourcePath(_ items: [WriteOperationItem], _ currentPath: String) -> String? {
        items.compactMap { nonEmpty($0.sourcePath) }
            .filter { isAtOrInside(currentPath, $0) }
            .max { $0.utf16.count < $1.utf16.count }
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

    private static func collapseNestedPaths(_ paths: [String]) -> [String] {
        var unique: [String] = []
        for path in paths where !unique.contains(path) { unique.append(path) }
        var roots: [String] = []
        for path in unique.sorted(by: shorterFirst) where !roots.contains(where: { isAtOrInside(path, $0) }) {
            roots.append(path)
        }
        return roots
    }

    /// Shorter first; of the same length, as `localeCompare` orders them.
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
