// Port of apps/desktop/src/renderer/lib/volumes.ts
import Foundation

/// Which disk a path is on, told from the path alone so a drag can show its cursor at once. macOS mounts
/// every other volume at /Volumes/<name>; everything else is on the startup disk.
public enum VolumePaths {
    private static let prefix = "/Volumes/"

    public static func volumeRootPath(_ path: String) -> String {
        // /^\/Volumes\/([^/]+)/
        guard path.hasPrefix(prefix) else { return "/" }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        return name.isEmpty ? "/" : prefix + name
    }

    /// The root of a volume: the startup disk ("/") or a disk mounted at /Volumes/<name>.
    public static func isVolumeRootPath(_ path: String) -> Bool {
        volumeRootPath(path) == path
    }

    public static func isOnSameVolume(_ first: String, _ second: String) -> Bool {
        volumeRootPath(first) == volumeRootPath(second)
    }
}
