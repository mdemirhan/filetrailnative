import Darwin
import FTFoundation
import Foundation

/// A path respelled as its disk has it, for one that didn't come from a listing: typed, picked in a panel, dropped,
/// given at launch, or saved by an earlier run. The disk is asked, so this is not for the main thread's hot paths.
/// The rest of the path's dealings with `URL` are in FTFoundation (`url(isDirectory:)`, `init(urlSpelling:)`).
extension DiskPath {
    /// The path as the disk spells it, which is how a listing spells it: every link followed, "." and ".." and
    /// doubled slashes resolved, and each part named as its folder holds it, accents and letter case included
    /// (`realpath`). A link at the end is followed too: the answer is where it leads. When nothing is at the path
    /// yet (a name to save under, a folder about to be made), the folder it would be in as the disk spells it, and
    /// the name as given. The path unchanged when that folder can't be found either.
    public func asOnDisk() -> DiskPath {
        if let real = Self.realPath(string) { return DiskPath(real) }
        let name = name
        guard !name.isEmpty, let folder = Self.realPath(parent.string) else { return self }
        return DiskPath(folder).appending(name)
    }

    /// The home folder as the disk spells it, read once.
    public static let home = DiskPath(NSHomeDirectory()).asOnDisk()

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
