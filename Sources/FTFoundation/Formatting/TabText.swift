import Foundation

public struct TabDescription: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case folder
        case search
    }

    public var label: String
    public var tooltip: String
    public var kind: Kind
    public var searching: Bool
}

public enum TabText {
    /// A folder's name as the tab strip and the toolbar say it: the startup disk's name for the root, and "Trash" for
    /// a Trash folder (the home folder's ".Trash", a disk's ".Trashes" and each user's Trash in that), as the path bar
    /// and the sidebar call it.
    public static func folderDisplayName(
        _ path: String, homePath: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> String {
        if JSString.equals(path, "/") {
            return startupDiskName
        }
        if path.isEmpty { return "" }
        return Paths.isTrashFolder(path, homePath: homePath) ? "Trash" : PathText.leafName(path)
    }

    /// What a tab is called in the strip: its folder, or its search while results are showing.
    public static func describe(
        currentPath: String, searchVisible: Bool, searchQuery: String, searchRootPath: String, searchRunning: Bool,
        homePath: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> TabDescription {
        func name(_ path: String) -> String {
            folderDisplayName(path, homePath: homePath, startupDiskName: startupDiskName)
        }
        if searchVisible, !JSString.trimmed(searchQuery).isEmpty {
            let root = searchRootPath.isEmpty ? currentPath : searchRootPath
            return TabDescription(
                label: "“\(searchQuery)” in \(name(root))",
                tooltip: "Searching \(root)",
                kind: .search,
                searching: searchRunning)
        }
        return TabDescription(
            label: currentPath.isEmpty ? "Favorites" : name(currentPath),
            tooltip: currentPath,
            kind: .folder,
            searching: false)
    }
}
