// Port of assertNotProtectedPath, assertNotIntoTrash, assertNotAlreadyInTrash, assertNotSystemLocation, identitiesOf,
// identityOf and trimAnalysisReportForWindow (apps/desktop/src/main/bootstrap/writeOperations.ts)
import FTFoundation
import Foundation

/// What every write is checked against, whatever the window asks: the Trash folders, the system's folders, the home
/// folder and its own folders, whole disks.
public enum WriteGuards {
    public static let trashFolderRefusal = "The Trash folder is a protected system directory and cannot be modified."

    /// `assertNotProtectedPath`: a Trash folder itself, the home folder's or another disk's.
    public static func assertNotProtectedPath(_ paths: [String], homePath: String) throws {
        for path in paths where Paths.isTrashFolder(NodePath.resolve(path), homePath: homePath) {
            throw WriteCoordinatorError(trashFolderRefusal)
        }
    }

    /// `assertNotIntoTrash`: nothing is pasted, dropped, duplicated or made in the Trash. `verb` is "pasted into",
    /// "made in"…
    public static func assertNotIntoTrash(_ destinationDirectoryPath: String, verb: String, homePath: String) throws {
        if Paths.isInsideTrash(NodePath.resolve(destinationDirectoryPath), homePath: homePath) {
            throw WriteCoordinatorError("Nothing can be \(verb) the Trash.")
        }
    }

    /// `assertNotAlreadyInTrash`.
    public static func assertNotAlreadyInTrash(_ paths: [String], homePath: String) throws {
        for path in paths where Paths.isInsideTrash(NodePath.resolve(path), homePath: homePath) {
            throw WriteCoordinatorError("\u{201C}\(NodePath.basename(path))\u{201D} is already in the Trash.")
        }
    }

    /// `assertNotSystemLocation`: refuses to delete, trash, move or rename the startup disk, a folder that holds the
    /// system, the apps or everyone's files, the home folder and its own folders, or a whole disk. The same folder
    /// can be reached by other paths ("/System/Volumes/Data/Users/me" is the home folder, "/USERS" is "/Users"), so
    /// besides the path, what is on disk is compared: the item's identity, and whether it is where a disk is
    /// mounted. Without `fileSystem`, the paths alone.
    public static func assertNotSystemLocation(
        _ paths: [String], verb: String, fileSystem: (any IdentityFileSystem)?, homePath: String
    ) throws {
        let home = NodePath.resolve(homePath)
        var protectedIds: Set<String>?
        for path in paths {
            if let refusal = Paths.systemLocationRefusal(path: path, verb: verb, homePath: home) {
                throw WriteCoordinatorError(refusal)
            }
            guard let fileSystem else { continue }
            let resolved = NodePath.resolve(path)
            // Only folders are protected; a file or a link is never one of them.
            guard let stats = try? fileSystem.lstat(resolved), stats.isDirectory else { continue }
            let ids = protectedIds ?? identities(of: Paths.protectedPaths(homePath: home), fileSystem)
            protectedIds = ids
            if let id = identity(of: stats), ids.contains(id) {
                throw WriteCoordinatorError("\u{201C}\(NodePath.basename(resolved))\u{201D} can't be \(verb).")
            }
            // A disk is mounted here when the folder is on a different disk than its parent.
            if let parent = try? fileSystem.lstat(NodePath.dirname(resolved)), let parentDev = parent.dev,
                let dev = stats.dev, parentDev != dev
            {
                throw WriteCoordinatorError(
                    "\u{201C}\(NodePath.basename(resolved))\u{201D} is a disk, so it can't be \(verb).")
            }
        }
    }

    private static func identities(of paths: [String], _ fileSystem: any IdentityFileSystem) -> Set<String> {
        Set(paths.compactMap { path in (try? fileSystem.stat(path)).flatMap(identity(of:)) })
    }

    /// The system's own folders have ids too large to compare (see `fileIdOf`).
    private static func identity(of stats: WriteServiceStats) -> String? {
        guard let dev = stats.dev, let ino = fileIdOf(stats.ino) else { return nil }
        return "\(dev):\(ino)"
    }

    /// `trimAnalysisReportForWindow`: the report of an analysis has a record for every file and folder to be copied.
    /// The window draws the review from it, and looks inside an item only when it is a folder that exists on both
    /// sides; what is inside an item that is new at the destination is left out of what the window is sent. This is
    /// a trimmed copy: the write service copies from its own report, which stays whole.
    public static func trimAnalysisReportForWindow(_ report: CopyPasteAnalysisReport) -> CopyPasteAnalysisReport {
        var trimmed = report
        trimmed.nodes = report.nodes.map(trimAnalysisNodeForWindow)
        return trimmed
    }

    private static func trimAnalysisNodeForWindow(_ node: CopyPasteAnalysisNode) -> CopyPasteAnalysisNode {
        var trimmed = node
        trimmed.children = node.conflictClass == .directoryConflict ? node.children.map(trimAnalysisNodeForWindow) : []
        return trimmed
    }
}
