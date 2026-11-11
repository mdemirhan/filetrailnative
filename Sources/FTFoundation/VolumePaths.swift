import Foundation

/// Which disk a path is on, told from the path alone, without asking the disk. macOS mounts every other volume
/// at /Volumes/<name>; everything else is on the startup disk.
public enum VolumePaths {
    private static let prefix = "/Volumes/"

    /// What the startup disk is called until the app has read its name, and in tests: the name macOS gives it.
    public static let defaultStartupDiskName = "Macintosh HD"

    /// `/Volumes/<name>` for a path on another disk, otherwise `/`.
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
}
