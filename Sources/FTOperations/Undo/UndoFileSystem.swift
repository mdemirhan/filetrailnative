// Port of the getAcl member of WriteOperationFs (apps/desktop/src/main/bootstrap/writeOperations.ts) and of the
// batch rename that undoExecution.ts runs (runBatchRename and movedItemsOf, batchRenameExecution.ts), as Undo calls
// them
import FTFileSystem
import FTFoundation
import Foundation

/// What Undo asks of the disk, on top of what the local operations do: the item's access control list, to take a
/// rule against deleting it off an operation's own copy for the Trash, and put it back after.
public protocol UndoFileSystem: LocalWriteFileSystem {
    /// `nativeGetAcl`: the ACL as text, nil for none.
    var getAcl: ((String) throws -> String?)? { get }
}

extension UndoFileSystem {
    public var getAcl: ((String) throws -> String?)? { nil }
}

extension NativeWriteFileSystem: UndoFileSystem {
    public var getAcl: ((String) throws -> String?)? {
        { try NativeFS.getAcl($0) }
    }
}

/// One item of the batch an Undo renames back (`writeOperation:batchRename`'s item).
public struct UndoBatchRenameItem: Equatable, Sendable {
    public var sourcePath: String
    public var destinationName: String
    /// Says where a number goes when the name is taken: a package's before its extension.
    public var isFolder: Bool

    public init(sourcePath: String, destinationName: String, isFolder: Bool) {
        self.sourcePath = sourcePath
        self.destinationName = destinationName
        self.isFolder = isFolder
    }
}

/// What the batch rename did (`BatchRenameRun`): every item has a result, in the order asked for.
public struct UndoBatchRenameRun: Equatable, Sendable {
    public var items: [WriteOperationItem]
    public var cancelled: Bool

    public init(items: [WriteOperationItem], cancelled: Bool) {
        self.items = items
        self.cancelled = cancelled
    }
}

/// `runBatchRename` with `onConflict: "number"` and `numberSeparator: " "`, as a batch undo runs it, on the file
/// system it is given (`UndoBatchRename.runBatchRename`, the default of `WriteCoordinatorOptions.undoBatchRename`).
public typealias UndoBatchRenamer =
    @Sendable (
        _ items: [UndoBatchRenameItem], _ fileSystem: any UndoFileSystem, _ signal: StopSignal,
        _ journal: (any WriteJournal)?
    ) -> UndoBatchRenameRun

public enum UndoBatchRename {
    /// `movedItemsOf`: the items of a batch's results that moved, each with its id and kind as it is now (read where
    /// it went), for Undo.
    public static func movedItemsOf(_ fileSystem: some IdentityFileSystem, _ items: [WriteOperationItem])
        -> [BatchRenamedItem]
    {
        var moved: [BatchRenamedItem] = []
        for item in items {
            guard let sourcePath = item.sourcePath, let destinationPath = item.destinationPath,
                !sameText(destinationPath, sourcePath),
                !sameText(NodePath.basename(destinationPath), NodePath.basename(sourcePath))
            else { continue }
            let now = readItemRef({ try fileSystem.lstat($0) }, destinationPath)
            if let kind = now.kind {
                moved.append(BatchRenamedItem(from: sourcePath, to: destinationPath, id: now.id, itemKind: kind))
            }
        }
        return moved
    }
}
