// Port of the paste destination, top-level item, gone-item and busy-drag cases of
// apps/desktop/src/renderer/lib/explorerAppUtils.test.ts, and of the issue messages and toasts of
// hooks/useExplorerActions.ts
import Foundation
import Testing

@testable import FTFoundation

struct ClipboardTextsTests {
    private func resolve(
        menu: PasteDestination.Menu? = nil, entry: (String, EntryKind)? = nil,
        clipboard: [String] = ["/Users/demo/source.txt"], currentPath: String = "/Users/demo", search: Bool = false
    ) -> String? {
        PasteDestination.resolve(
            menu: menu, menuEntryPath: entry?.0, menuEntryKind: entry?.1, clipboardSourcePaths: clipboard,
            currentPath: currentPath, isSearchMode: search, homePath: "/Users/demo")
    }

    private func content(_ paths: [String], _ target: String) -> PasteDestination.Menu {
        PasteDestination.Menu(target: .content, targetPath: target, paths: paths)
    }

    // T-f987c23c
    // T-11201414 T-5a36953e T-7778e453 T-85ab3d1a T-a9b252b4 T-ffb0bc5e
    @Test func pastesIntoTheFolderOnScreenFromTheKeyboardOrMenuBarWhateverIsSelected() {
        #expect(resolve() == "/Users/demo")
        #expect(resolve(currentPath: "") == nil)
    }

    // T-a5707c40
    @Test func hasNoDestinationFromTheMenuOfSeveralItemsOrOfAFile() {
        #expect(
            resolve(
                menu: content(["/Users/demo/Folder", "/Users/demo/a.txt"], "/Users/demo/Folder"),
                entry: ("/Users/demo/Folder", .directory)) == nil)
        #expect(
            resolve(menu: content(["/Users/demo/a.txt"], "/Users/demo/a.txt"), entry: ("/Users/demo/a.txt", .file))
                == nil)
    }

    // T-862e2df5
    @Test func pastesIntoTheFolderOnScreenFromTheBackgroundsMenu() {
        #expect(resolve(menu: content([], "/Users/demo")) == "/Users/demo")
    }

    // T-3f922ef9
    @Test func pastesIntoARightClickedFolderWhenItIsTheOnlyItem() {
        #expect(
            resolve(
                menu: content(["/Users/demo/Folder"], "/Users/demo/Folder"), entry: ("/Users/demo/Folder", .directory))
                == "/Users/demo/Folder")
    }

    // T-09251d6a
    @Test func hasNoDestinationWhenTheFolderRightClickedIsItselfOnTheClipboard() {
        #expect(
            resolve(
                menu: content(["/Users/demo/Folder"], "/Users/demo/Folder"), entry: ("/Users/demo/Folder", .directory),
                clipboard: ["/Users/demo/Folder"]) == nil)
    }

    // T-7b1bc91e
    // T-1c693346
    @Test func pastesIntoAnAliasOfAFolderThroughIt() {
        #expect(
            resolve(
                menu: content(["/Users/demo/Linked"], "/Users/demo/Linked"),
                entry: ("/Users/demo/Linked", .symlinkDirectory))
                == "/Users/demo/Linked")
    }

    // T-d4b3c2fe
    @Test func hasNoDestinationInSearchResults() {
        #expect(resolve(search: true) == nil)
    }

    // T-cc6ebb98
    // T-adb6c85c
    @Test func neverPastesIntoTheTrashOrAFolderInIt() {
        #expect(resolve(currentPath: "/Users/demo/.Trash") == nil)
        #expect(
            resolve(
                menu: content(["/Users/demo/.Trash/Old"], "/Users/demo/.Trash/Old"),
                entry: ("/Users/demo/.Trash/Old", .directory)) == nil)
        #expect(
            resolve(menu: PasteDestination.Menu(target: .favorite, targetPath: "/Users/demo/.Trash", paths: [])) == nil)
        #expect(resolve(currentPath: "/Volumes/USB/.Trashes/501") == nil)
        #expect(
            resolve(menu: PasteDestination.Menu(target: .treeFolder, targetPath: "/Users/demo/Docs", paths: []))
                == "/Users/demo/Docs")
    }

    // T-068aeb28
    @Test func keepsItemsWithNothingListedAboveThemInTheirOriginalOrder() {
        let items: [String?] = ["/src/b", "/src/a/inner.txt", "/src/a", "/src/b/deep/x.txt", nil]
        #expect(PasteDestination.topLevelItems(items, path: { $0 }) == ["/src/b", "/src/a", nil])
    }

    // T-cd5ad501
    // T-37ebf0d0
    @Test func saysWhichClipboardItemsCouldNotBePastedBecauseTheyAreGone() {
        #expect(
            ClipboardTexts.missingClipboardItems(["/Users/demo/report.pdf"])
                == "\u{201C}report.pdf\u{201D} couldn\u{2019}t be pasted because it was moved or deleted since it was copied."
        )
        #expect(
            ClipboardTexts.missingClipboardItems(["/a/one", "/a/two"])
                == "\u{201C}one\u{201D} and \u{201C}two\u{201D} couldn\u{2019}t be pasted because they were moved or deleted since they were copied."
        )
        #expect(
            ClipboardTexts.missingClipboardItems(["/a/1", "/a/2", "/a/3", "/a/4"])
                == "4 items couldn\u{2019}t be pasted because they were moved or deleted since they were copied: \u{201C}1\u{201D}, \u{201C}2\u{201D}, \u{201C}3\u{201D} and 1 more."
        )
        #expect(
            ClipboardTexts.missingClipboardItems(["/a/one", "/a/two"], cut: true)
                == "\u{201C}one\u{201D} and \u{201C}two\u{201D} couldn\u{2019}t be moved because they were deleted or moved elsewhere since they were cut."
        )
    }

    // T-5bf8ee8d
    @Test func namesWhatIsRunningAndTheItemItIsOn() {
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "paste", currentSourcePath: "/Users/demo/Photos")
                == "Can't drag while \u{201C}Photos\u{201D} is being copied")
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "move_to", currentSourcePath: nil)
                == "Can't drag while items are being moved")
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "trash", currentSourcePath: "/Users/demo/a.txt")
                == "Can't drag while \u{201C}a.txt\u{201D} is being moved to the Trash")
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "delete_immediately", currentSourcePath: nil)
                == "Can't drag while items are being deleted")
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "rename", currentSourcePath: "/Users/demo/a.txt")
                == "Can't drag while \u{201C}a.txt\u{201D} is being renamed")
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "new_folder", currentSourcePath: nil)
                == "Can't drag while a folder is being made")
    }

    // T-b0c5c6c6
    @Test func saysADropCantBeMadeForADragFromAnotherApp() {
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "paste", currentSourcePath: "/Users/demo/Photos", drop: true)
                == "Can't drop while \u{201C}Photos\u{201D} is being copied")
        #expect(
            ClipboardTexts.dragRefusedWhileBusy(action: "new_folder", currentSourcePath: nil, drop: true)
                == "Can't drop while a folder is being made")
    }

    // B-CLIP-070
    // T-89efd829
    @Test func namesTheItemsAnAnalysisIssueIsAbout() {
        func issue(_ code: String, _ source: String?, _ message: String = "") -> ClipboardTexts.Issue {
            ClipboardTexts.Issue(code: code, sourcePath: source, destinationPath: nil, message: message)
        }
        let dest = "/Users/demo/Target"
        #expect(
            ClipboardTexts.issueMessage([issue("destination_missing", nil)], destinationDirectoryPath: dest, cut: false)
                == "The folder \u{201C}Target\u{201D} no longer exists.")
        #expect(
            ClipboardTexts.issueMessage(
                [issue("source_missing", "/a/x"), issue("source_missing", "/a/y"), issue("same_path", "/a/z")],
                destinationDirectoryPath: dest, cut: false)
                == "\u{201C}x\u{201D} and \u{201C}y\u{201D} no longer exist.")
        #expect(
            ClipboardTexts.issueMessage([issue("same_path", "/a/x")], destinationDirectoryPath: dest, cut: true)
                == "\u{201C}x\u{201D} is already in \u{201C}Target\u{201D}.")
        #expect(
            ClipboardTexts.issueMessage([issue("parent_into_child", "/a/x")], destinationDirectoryPath: dest, cut: true)
                == "\u{201C}x\u{201D} can't be moved into a folder inside itself.")
        #expect(
            ClipboardTexts.issueMessage(
                [issue("other", "/a/x", "It broke.")], destinationDirectoryPath: dest, cut: false)
                == "It broke.")
        #expect(
            ClipboardTexts.issueMessage([], destinationDirectoryPath: dest, cut: false)
                == "File Trail couldn\u{2019}t finish checking the items. Nothing was changed.")
    }

    // B-CLIP-073 B-CLIP-074
    // T-7567e39d T-e04b3e03
    @Test func leavesOutItemsAlreadyInPlaceOrGoneAndNothingElse() {
        func issue(_ code: String, _ source: String?) -> ClipboardTexts.Issue {
            ClipboardTexts.Issue(code: code, sourcePath: source, destinationPath: nil, message: "")
        }
        let sources = ["/a/x", "/a/y"]
        let both = ClipboardTexts.leftOutSourcePaths(
            [issue("same_path", "/a/x"), issue("source_missing", "/a/y")], sourcePaths: sources, alreadyInPlace: true,
            missing: true)
        #expect(both?.alreadyInPlace == ["/a/x"])
        #expect(both?.missing == ["/a/y"])
        #expect(
            ClipboardTexts.leftOutSourcePaths(
                [issue("same_path", "/a/x")], sourcePaths: sources, alreadyInPlace: false, missing: true) == nil)
        #expect(
            ClipboardTexts.leftOutSourcePaths(
                [issue("parent_into_child", "/a/x")], sourcePaths: sources, alreadyInPlace: true, missing: true) == nil)
        #expect(
            ClipboardTexts.leftOutSourcePaths(
                [issue("source_missing", "/b")], sourcePaths: sources, alreadyInPlace: true, missing: true) == nil)
        #expect(
            ClipboardTexts.missingClipboardItemsTitle(missing: 1, requested: 3, cut: false)
                == "An item couldn\u{2019}t be pasted")
        #expect(
            ClipboardTexts.missingClipboardItemsTitle(missing: 2, requested: 3, cut: true)
                == "Some items couldn\u{2019}t be moved")
        #expect(ClipboardTexts.missingClipboardItemsTitle(missing: 3, requested: 3, cut: false) == nil)
    }

    // T-eeefccac B-CLIP-130 B-VIEW-202: an Undo or Redo is told only when nothing it changed is in the folder on screen
    // and all of it went (the rest is the result sheet's).
    @Test func tellsAnUndoOrRedoOnlyWhenItIsOutOfSight() {
        func write(
            _ action: String, _ status: String = "completed",
            source: String? = "/Users/demo/Other/a.txt", destination: String? = "/Volumes/X/a.txt"
        ) -> WriteEndSummary {
            WriteEndSummary(
                action: action, status: status, targetPath: nil, topLevelItemCount: 1, completedItemCount: 1,
                failedItemCount: 0, skippedItemCount: 0, cancelledItemCount: 0,
                items: [WriteEndSummary.Item(sourcePath: source, destinationPath: destination, status: "completed")])
        }
        let label = "Move of \u{201C}source.txt\u{201D}"
        #expect(
            WriteEndNotices.toast(write("undo"), currentPath: "/Users/demo", undoLabel: label)
                == WriteEndToast(kind: .success, title: "Undone", message: label))
        #expect(
            WriteEndNotices.toast(write("redo"), currentPath: "/Users/demo", undoLabel: label)
                == WriteEndToast(kind: .success, title: "Redone", message: label))
        // Without a label, the title alone.
        #expect(
            WriteEndNotices.toast(write("undo"), currentPath: "/Users/demo")
                == WriteEndToast(kind: .success, title: "Undone", message: nil))
        #expect(
            WriteEndNotices.toast(write("undo"), currentPath: "/Users/demo", undoLabel: "")
                == WriteEndToast(kind: .success, title: "Undone", message: nil))
        // In sight: where an item came from, or where it went.
        #expect(WriteEndNotices.toast(write("undo"), currentPath: "/Users/demo/Other", undoLabel: label) == nil)
        #expect(WriteEndNotices.toast(write("redo"), currentPath: "/Volumes/X", undoLabel: label) == nil)
        // A path nil on either side, or the top of the disk, is no change in the folder on screen.
        #expect(
            WriteEndNotices.toast(write("undo", source: nil, destination: nil), currentPath: "/Users/demo")?.title
                == "Undone")
        #expect(WriteEndNotices.toast(write("undo", source: "/", destination: nil), currentPath: "")?.title == "Undone")
        // Anything but all of it done says nothing here.
        #expect(WriteEndNotices.toast(write("undo", "cancelled"), currentPath: "/Users/demo") == nil)
        #expect(WriteEndNotices.toast(write("undo", "partial"), currentPath: "/Users/demo") == nil)
        #expect(WriteEndNotices.toast(write("undo", "failed"), currentPath: "/Users/demo") == nil)
    }

    // B-CLIP-124 B-CLIP-126 B-CLIP-127 B-CLIP-128 B-CLIP-129
    // B-VIEW-196 B-VIEW-201 T-0cb1f30c T-16157729 T-740a332a T-a40978f7 T-da0c847b T-e0d60d23 T-fa0e2e01
    @Test func tellsAFinishedOperationInAToastOrASheet() {
        func write(
            _ action: String, _ status: String, completed: Int = 1, skipped: Int = 0, failed: Int = 0, top: Int = 1
        )
            -> WriteEndSummary
        {
            WriteEndSummary(
                action: action, status: status, targetPath: "/Users/demo/Target", topLevelItemCount: top,
                completedItemCount: completed, failedItemCount: failed, skippedItemCount: skipped,
                cancelledItemCount: 0,
                items: [
                    WriteEndSummary.Item(
                        sourcePath: "/a/notes.md", destinationPath: "/Users/demo/Target/notes.md", status: "completed")
                ]
                    + (skipped > 0
                        ? [
                            WriteEndSummary.Item(
                                sourcePath: "/a/b", destinationPath: nil, status: "skipped",
                                skipReason: "planned_conflict_policy")
                        ] : []))
        }
        let pasted = write("paste", "completed", top: 3)
        #expect(!WriteEndNotices.needsResultSheet(pasted))
        #expect(
            WriteEndNotices.toast(pasted)
                == WriteEndToast(
                    kind: .success, title: "Pasted into Target", message: "\u{201C}notes.md\u{201D} and 2 more"))
        #expect(WriteEndNotices.toast(write("move_to", "completed"))?.title == "Moved to Target")
        #expect(WriteEndNotices.toast(write("copy_to", "completed"))?.title == "Copied to Target")
        #expect(WriteEndNotices.toast(write("trash", "completed"))?.title == "Moved to Trash")
        #expect(WriteEndNotices.toast(write("delete_immediately", "completed"))?.title == "Deleted")
        #expect(WriteEndNotices.toast(write("duplicate", "completed")) == nil)
        #expect(WriteEndNotices.toast(write("move_to", "cancelled", completed: 0))?.title == "Move cancelled")
        #expect(WriteEndNotices.needsResultSheet(write("paste", "failed")))
        #expect(WriteEndNotices.needsResultSheet(write("paste", "cancelled", completed: 1)))
        #expect(!WriteEndNotices.needsResultSheet(write("paste", "cancelled", completed: 0)))
        let skippedOnly = write("paste", "partial", completed: 1, skipped: 1)
        #expect(!WriteEndNotices.needsResultSheet(skippedOnly))
        #expect(
            WriteEndNotices.toast(skippedOnly)
                == WriteEndToast(
                    kind: .info, title: "Paste finished with skipped items",
                    message: "Copied 1 item. Skipped 1 item that already exists."))
        // Dropped from another app into the folder on screen: in sight there.
        #expect(
            WriteEndNotices.toast(
                write("move_to", "completed"), quietOnScreen: true, currentPath: "/Users/demo/Target") == nil)
        #expect(
            WriteEndNotices.toast(write("move_to", "completed"), quietOnScreen: true, currentPath: "/elsewhere")?.title
                == "Moved to Target")
    }
}
