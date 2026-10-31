// Port of the resolveNewFolderTargetPath describe and of the New Folder name and Empty Trash failure cases of
// apps/desktop/src/renderer/lib/explorerAppUtils.test.ts
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

@Suite struct LocalWriteRulesTests {
    private let folder = (path: "/Users/demo/Folder", isDirectoryLike: true)
    private let file = (path: "/Users/demo/notes.txt", isDirectoryLike: false)

    private func target(
        _ selection: [(path: String, isDirectoryLike: Bool)], scope: LocalWriteRules.Scope? = nil,
        isSearchMode: Bool = false
    ) -> String? {
        LocalWriteRules.newFolderTargetPath(
            currentPath: "/Users/demo", selectedEntry: selection.first, selectedPaths: selection.map(\.path),
            isSearchMode: isSearchMode, homePath: "/Users/demo", scope: scope)
    }

    // As in Finder: ⇧⌘N makes it in the folder on screen whatever is selected, so two in a row don't nest the
    // second inside the first (which is selected once made).
    // F-297 T-7da9398e
    // T-24bd7058 T-b4a8467b T-cf63a4df
    @Test func makesTheFolderInTheFolderOnScreenFromTheKeyboardWhateverIsSelected() {
        #expect(target([]) == "/Users/demo")
        #expect(target([folder]) == "/Users/demo")
        #expect(target([file]) == "/Users/demo")
        #expect(target([folder, file]) == "/Users/demo")
        #expect(target([file, ("/Users/demo/more.txt", false)]) == "/Users/demo")
    }

    // F-297 T-a99d1d96
    // T-56b88ca6 T-9f23bfcd
    @Test func makesItInsideAFolderFromThatFoldersOwnMenuAndOffersNothingForAFileOrSeveralItems() {
        #expect(target([folder], scope: .selection) == "/Users/demo/Folder")
        #expect(target([file], scope: .selection) == nil)
        #expect(target([folder, file], scope: .selection) == nil)
        #expect(target([], scope: .selection) == "/Users/demo")
        // The menu opened on empty space is about the folder on screen, whatever is selected.
        #expect(target([file], scope: .background) == "/Users/demo")
    }

    // F-297 T-79a02757
    @Test func makesNothingInTheTrash() {
        #expect(
            LocalWriteRules.newFolderTargetPath(
                currentPath: "/Users/demo/.Trash", selectedEntry: nil, selectedPaths: [], isSearchMode: false,
                homePath: "/Users/demo") == nil)
        #expect(
            LocalWriteRules.newFolderTargetPath(
                currentPath: "/Users/demo", selectedEntry: ("/Users/demo/.Trash/Old", true),
                selectedPaths: ["/Users/demo/.Trash/Old"], isSearchMode: false, homePath: "/Users/demo",
                scope: .selection) == nil)
    }

    // T-e009a148
    @Test func hasNoTargetInSearchResultsOrWithoutAFolderOnScreen() {
        #expect(target([], isSearchMode: true) == nil)
        #expect(target([file], isSearchMode: true) == nil)
        #expect(
            LocalWriteRules.newFolderTargetPath(
                currentPath: "", selectedEntry: nil, selectedPaths: [], isSearchMode: false, homePath: "/Users/demo")
                == nil)
    }

    // F-297 T-e872cd80 T-8cdccb11
    // B-CLIP-199
    @Test func suggestsAFreeNewFolderNameIgnoringCaseLikeTheDiskDoes() {
        #expect(LocalWriteRules.freeNewFolderName([]) == "untitled folder")
        #expect(LocalWriteRules.freeNewFolderName(["untitled folder"]) == "untitled folder 2")
        #expect(LocalWriteRules.freeNewFolderName(["Untitled Folder", "UNTITLED FOLDER 2"]) == "untitled folder 3")
        #expect(LocalWriteRules.freeNewFolderName(["untitled folder", "untitled folder 3"]) == "untitled folder 2")
    }

    // F-304 F-305 T-9407a866
    @Test func explainsAnEmptyTrashFailureAndHowToAllowFileTrailToControlFinder() {
        let title = "Couldn\u{2019}t Empty the Trash"
        let denied = LocalWriteRules.describeEmptyTrashFailure(
            "execution error: Not authorized to send Apple events to Finder. (-1743)")
        #expect(denied.title == title)
        #expect(
            denied.message
                == "File Trail needs permission to control Finder. Turn it on in System Settings > Privacy & Security > Automation, then try again."
        )
        let other = LocalWriteRules.describeEmptyTrashFailure("Finder got an error: The operation can't be completed.")
        #expect(other.title == title)
        #expect(other.message == "Finder got an error: The operation can't be completed.")
        // A large Trash takes Finder longer than AppleScript waited before (two minutes).
        #expect(
            LocalWriteRules.describeEmptyTrashFailure(
                "execution error: Finder got an error: AppleEvent timed out. (-1712)"
            ).message == "Finder took too long to answer. It may still be emptying the Trash.")
        #expect(
            LocalWriteRules.describeEmptyTrashFailure("execution error: User canceled. (-128)").message
                == "Emptying the Trash was stopped in Finder.")
        // Only the reason: never the command that ran or the error number.
        #expect(
            LocalWriteRules.describeEmptyTrashFailure(
                "0:46: execution error: Finder got an error: The operation can\u{2019}t be completed. (-8003)"
            ).message == "Finder got an error: The operation can\u{2019}t be completed.")
        #expect(
            LocalWriteRules.describeEmptyTrashFailure("  ").message
                == "Finder didn't empty the Trash. Try again, or empty it in Finder.")
    }
}
