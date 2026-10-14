// Port of apps/desktop/src/main/bootstrap/diskHasTrash.ts and nativeListMounts (packages/native-fs/src/native_volumes.c)
import Darwin
import Foundation

/// A mount in the mount table: where it is mounted, and whether it is a local disk.
public struct Mount: Equatable, Sendable {
    public var path: String
    public var isLocal: Bool

    public init(path: String, isLocal: Bool) {
        self.path = path
        self.isLocal = isLocal
    }
}

public enum MountTable {
    /// `nativeListMounts`: `getmntinfo(MNT_NOWAIT)`.
    public static func list() -> [Mount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count))
        let size = Int32(MemoryLayout<statfs>.stride * buffer.count)
        let filled = getfsstat(&buffer, size, MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map { entry in
            var entry = entry
            let path = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return Mount(path: path, isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }

    /// `fs.realpathSync.native`.
    public static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Whether the disk holding a path has a Trash, for telling if copies made there can be undone. macOS can't be asked
/// without making a Trash folder on the disk, so this goes by the kind of disk: a network share is taken to have
/// none (Finder deletes there at once), anything else to have one. The path is followed through symlinks first
/// (~/NAS may be /Volumes/NAS), and compared with every mount, wherever it is mounted, ignoring case as the startup
/// disk does.
public func makeDiskHasTrash(
    listMounts: @escaping @Sendable () -> [Mount] = MountTable.list,
    realPath: @escaping @Sendable (String) throws -> String = MountTable.realPath
) -> @Sendable (String) -> Bool {
    { path in
        let key = realPathOf(path, realPath).lowercased()
        var holding: Mount?
        for mount in listMounts() {
            let mountKey = mount.path.lowercased()
            let inside = key == mountKey || key.hasPrefix(mountKey.hasSuffix("/") ? mountKey : mountKey + "/")
            // JavaScript compares string lengths in UTF-16 units.
            if inside && (holding == nil || mount.path.utf16.count > (holding?.path.utf16.count ?? 0)) {
                holding = mount
            }
        }
        return holding?.isLocal ?? true
    }
}

/// Where a path really is: the nearest part of it that exists, followed through symlinks, with the rest added back.
private func realPathOf(_ path: String, _ realPath: (String) throws -> String) -> String {
    var rest: [String] = []
    var current = path
    while true {
        do {
            return join(try realPath(current), rest)
        } catch {
            let parent = ApplicationPaths.dirname(current)
            if parent == current { return path }
            rest.insert(ApplicationPaths.basename(current), at: 0)
            current = parent
        }
    }
}

private func join(_ base: String, _ rest: [String]) -> String {
    guard !rest.isEmpty else { return base }
    let parts = ([base] + rest).joined(separator: "/")
    return ApplicationPaths.normalize(parts)
}
