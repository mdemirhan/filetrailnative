// Port of apps/desktop/src/renderer/lib/treeView.ts
import Foundation

/// A row of the expanded tree with its depth.
public struct FlattenedTreeNode: Equatable, Sendable {
    public var path: String
    public var depth: Int

    public init(path: String, depth: Int) {
        self.path = path
        self.depth = depth
    }
}

/// What a key does in the tree, as a decision; the caller carries it out.
public enum TreeKeyboardAction: Equatable, Sendable {
    case navigate(path: String)
    case expand(path: String)
    case collapse(path: String)
    case load(path: String)
    case none
}

public enum TreeView {
    public enum Key: Sendable {
        case up, down, left, right, home, end
    }

    /// `flattenVisibleTree`: the exact visual order of the expanded tree, depth included, for keyboard navigation and
    /// typeahead. Collapsed descendants are left out.
    public static func flatten(rootPath: String, nodes: TreeNodes) -> [FlattenedTreeNode] {
        guard nodes[rootPath] != nil else { return [] }
        var flattened: [FlattenedTreeNode] = []
        func walk(_ path: String, _ depth: Int) {
            guard let node = nodes[path] else { return }
            flattened.append(FlattenedTreeNode(path: path, depth: depth))
            guard node.expanded else { return }
            for child in node.childPaths { walk(child, depth + 1) }
        }
        walk(rootPath, 0)
        return flattened
    }

    /// `getTreeKeyboardAction`: maps arrow, Home and End keys to what to do, instead of changing state directly.
    public static func keyboardAction(key: Key, currentPath: String, rootPath: String, nodes: TreeNodes)
        -> TreeKeyboardAction
    {
        let visible = flatten(rootPath: rootPath, nodes: nodes)
        guard let first = visible.first else { return .none }
        let currentIndex = visible.firstIndex { JSString.equals($0.path, currentPath) }
        let currentNodePath = currentIndex != nil ? currentPath : first.path
        guard let currentNode = nodes[currentNodePath] else { return .none }

        switch key {
        case .home:
            return .navigate(path: first.path)
        case .end:
            return .navigate(path: visible[visible.count - 1].path)
        case .up:
            return .navigate(path: visible[max(0, (currentIndex ?? 0) - 1)].path)
        case .down:
            return .navigate(path: visible[min(visible.count - 1, (currentIndex ?? 0) + 1)].path)
        case .right:
            if currentNode.isSymlink { return .none }
            // Right lazily loads directories before trying to expand or enter them.
            if !currentNode.loaded { return .load(path: currentNode.path) }
            if !currentNode.expanded, !currentNode.childPaths.isEmpty { return .expand(path: currentNode.path) }
            if currentNode.expanded, let child = currentNode.childPaths.first { return .navigate(path: child) }
            return .none
        case .left:
            // Left collapses first; only once already collapsed does it move to the parent.
            if currentNode.expanded, !currentNode.childPaths.isEmpty { return .collapse(path: currentNode.path) }
            if JSString.equals(currentNode.path, rootPath) { return .none }
            let parent = parentPath(currentNode.path)
            return TreePaths.isWithinRoot(parent, rootPath) ? .navigate(path: parent) : .none
        }
    }

    /// The local `parentDirectoryPath` of treeView.ts: `/` for the top and for a top-level folder.
    private static func parentPath(_ path: String) -> String {
        if JSString.equals(path, "/") { return "/" }
        let parts = path.utf16.split(separator: 0x2F, omittingEmptySubsequences: false).dropLast()
        let joined = parts.map { JSString.string($0) }.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }
}
