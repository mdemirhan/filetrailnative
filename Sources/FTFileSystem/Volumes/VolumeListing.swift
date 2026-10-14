// Port of packages/native-fs/src/native_volumes.c (nativeListVolumes, nativeListMounts)
import Darwin
import Foundation

/// One row of the kernel's mount table.
public struct MountRecord: Sendable, Equatable {
    public var path: String
    public var source: String
    public var fileSystem: String
    public var flags: UInt32

    public init(path: String, source: String, fileSystem: String, flags: UInt32) {
        self.path = path
        self.source = source
        self.fileSystem = fileSystem
        self.flags = flags
    }

    public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
    public var isReadOnly: Bool { flags & UInt32(MNT_RDONLY) != 0 }
    public var isDontBrowse: Bool { flags & UInt32(MNT_DONTBROWSE) != 0 }
}

/// A mount and whether it is local: what holds a path, to tell a network share from a local disk.
public struct MountPoint: Sendable, Equatable {
    public var path: String
    public var isLocal: Bool
}

/// The disks mounted besides the startup disk, as Finder's sidebar lists them. Read from the kernel's mount
/// table with `getmntinfo(MNT_NOWAIT)`, which never asks a file system (a network share that stopped
/// answering would block), so it is quick enough for the main thread.
public enum VolumeListing {
    static let volumesPrefix = "/Volumes/"
    static let devPrefix = "/dev/"

    public static func mounts() -> [MountRecord] {
        var table: UnsafeMutablePointer<statfs>?
        // The reentrant variant: the plain one returns a buffer shared by every caller.
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard count > 0, let table else { return [] }
        defer { free(table) }
        return (0..<Int(count)).map { MountRecord(table[$0]) }
    }

    /// `nativeListMounts`: every mount, wherever it is mounted and however it is marked.
    public static func listMounts() -> [MountPoint] {
        mounts().map { MountPoint(path: $0.path, isLocal: $0.isLocal) }
    }

    /// `nativeListVolumes`, in the order of the mount table (see `Volume.sorted`).
    public static func listVolumes(
        physicalDisk: (String) -> PhysicalDisk? = PhysicalDisk.lookup(bsdName:)
    ) -> [Volume] {
        volumes(from: mounts(), physicalDisk: physicalDisk)
    }

    public static func volumes(from mounts: [MountRecord], physicalDisk: (String) -> PhysicalDisk?) -> [Volume] {
        var volumes: [Volume] = []
        for mount in mounts {
            guard mount.path.hasPrefix(volumesPrefix) else { continue }
            let name = String(mount.path.dropFirst(volumesPrefix.count))
            // A disk mounted deeper than /Volumes/<name>, or with a hidden name.
            if name.isEmpty || name.hasPrefix(".") || name.contains("/") { continue }
            // Time Machine's snapshots and the system's own volumes, which Finder doesn't show either.
            if mount.isDontBrowse { continue }
            let disk = deviceDisk(of: mount, physicalDisk)
            volumes.append(
                Volume(
                    path: mount.path, name: name, isLocal: mount.isLocal, isReadOnly: mount.isReadOnly,
                    fileSystem: mount.fileSystem,
                    // A network share, or another mount not on a device, is unmounted as Finder ejects it.
                    canEject: disk?.ejectable ?? true, disk: disk?.whole))
        }
        return volumes
    }

    /// The physical disk a mount is on; nil when its source isn't a device.
    static func deviceDisk(of mount: MountRecord, _ physicalDisk: (String) -> PhysicalDisk?) -> PhysicalDisk? {
        guard mount.source.hasPrefix(devPrefix) else { return nil }
        return physicalDisk(String(mount.source.dropFirst(devPrefix.count)))
    }
}

extension MountRecord {
    init(_ entry: statfs) {
        var entry = entry
        self.init(
            path: Self.string(&entry.f_mntonname), source: Self.string(&entry.f_mntfromname),
            fileSystem: Self.string(&entry.f_fstypename), flags: entry.f_flags)
    }

    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
