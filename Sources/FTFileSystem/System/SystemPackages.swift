// Which folders the system shows as one item
import FTFoundation
import Foundation
import UniformTypeIdentifiers

/// macOS shows a folder as one item when it has the bundle bit or when its extension's type is declared a package, by
/// macOS or by an app (UTM's `.utm`, Parallels' `.pvm`). That is what `URLResourceKey.isPackageKey` answers: over 34,768
/// folders with an extension on this Mac, 825 of them packages, the two agreed on every one.
public enum SystemPackages {
    /// Whether folders with this extension (without its dot) are packages by their type: the system's types are asked,
    /// not the disk, so no folder is looked into (in `~/Library/Group Containers` a look at one costs 20 ms, as macOS
    /// checks whether the app may see other apps' data). About 6 µs.
    public static func isPackageType(_ fileExtension: String) -> Bool {
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension, conformingTo: .directory)
        else { return false }
        return type.conforms(to: .package)
    }

    /// What the system says of the folder at `path` (`URLResourceKey.isPackageKey`), for one item that no folder read
    /// gave: it reads the folder's bundle bit. Nil when it can't be asked (the folder is gone).
    public static func answer(_ path: String) -> Bool? {
        (try? DiskPath(path).url(isDirectory: true).resourceValues(forKeys: [.isPackageKey]))?.isPackage
    }

    /// Whether the folder at `path` is a package (`ItemNames.isPackageFolder`), for one item: by its extension when it
    /// is one of the list, otherwise as the system says, asked only when its name has another extension.
    public static func isPackageFolder(at path: String) -> Bool {
        ItemNames.isPackageFolder(named: NodePath.basename(path)) { answer(path) }
    }
}
