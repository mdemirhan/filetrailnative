import Testing

@testable import FTFoundation

struct ShortcutTargetsTests {
    typealias Selection = ShortcutTargets.Selection

    @Test func prefersExplicitContextMenuPathsOverPaneSelection() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, contextMenuPaths: ["/tmp/context"],
                selectedContentPaths: ["/tmp/content"], currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/context"])
    }

    @Test func fallsBackToTheCurrentPathForTerminalWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree"])
    }

    @Test func fallsBackToTheTreePathForTerminalWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(focusedPane: .tree, lastFocusedPane: .tree, currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree"])
    }

    @Test func prefersTheExplicitSelectedTreePathForTerminalWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree-selected"])
    }

    @Test func usesTheContentSelectionWhenTheContentPaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .content, lastFocusedPane: .tree,
                selectedContentPaths: ["/tmp/content-a", "/tmp/content-b"], currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/content-a", "/tmp/content-b"])
    }

    @Test func fallsBackToTheCurrentPathForTerminalWhenFocusIsTemporarilyNullAfterTreeFocus() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: nil, lastFocusedPane: .tree, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree"])
    }

    @Test func fallsBackToTheCurrentPathWhenContentHasNoSelection() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(focusedPane: .content, lastFocusedPane: .tree, currentPath: "/tmp/current"))
        #expect(paths == ["/tmp/current"])
    }
}
