// A rename of several items in folders whose paths differ only in how an accent is stored
import Foundation
import Testing

@testable import FTFoundation

/// "café" with its "é" as one scalar, and as an "e" with the accent after it: two folders on a disk that keeps both.
struct BatchRenameAccentTwinsTests {
    private let composed = "/disk/caf\u{E9}"
    private let decomposed = "/disk/cafe\u{301}"
    private let settings = BatchRenameSettings(find: "a", replaceWith: "b")

    private func item(_ path: String) -> BatchRenameItem {
        BatchRenameItem(path: path, name: JSString.components(path, separator: 0x2F).last ?? path)
    }

    private func name(_ planned: BatchRenamePlanItem) -> String {
        switch planned {
        case .unchanged: "unchanged"
        case .rename(let name, _, _, _, _, _): name
        case .problem(_, _, .cannotRename(let message)): message
        case .problem(let name, _, _): "problem:\(name)"
        }
    }

    // Each folder's own names decide whether a new name is taken in it.
    @Test func eachFoldersNamesAreItsOwn() {
        let folders = [
            DiskPath(composed): BatchRenameFolder(names: ["a.txt", "b.txt"], caseSensitive: true),
            DiskPath(decomposed): BatchRenameFolder(names: ["a.txt"], caseSensitive: true),
        ]
        let plan = BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: settings, items: [item(composed + "/a.txt"), item(decomposed + "/a.txt")],
                folders: folders, now: "2026-10-04T11:32:10"))
        // "b.txt" is taken in the first folder and free in the second.
        #expect(plan.items.map(name) == ["b 2.txt", "b.txt"])
    }

    // An item that can't be renamed is that item, not the one whose path differs so.
    @Test func whatCantBeRenamedIsEachItemsOwn() {
        let cannotRename = [
            DiskPath(composed): "The first is locked.", DiskPath(decomposed): "The second is locked.",
        ]
        let settings = BatchRenameSettings(find: "caf", replaceWith: "bar")
        let both = BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: settings, items: [item(composed), item(decomposed)], cannotRename: cannotRename,
                now: "2026-10-04T11:32:10"))
        #expect(both.items.map(name) == ["The first is locked.", "The second is locked."])
    }
}
