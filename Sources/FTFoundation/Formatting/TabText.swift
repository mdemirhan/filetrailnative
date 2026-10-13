// Port of the wording in apps/desktop/src/renderer/lib/explorerTabs.ts (getFolderDisplayName, describeTab)
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
    /// A folder's name as the tab strip and the path bar say it: "Macintosh HD" for the root.
    public static func folderDisplayName(_ path: String) -> String {
        if JSString.equals(path, "/") {
            return "Macintosh HD"
        }
        return path.isEmpty ? "" : PathText.leafName(path)
    }

    /// What a tab is called in the strip: its folder, or its search while results are showing.
    public static func describe(
        currentPath: String, searchVisible: Bool, searchQuery: String, searchRootPath: String, searchRunning: Bool
    ) -> TabDescription {
        if searchVisible, !JSString.trimmed(searchQuery).isEmpty {
            let root = searchRootPath.isEmpty ? currentPath : searchRootPath
            return TabDescription(
                label: "“\(searchQuery)” in \(folderDisplayName(root))",
                tooltip: "Searching \(root)",
                kind: .search,
                searching: searchRunning)
        }
        return TabDescription(
            label: currentPath.isEmpty ? "Favorites" : folderDisplayName(currentPath),
            tooltip: currentPath,
            kind: .folder,
            searching: false)
    }
}
