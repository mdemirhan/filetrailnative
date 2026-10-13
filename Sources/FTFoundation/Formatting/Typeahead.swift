// Port of apps/desktop/src/renderer/lib/typeahead.ts
import Foundation

/// A folder of the sidebar's tree, as typeahead needs it (the original's `TreeNodeState`).
public struct TypeaheadTreeNode: Equatable, Sendable {
    public var path: String
    public var name: String
    public var expanded: Bool
    public var childPaths: [String]

    public init(path: String, name: String, expanded: Bool, childPaths: [String]) {
        self.path = path
        self.name = name
        self.expanded = expanded
        self.childPaths = childPaths
    }
}

public enum Typeahead {
    /// Printable, non-whitespace characters start or extend the list filter and the sidebar's
    /// type-to-select. Navigation and modifier shortcuts are handled elsewhere. `key` is a
    /// `KeyboardEvent.key` value: one UTF-16 unit for a character, a name ("ArrowDown") otherwise.
    public static func isCharacterKey(_ key: String) -> Bool {
        key.utf16.count == 1 && !JSString.trimmed(key).isEmpty
    }

    /// Tree typeahead only searches visible nodes. Collapsed descendants are excluded so results
    /// always map to something the user can immediately see and select.
    public static func findTreeMatch(rootPath: String, nodes: [String: TypeaheadTreeNode], query: String)
        -> TypeaheadTreeNode?
    {
        let normalizedQuery = JSString.lowercased(JSString.trimmed(query))
        if normalizedQuery.isEmpty {
            return nil
        }
        for path in visiblePaths(rootPath: rootPath, nodes: nodes) {
            if let node = nodes[path], JSString.hasPrefix(JSString.lowercased(node.name), normalizedQuery) {
                return node
            }
        }
        return nil
    }

    // The exact visual order of the expanded tree (`flattenVisibleTree` of lib/treeView.ts).
    private static func visiblePaths(rootPath: String, nodes: [String: TypeaheadTreeNode]) -> [String] {
        var paths: [String] = []
        func walk(_ path: String) {
            guard let node = nodes[path] else { return }
            paths.append(path)
            guard node.expanded else { return }
            for child in node.childPaths {
                walk(child)
            }
        }
        walk(rootPath)
        return paths
    }
}
