// Port of the Volume type in packages/contracts/src/ipc.ts and the sort in apps/desktop/src/main/volumes.ts
import Foundation

/// A disk mounted besides the startup disk: a drive, a disk image or a network share.
public struct Volume: Sendable, Equatable {
    /// Where it is mounted: /Volumes/<name>.
    public var path: String
    public var name: String
    /// False for a network share.
    public var isLocal: Bool
    public var isReadOnly: Bool
    /// apfs, hfs, exfat, smbfs...; empty when not known.
    public var fileSystem: String
    /// Whether Finder offers to eject it.
    public var canEject: Bool
    /// The physical disk it is on ("disk5"); nil for a network share.
    public var disk: String?

    public init(
        path: String, name: String, isLocal: Bool, isReadOnly: Bool, fileSystem: String, canEject: Bool,
        disk: String?
    ) {
        self.path = path
        self.name = name
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.fileSystem = fileSystem
        self.canEject = canEject
        self.disk = disk
    }
}

/// `a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" })`: numbers in order, case and
/// accents aside.
func naturalCompare(_ first: String, _ second: String) -> ComparisonResult {
    first.compare(
        second, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil,
        locale: Locale(identifier: "en_US"))
}

/// A stable sort by natural order of a key, as `Array.prototype.sort` is.
func naturallySorted<T>(_ items: [T], by key: (T) -> String) -> [T] {
    items.enumerated().sorted { first, second in
        switch naturalCompare(key(first.element), key(second.element)) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return first.offset < second.offset
        }
    }.map(\.element)
}

extension Volume {
    /// Disks by name, numbers in order and letter case aside.
    public static func sorted(_ volumes: [Volume]) -> [Volume] {
        naturallySorted(volumes, by: \.name)
    }
}
