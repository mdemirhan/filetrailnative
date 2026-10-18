// Port of apps/desktop/src/renderer/lib/treeView.test.ts
import Testing

@testable import FTFoundation

struct TreeViewTests {
    private func node(_ path: String, expanded: Bool, loaded: Bool, children: [String] = []) -> TreeNodeState {
        var node = TreeNodeState(path: path, name: String(path.split(separator: "/").last ?? "/"), expanded: expanded)
        node.loaded = loaded
        node.childPaths = children
        return node
    }

    // T-a5280d40
    @Test func returnsOnlyExpandedBranchesInDisplayOrder() {
        let nodes = TreeNodes([
            node("/root", expanded: true, loaded: true, children: ["/root/a", "/root/b"]),
            node("/root/a", expanded: true, loaded: true, children: ["/root/a/deep"]),
            node("/root/a/deep", expanded: false, loaded: false),
            node("/root/b", expanded: false, loaded: false),
        ])
        #expect(
            TreeView.flatten(rootPath: "/root", nodes: nodes) == [
                FlattenedTreeNode(path: "/root", depth: 0), FlattenedTreeNode(path: "/root/a", depth: 1),
                FlattenedTreeNode(path: "/root/a/deep", depth: 2), FlattenedTreeNode(path: "/root/b", depth: 1),
            ])
        #expect(TreeView.flatten(rootPath: "/missing", nodes: nodes).isEmpty)
    }

    private var nodes: TreeNodes {
        TreeNodes([
            node("/root", expanded: true, loaded: true, children: ["/root/a", "/root/b", "/root/loading"]),
            node("/root/a", expanded: true, loaded: true, children: ["/root/a/deep"]),
            node("/root/a/deep", expanded: false, loaded: false),
            node("/root/b", expanded: false, loaded: true, children: ["/root/b/child"]),
            node("/root/loading", expanded: false, loaded: false),
        ])
    }

    // T-c3c420b1 F-740
    @Test func movesThroughVisibleTreeRows() {
        #expect(
            TreeView.keyboardAction(key: .down, currentPath: "/root", rootPath: "/root", nodes: nodes)
                == .navigate(path: "/root/a"))
        #expect(
            TreeView.keyboardAction(key: .up, currentPath: "/root/a", rootPath: "/root", nodes: nodes)
                == .navigate(path: "/root"))
        #expect(
            TreeView.keyboardAction(key: .home, currentPath: "/root/b", rootPath: "/root", nodes: nodes)
                == .navigate(path: "/root"))
        #expect(
            TreeView.keyboardAction(key: .end, currentPath: "/root", rootPath: "/root", nodes: nodes)
                == .navigate(path: "/root/loading"))
    }
}
