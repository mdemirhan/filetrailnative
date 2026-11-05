import Testing

@testable import FTFoundation

struct ShortcutTargetsTests {
    typealias Selection = ShortcutTargets.Selection
    typealias RootTree = ShortcutTargets.RootTreeInput

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

    @Test func doesNotFallBackToTheCurrentTreePathForOpenWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == [])
    }

    @Test func doesNotFallBackToTheCurrentPathForOpenWhenFocusIsTemporarilyNullAfterTreeFocus() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .tree, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == [])
    }

    @Test func prefersTheExplicitSelectedTreePathForOpenWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree-selected"])
    }

    @Test func doesNotFallBackToTheCurrentPathForOpenWhenFocusIsNullAfterTreeFocus() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: nil, lastFocusedPane: .tree, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == [])
    }

    @Test func doesNotFallBackToTheCurrentPathForEditWithoutAFileSelection() {
        let paths = ShortcutTargets.editSelectionPaths(Selection(focusedPane: .tree, lastFocusedPane: .tree))
        #expect(paths == [])
    }

    @Test func prefersTheExplicitSelectedTreePathForEditWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.editSelectionPaths(
            Selection(focusedPane: .tree, lastFocusedPane: .content, selectedTreePath: "/tmp/tree-selected"))
        #expect(paths == ["/tmp/tree-selected"])
    }

    @Test func rootsTheTreeAtTheTreesSelectedFolderWhenTheTreePaneIsFocused() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentFolderPath: "/tmp/content-folder",
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/current"))
        #expect(path == "/tmp/tree-selected")
    }

    @Test func rootsTheTreeAtTheSingleFolderSelectedInTheFileList() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(
                focusedPane: .content, lastFocusedPane: .tree, selectedContentFolderPath: "/tmp/content-folder",
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/current"))
        #expect(path == "/tmp/content-folder")
    }

    @Test func rootsTheTreeAtTheFolderOnScreenWhenTheSelectionIsNotASingleFolder() {
        let content = ShortcutTargets.rootTreeTargetPath(
            RootTree(
                focusedPane: .content, lastFocusedPane: .content, selectedTreePath: "/tmp/tree-selected",
                currentPath: "/tmp/current"))
        #expect(content == "/tmp/current")
        let none = ShortcutTargets.rootTreeTargetPath(
            RootTree(focusedPane: nil, lastFocusedPane: .tree, currentPath: "/tmp/current"))
        #expect(none == "/tmp/current")
    }

    @Test func rootsTheTreeAtTheRightClickedFolderWhileItsMenuIsOpen() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(
                focusedPane: .tree, lastFocusedPane: .tree, contextMenuFolderPath: "/tmp/context",
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/current"))
        #expect(path == "/tmp/context")
    }

    @Test func hasNoTreeRootTargetWhenNothingIsSelectedOrOnScreen() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(focusedPane: .tree, lastFocusedPane: .tree, currentPath: ""))
        #expect(path == nil)
    }
}
