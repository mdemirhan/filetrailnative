// The files File ▸ New File makes new files from: those of the Templates folder
import FTFoundation
import Foundation

public enum NewFileTemplates {
    /// What New File ▸ Text File calls its file ("untitled 2.txt" when taken).
    public static let textFileName = "untitled.txt"

    /// The files in `folder` a new file can be made from, by name in the order names are sorted: plain files, or links
    /// to them. Folders and packages are left out (copying those is a paste's job), and so are names that start with
    /// a dot (hidden, as Finder's `.DS_Store`). None when the folder isn't there.
    public static func names(in folder: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return
            names
            .filter { name in
                guard !ItemNames.isHidden(name) else { return false }
                var isFolder: ObjCBool = false
                let path = (folder as NSString).appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            }
            .sorted { naturalCompare($0, $1) == .orderedAscending }
    }
}
