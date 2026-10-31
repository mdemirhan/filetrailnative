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

    /// The folder that is listed for `path`: a disk's own Trash is shown as part of the one Trash.
    func listedFolder(for path: String) -> String {
        path == homeAsSpelled || isOnOtherDisk(path) ? home : path
    }

    /// The folders listed along with `path`.
    public func listedWith(_ path: String) -> [String] {
        listedFolder(for: path) == home && !isOnOtherDisk(path) ? onOtherDisks : []
    }

    /// The disk a Trash from `onOtherDisks` is on.
    static func disk(of trash: String) -> String {
        NodePath.dirname(NodePath.dirname(trash))
    }
}
