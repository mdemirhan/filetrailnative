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

/// Keyed by folder, by its path's bytes: two folders whose paths differ only in how an accent is encoded are left
/// each as it was. Only the folders in the tab's history are kept: no other folder can be gone back to.
public typealias FolderViewMemories = [DiskPath: FolderViewMemory]

extension Dictionary where Key == DiskPath, Value == FolderViewMemory {
    /// Keeps the memories of the folders in `historyPaths` and sets the one of `path`.
    public func remembering(_ memory: FolderViewMemory, at path: String, historyPaths: [String]) -> FolderViewMemories {
        let kept = Set(historyPaths.map { DiskPath($0) })
        var next = filter { kept.contains($0.key) }
        next[DiskPath(path)] = memory
        return next
    }

    /// How the folder at `path` was left, if it is remembered.
    public subscript(path: String) -> FolderViewMemory? {
        self[DiskPath(path)]
    }
}
