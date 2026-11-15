// What a finished write does to search results it acted on: what it removed, what it renamed, what it put inside
import FTFileSystem
import FTFoundation
import FTOperations

/// A path as a key, spelled exactly.
typealias ExactPath = FTFoundation.NameKeys.Exact

/// What a write did, as search results take it. Results change only when the write acted on them: one of its items
/// was a result, or it put items into a folder found. Then what it removed or moved to another folder leaves them,
/// what it renamed is renamed in them, and what it put inside the folder searched is not added: the results say
/// they may be missing something instead. Nothing is searched again.
struct SearchAfterWrite: Equatable {
    /// What the write took away: moved to the Trash, deleted, or moved into another folder.
    var removed: [String] = []
    /// What it renamed in its own folder, a folder renamed with it taking it along.
    var renamed: [SearchResultRename] = []
    /// What it put somewhere, outside the Trash: what it copied, moved into another folder, made or brought back.
    var arrived: [String] = []
    /// The items it acted on, and the folders it put items into.
    private var items: [String] = []
    private var targets: [String] = []

    init(_ result: WriteOperationResult, homePath: String) {
        let completed = result.items.filter { $0.status == .completed }
        var renamedTo = Set<ExactPath>()
        if AfterWrite.movedItems(result) {
            // The shallowest first: a folder renamed with items inside it is known before they are, so an item
            // whose folder took it along under its new name is renamed (or stays as it is) rather than moved away.
            let moves = WriteEffects.followedMoves(result.action, items: result.items)
                .sorted { $0.from.utf8.count < $1.from.utf8.count }
            var renames = SearchResultRenames()
            for move in moves {
                let folder = NodePath.dirname(move.from)
                let folderNow = renames.path(folder) ?? folder
                if folderNow.utf8.elementsEqual(NodePath.dirname(move.to).utf8) {
                    let rename = SearchResultRename(from: move.from, to: move.to)
                    renamed.append(rename)
                    renames.add(rename)
                    renamedTo.insert(ExactPath(move.to))
                } else {
                    removed.append(move.from)
                }
            }
        }
        // What a Replace removed has another item at its path now: its result stays.
        removed += WriteEffects.removedPaths(result.action, items: result.items, replacedPaths: [])
        arrived = completed.compactMap { item in
            guard let path = item.destinationPath, !path.isEmpty, !renamedTo.contains(ExactPath(path)),
                !Paths.isInsideTrash(path, homePath: homePath)
            else { return nil }
            return path
        }
        items = result.items.compactMap { $0.sourcePath.flatMap { $0.isEmpty ? nil : $0 } }
        targets = completed.compactMap { $0.destinationPath.flatMap { $0.isEmpty ? nil : NodePath.dirname($0) } }
        if let target = result.targetPath, !target.isEmpty { targets.append(target) }
    }

    /// What another app took away from a drag out of the results, or that was gone after it.
    init(draggedAway gone: [String]) {
        removed = gone
        items = gone
    }

    /// Whether the write acted on results at `paths`: one of its items is one of them, or it put items into one.
    func actsOn(_ paths: Set<ExactPath>) -> Bool {
        items.contains { paths.contains(ExactPath($0)) } || targets.contains { paths.contains(ExactPath($0)) }
    }

    /// Whether it put something inside `rootPath`, which a search there may find.
    func addsInside(_ rootPath: String) -> Bool {
        !rootPath.isEmpty && arrived.contains { SearchResults.isAtOrInside($0, rootPath) }
    }
}
