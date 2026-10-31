// Port of apps/desktop/src/renderer/lib/{pagedScroll,entriesAtPaths,explorerPaneFocus,focusedEditTarget,folderViewMemory}.test.ts
import Testing

@testable import FTFoundation

struct PagedScrollTests {
    // T-866df106 B-SEL-056
    @Test func scrollsSidewaysByTheAmount() {
        #expect(
            PagedScroll.nextOffset(viewportSize: 480, scrollSize: 1800, currentOffset: 240, delta: 310) == 550)
    }

    // T-b89b3345 B-SEL-056
    @Test func scrollsUpAndDownStoppingAtEitherEnd() {
        #expect(PagedScroll.nextOffset(viewportSize: 300, scrollSize: 850, currentOffset: 500, delta: 300) == 550)
        #expect(PagedScroll.nextOffset(viewportSize: 300, scrollSize: 850, currentOffset: 550, delta: -900) == 0)
    }

    // T-9376e8bb N/A: the native views read the scroll position from their scroll view and need no synthetic scroll event.

    // T-b7e58442 B-SEL-056
    @Test func returnsNilWhenTheViewCantScrollThatWayOrIsAlreadyAtTheEnd() {
        #expect(PagedScroll.nextOffset(viewportSize: 320, scrollSize: 320, currentOffset: 0, delta: 100) == nil)
        #expect(PagedScroll.nextOffset(viewportSize: 480, scrollSize: 960, currentOffset: 0, delta: -100) == nil)
        #expect(PagedScroll.nextOffset(viewportSize: 480, scrollSize: 960, currentOffset: 0, delta: 0) == nil)
        // A scroll of a point or less scrolls nothing.
        #expect(PagedScroll.nextOffset(viewportSize: 480, scrollSize: 960, currentOffset: 100, delta: 1) == nil)
    }
}

struct PathIndexTests {
    struct Item: Equatable {
        var path: String
        var name: String
    }

    // T-b8aced91
    @Test func givesTheItemsInTheOrderOfThePathsLeavingOutPathsNotInTheList() {
        let items = ["/a", "/b", "/c"].map { Item(path: $0, name: $0) }
        let index = PathIndex(items, path: \.path)
        #expect(index.resolve(["/c", "/gone", "/a"]) == [items[2], items[0]])
        #expect(index.resolve([]) == [])
    }

    // T-5ab32328
    @Test func findsTheFirstOfTwoItemsWithOnePathAsASearchFromTheStartWould() {
        let index = PathIndex([Item(path: "/a", name: "first"), Item(path: "/a", name: "second")], path: \.path)
        #expect(index.find("/a")?.name == "first")
        #expect(index.resolve(["/a"]).first?.name == "first")
    }

    // T-39d8d1ef
    @Test func answersForANewListOfItemsNotTheOneAskedAboutBefore() {
        let before = PathIndex([Item(path: "/a", name: "a")], path: \.path)
        let after = PathIndex([Item(path: "/b", name: "b")], path: \.path)
        #expect(before.find("/a")?.name == "a")
        #expect(after.find("/a") == nil)
        #expect(after.find("/b")?.name == "b")
        #expect(after.find(nil) == nil)
    }
}

struct ExplorerPaneFocusTests {
    private func target(
        _ preferred: FocusedPane?, _ last: FocusedPane?, tree: Bool = true, content: Bool = true
    ) -> FocusedPane? {
        ExplorerPaneFocus.restoreTarget(
            preferred: preferred, lastFocused: last, hasTreePane: tree, hasContentPane: content)
    }

    // T-d31fcc50 B-SEL-167
    @Test func prefersAnExplicitRestoreTargetWhenAvailable() {
        #expect(target(.tree, .content) == .tree)
    }

    // T-e18743bf B-SEL-167
    @Test func fallsBackToTheLastFocusedPaneForTransientBlurRestoration() {
        #expect(target(nil, .tree) == .tree)
    }

    // T-c8da9016 B-SEL-167
    @Test func fallsBackToContentWhenNoPriorPaneIsKnownAndContentExists() {
        #expect(target(nil, nil) == .content)
    }

    // T-dafaf1c9 B-SEL-167
    @Test func fallsBackToTreeWhenContentIsUnavailable() {
        #expect(target(nil, nil, content: false) == .tree)
    }

    // T-60da3e1b B-SEL-167
    @Test func returnsNilWhenNoExplorerPaneCanBeFocused() {
        #expect(target(.tree, .content, tree: false, content: false) == nil)
    }
}

struct FocusedEditTargetTests {
    private func input(_ type: String, readOnly: Bool = false, disabled: Bool = false) -> FocusedElement {
        FocusedElement(kind: .input(type: type), isDisabled: disabled, isReadOnly: readOnly)
    }

    // T-965032bb B-SEL-164
    @Test func detectsEditableTextInputs() {
        #expect(FocusedEditTargets.resolve(input("text")) == .editableText)
    }

    // T-72765261 B-SEL-164
    @Test func detectsSearchInputs() {
        #expect(FocusedEditTargets.resolve(input("search")) == .editableText)
    }

    // T-0eb60e72 B-SEL-164
    @Test func detectsTextareas() {
        #expect(FocusedEditTargets.resolve(FocusedElement(kind: .textarea)) == .editableText)
    }

    // T-023241db B-SEL-164
    @Test func detectsContenteditableDescendants() {
        #expect(FocusedEditTargets.resolve(FocusedElement(kind: .other, isContentEditable: true)) == .editableText)
    }

    // T-25f87439 B-SEL-164
    @Test func classifiesReadonlyTextInputsSeparately() {
        #expect(FocusedEditTargets.resolve(input("email", readOnly: true)) == .readonlyText)
    }

    // T-a4f0a1fd B-SEL-164
    @Test func treatsDisabledTextInputsAsNonText() {
        #expect(FocusedEditTargets.resolve(input("text", disabled: true)) == .nonText)
    }

    // T-6e22ab84 B-SEL-165
    @Test func rejectsSelects() {
        let select = FocusedElement(kind: .select)
        #expect(FocusedEditTargets.resolve(select) == .nonText)
        #expect(FocusedEditTargets.isKeyboardOwnedFormControl(select))
        #expect(!FocusedEditTargets.isKeyboardOwnedFormControl(FocusedElement(kind: .select, isDisabled: true)))
    }

    // T-ce8e7e6c B-SEL-164
    @Test func rejectsColorInputs() {
        #expect(FocusedEditTargets.resolve(input("color")) == .nonText)
    }

    // T-2dda7e98 B-SEL-164
    @Test func rejectsNonTextInputTypes() {
        for type in ["checkbox", "radio", "range", "file", "button"] {
            #expect(FocusedEditTargets.resolve(input(type)) == .nonText, "\(type)")
        }
    }

    // T-ddd43975 B-SEL-164
    @Test func honorsEditableCustomMarkers() {
        #expect(FocusedEditTargets.resolve(FocusedElement(kind: .other, marker: .editable)) == .editableText)
    }

    // T-a31fcc6d B-SEL-164
    @Test func honorsReadonlyCustomMarkers() {
        #expect(FocusedEditTargets.resolve(FocusedElement(kind: .other, marker: .readonly)) == .readonlyText)
    }

    // T-f797d02e B-SEL-162
    @Test func givesAPaneTheKeyboardForItsListButNotForATextFieldInsideIt() {
        #expect(FocusedEditTargets.focusGivesPaneTheKeyboard(FocusedElement(kind: .other)))
        #expect(FocusedEditTargets.focusGivesPaneTheKeyboard(input("checkbox")))
        #expect(!FocusedEditTargets.focusGivesPaneTheKeyboard(input("text")))
        #expect(FocusedEditTargets.focusGivesPaneTheKeyboard(nil))
    }

    // T-59350e27 B-SEL-162: the rename field stands in for the item it renames and keeps its own keys.
    @Test func keepsThePanesKeyboardForTheInlineRenameField() {
        let rename = FocusedElement(kind: .input(type: "text"), isInlineRenameField: true)
        #expect(FocusedEditTargets.focusGivesPaneTheKeyboard(rename))
    }
}

struct FolderViewMemoryTests {
    // T-2e08aed7 B-NAV-045
    // B-SEL-117
    @Test func keepsTheFoldersInTheHistoryAndReplacesTheOneLeft() {
        let view = FolderViewMemory(selection: .empty, scrollTop: 120, scrollLeft: 0)
        let memories: FolderViewMemories = ["/a": view, "/b": view, "/gone": view]
        let left = FolderViewMemory(selection: .empty, scrollTop: 300, scrollLeft: 0)
        #expect(memories.remembering(left, at: "/b", historyPaths: ["/a", "/b"]) == ["/a": view, "/b": left])
    }
}
