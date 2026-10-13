// Port of apps/desktop/src/renderer/lib/shortcutTargets.test.ts
import Testing

@testable import FTFoundation

struct ShortcutTargetsTests {
    typealias Selection = ShortcutTargets.Selection
    typealias RootTree = ShortcutTargets.RootTreeInput

    // T-64d38295
    @Test func prefersExplicitContextMenuPathsOverPaneSelection() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, contextMenuPaths: ["/tmp/context"],
                selectedContentPaths: ["/tmp/content"], currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/context"])
    }

    // T-4a5d74d8
    @Test func fallsBackToTheCurrentPathForTerminalWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree"])
    }

    // T-9801160c
    @Test func fallsBackToTheTreePathForTerminalWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(focusedPane: .tree, lastFocusedPane: .tree, currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree"])
    }

    // T-d34a2656
    @Test func prefersTheExplicitSelectedTreePathForTerminalWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree-selected"])
    }

    // T-49691608
    @Test func usesTheContentSelectionWhenTheContentPaneIsFocused() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: .content, lastFocusedPane: .tree,
                selectedContentPaths: ["/tmp/content-a", "/tmp/content-b"], currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/content-a", "/tmp/content-b"])
    }

    // T-b9e13056
    @Test func fallsBackToTheCurrentPathForTerminalWhenFocusIsTemporarilyNullAfterTreeFocus() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(
                focusedPane: nil, lastFocusedPane: .tree, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree"])
    }

    // T-dfb65e85
    @Test func fallsBackToTheCurrentPathWhenContentHasNoSelection() {
        let paths = ShortcutTargets.openInTerminalPaths(
            Selection(focusedPane: .content, lastFocusedPane: .tree, currentPath: "/tmp/current"))
        #expect(paths == ["/tmp/current"])
    }

    // T-14dfb80a
    @Test func doesNotFallBackToTheCurrentTreePathForOpenWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == [])
    }

    // T-91126de4
    @Test func doesNotFallBackToTheCurrentPathForOpenWhenFocusIsTemporarilyNullAfterTreeFocus() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .tree, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == [])
    }

    // T-0741865c
    @Test func prefersTheExplicitSelectedTreePathForOpenWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentPaths: ["/tmp/content"],
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/tree"))
        #expect(paths == ["/tmp/tree-selected"])
    }

    // T-856b8ed6
    @Test func doesNotFallBackToTheCurrentPathForOpenWhenFocusIsNullAfterTreeFocus() {
        let paths = ShortcutTargets.openSelectionPaths(
            Selection(
                focusedPane: nil, lastFocusedPane: .tree, selectedContentPaths: ["/tmp/content"],
                currentPath: "/tmp/tree"))
        #expect(paths == [])
    }

    // T-6e6ba032
    @Test func doesNotFallBackToTheCurrentPathForEditWithoutAFileSelection() {
        let paths = ShortcutTargets.editSelectionPaths(Selection(focusedPane: .tree, lastFocusedPane: .tree))
        #expect(paths == [])
    }

    // T-ca291e45
    @Test func prefersTheExplicitSelectedTreePathForEditWhenTheTreePaneIsFocused() {
        let paths = ShortcutTargets.editSelectionPaths(
            Selection(focusedPane: .tree, lastFocusedPane: .content, selectedTreePath: "/tmp/tree-selected"))
        #expect(paths == ["/tmp/tree-selected"])
    }

    // T-b8ab8735
    @Test func rootsTheTreeAtTheTreesSelectedFolderWhenTheTreePaneIsFocused() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(
                focusedPane: .tree, lastFocusedPane: .content, selectedContentFolderPath: "/tmp/content-folder",
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/current"))
        #expect(path == "/tmp/tree-selected")
    }

    // T-c3c608e7
    @Test func rootsTheTreeAtTheSingleFolderSelectedInTheFileList() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(
                focusedPane: .content, lastFocusedPane: .tree, selectedContentFolderPath: "/tmp/content-folder",
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/current"))
        #expect(path == "/tmp/content-folder")
    }

    // T-44caf5bc
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

    // T-ae4b9c5c
    @Test func rootsTheTreeAtTheRightClickedFolderWhileItsMenuIsOpen() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(
                focusedPane: .tree, lastFocusedPane: .tree, contextMenuFolderPath: "/tmp/context",
                selectedTreePath: "/tmp/tree-selected", currentPath: "/tmp/current"))
        #expect(path == "/tmp/context")
    }

    // T-3ada0d2e
    @Test func hasNoTreeRootTargetWhenNothingIsSelectedOrOnScreen() {
        let path = ShortcutTargets.rootTreeTargetPath(
            RootTree(focusedPane: .tree, lastFocusedPane: .tree, currentPath: ""))
        #expect(path == nil)
    }
}
