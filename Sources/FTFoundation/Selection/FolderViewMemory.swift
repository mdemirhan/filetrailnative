// Port of apps/desktop/src/renderer/lib/folderViewMemory.ts
import Foundation

/// How a folder looked when it was left: what was selected and where the list was scrolled. Back and Forward show it that
/// way again.
public struct FolderViewMemory: Equatable, Sendable, Codable {
    public var selection: ContentSelection
    public var scrollTop: Double
    public var scrollLeft: Double

    public init(selection: ContentSelection, scrollTop: Double = 0, scrollLeft: Double = 0) {
        self.selection = selection
        self.scrollTop = scrollTop
        self.scrollLeft = scrollLeft
    }
}

/// Keyed by folder. Only the folders in the tab's history are kept: no other folder can be gone back to.
public typealias FolderViewMemories = [String: FolderViewMemory]

extension Dictionary where Key == String, Value == FolderViewMemory {
    /// `rememberFolderView`: keeps the memories of the folders in `historyPaths` and sets the one of `path`.
    public func remembering(_ memory: FolderViewMemory, at path: String, historyPaths: [String]) -> FolderViewMemories {
        let kept = Set(historyPaths)
        var next = filter { kept.contains($0.key) }
        next[path] = memory
        return next
    }
}
