import Darwin
import FTFoundation
import Foundation

/// The folders that make up the one Trash Finder shows: the home folder's, and on each other disk this user's folder
/// in its ".Trashes". What is trashed on a disk stays on that disk, so these go and come with the disks. Only local
/// disks count: a network share has no Trash (`makeDiskHasTrash`), and reading one may stall.
public struct TrashFolders: Sendable {
    /// The home folder's Trash by its real path, which the one Trash is known by: what a folder's listing gives.
    public let home: String
    /// The same as the system spells the home folder (/tmp for /private/tmp, a link to a home elsewhere).
    private let homeAsSpelled: String
    private let uid: UInt32
    private let listMounts: @Sendable () -> [Mount]

    public init(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path, uid: UInt32 = getuid(),
        listMounts: @escaping @Sendable () -> [Mount] = MountTable.list
    ) {
        homeAsSpelled = NodePath.join(homePath, ".Trash")
        home = (try? MountTable.realPath(homeAsSpelled)) ?? homeAsSpelled
        self.uid = uid
        self.listMounts = listMounts
    }

    /// This user's Trash on each disk mounted now, whether the disk has made it yet or not.
    public var onOtherDisks: [String] {
        listMounts().filter(\.isLocal).map { "\($0.path)/.Trashes/\(uid)" }.filter(isOnOtherDisk).sorted()
    }

    /// Whether `path` is this user's Trash on another disk.
    public func isOnOtherDisk(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return path.hasPrefix("/") && parts.count == 4 && parts[0] == "Volumes" && parts[2] == ".Trashes"
            && parts[3] == String(uid)
    }

    /// Whether `path` is a disk's ".Trashes", which holds one Trash per user. macOS makes it so that no one can list
    /// it, Full Disk Access or not (mode d-wx--x--t); only this user's folder in it can be read.
    func isTrashesOfDisk(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return path.hasPrefix("/") && parts.count == 3 && parts[0] == "Volumes" && parts[2] == ".Trashes"
    }

    /// The Trash folders, which are never listed, with hidden files shown or not, as in Finder: the Trash is reached by
    /// its own row. A folder of that name anywhere else is a folder like any other. The name is looked at first, as
    /// this is asked of every item of every folder.
    func isAlwaysHidden(_ name: String, in folder: String) -> Bool {
        switch name {
        case ".Trash":
            let path = NodePath.join(folder, name)
            return path == home || path == homeAsSpelled
        case ".Trashes":
            return isTrashesOfDisk(NodePath.join(folder, name))
        default:
            return false
        }
    }

    /// This user's Trash in the disk's ".Trashes" `path`; any other path as it is.
    func ownFolder(for path: String) -> String {
        isTrashesOfDisk(path) ? "\(path)/\(uid)" : path
    }

    /// The folder that is listed for `path`: a disk's own Trash is shown as part of the one Trash, as is its ".Trashes"
    /// when its path is typed.
    func listedFolder(for path: String) -> String {
        path == homeAsSpelled || isOnOtherDisk(path) || isTrashesOfDisk(path) ? home : path
    }

    /// The folders listed along with `path`.
    public func listedWith(_ path: String) -> [String] {
        listedFolder(for: path) == home && !isOnOtherDisk(path) && !isTrashesOfDisk(path) ? onOtherDisks : []
    }

    /// The disk a Trash from `onOtherDisks` is on.
    static func disk(of trash: String) -> String {
        NodePath.dirname(NodePath.dirname(trash))
    }
}
