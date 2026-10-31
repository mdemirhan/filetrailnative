// A Trash of the tests' own, so that no test run can leave anything in the user's
import FTOperations
import Foundation

extension TrashItem {
    /// Moves an item to a folder of this test process and says where it went, as the system's Trash does (a name taken
    /// there gets a new one). Undo puts it back from there.
    static var standIn: TrashItem {
        let fileSystem = PosixFileSystem()
        return TrashItem(
            trash: { path in
                let manager = FileManager.default
                let folder = StandInTrash.folder
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = (path as NSString).lastPathComponent
                var target = folder.appendingPathComponent(name)
                if manager.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent(UUID().uuidString + " " + name)
                }
                try manager.moveItem(atPath: path, toPath: target.path)
                return target.path
            },
            lstat: { try fileSystem.lstat($0) }, getFlags: NativeFS.getFlags,
            homePath: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

enum StandInTrash {
    static let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("filetrail-test-trash-\(getpid())/.Trash")
}
