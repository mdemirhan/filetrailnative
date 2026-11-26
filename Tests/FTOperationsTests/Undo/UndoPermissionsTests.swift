// The permissions popover's changes on a real disk, through the write coordinator: each visit one Undo, its Undo and
// Redo, and what is left alone
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoPermissionsTests {
    private func file(_ path: String, mode: Int) throws {
        try UndoDisk.write(path, "x")
        #expect(Darwin.chmod(path, mode_t(mode)) == 0)
    }

    private func mode(_ path: String) -> Int {
        var info = Darwin.stat()
        return Darwin.lstat(path, &info) == 0 ? Int(info.st_mode & 0o7777) : -1
    }

    private func flags(_ path: String) -> UInt32 {
        var info = Darwin.stat()
        return Darwin.lstat(path, &info) == 0 ? info.st_flags : 0
    }

    private func locked(_ path: String) -> Bool { flags(path) & UInt32(UF_IMMUTABLE) != 0 }
    private func hidden(_ path: String) -> Bool { flags(path) & UInt32(UF_HIDDEN) != 0 }

    /// Locked items are unlocked before the folder goes.
    private func unlock(_ paths: String...) {
        for path in paths { Darwin.lchflags(path, 0) }
    }

    // Everything changed in one visit is one Undo: a Write for the group on a script and a file leaves the script's
    // Run, the Hidden flag goes on both, a mode typed sets the nine bits. Undo puts back each item as it was when the
    // visit began; Redo gives them the last of it again.
    @Test func oneVisitIsOneUndoAndRedoAppliesItsLastStateAgain() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, b) = ("\(root)/a.txt", "\(root)/run.sh")
            try file(a, mode: 0o644)
            try file(b, mode: 0o755)
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = PermissionsVisit()
            var run = try await t.coordinator.changePermissions(
                .bit(who: 1, what: 1, on: true), paths: [a, b], visit: visit)
            #expect(run.failures.isEmpty)
            #expect(mode(a) == 0o664)
            #expect(mode(b) == 0o775)
            run = try await t.coordinator.changePermissions(.hidden(true), paths: [a, b], visit: visit)
            #expect(hidden(a) && hidden(b))
            run = try await t.coordinator.changePermissions(.mode(0o600), paths: [a, b], visit: visit)
            #expect(mode(a) == 0o600)
            #expect(mode(b) == 0o600)
            #expect(t.history.entries(.undo).count == 1)
            #expect(t.history.menu().undo == "Permissions of 2 Items")
            #expect(try await t.undo().status == .completed)
            #expect(mode(a) == 0o644)
            #expect(mode(b) == 0o755)
            #expect(!hidden(a) && !hidden(b))
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Permissions of 2 Items", cantUndo: false))
            #expect(try await t.undo(.redo).status == .completed)
            #expect(mode(a) == 0o600)
            #expect(mode(b) == 0o600)
            #expect(hidden(a) && hidden(b))
            #expect(t.history.menu().undo == "Permissions of 2 Items")
            await t.shutDown()
        }
    }

    // Another visit is another Undo; and once an Undo took the visit's entry, its next change is an entry of its own.
    @Test func anotherVisitOrAChangeAfterAnUndoIsAnotherEntry() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try file(a, mode: 0o644)
            let t = UndoTest(root: root, trashDir: trashDir)
            let first = PermissionsVisit()
            _ = try await t.coordinator.changePermissions(.bit(who: 2, what: 0, on: false), paths: [a], visit: first)
            #expect(t.history.menu().undo == "Permissions of \u{201C}a.txt\u{201D}")
            let second = PermissionsVisit()
            _ = try await t.coordinator.changePermissions(.bit(who: 1, what: 0, on: false), paths: [a], visit: second)
            #expect(mode(a) == 0o600)
            #expect(t.history.entries(.undo).count == 2)
            #expect(try await t.undo().status == .completed)
            #expect(mode(a) == 0o640)
            // The second visit goes on: its entry was undone, so this is a new one, from where the item is now.
            _ = try await t.coordinator.changePermissions(.bit(who: 0, what: 2, on: true), paths: [a], visit: second)
            #expect(mode(a) == 0o740)
            #expect(t.history.entries(.undo).count == 2)
            #expect(t.history.top(.redo) == nil)
            #expect(try await t.undo().status == .completed)
            #expect(mode(a) == 0o640)
            #expect(try await t.undo().status == .completed)
            #expect(mode(a) == 0o644)
            await t.shutDown()
        }
    }

    // A change put back by hand while it is open leaves nothing to undo: the entry goes.
    @Test func aChangeTakenBackInTheSameVisitLeavesNoEntry() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try file(a, mode: 0o644)
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = PermissionsVisit()
            _ = try await t.coordinator.changePermissions(.bit(who: 1, what: 1, on: true), paths: [a], visit: visit)
            #expect(t.history.entries(.undo).count == 1)
            _ = try await t.coordinator.changePermissions(.bit(who: 1, what: 1, on: false), paths: [a], visit: visit)
            #expect(mode(a) == 0o644)
            #expect(t.history.entries(.undo).isEmpty)
            await t.shutDown()
        }
    }

    // A locked item refuses a new mode and says why; unlocked, it takes one. Undo puts back its mode and locks it
    // again; Redo unlocks it and gives it the new mode.
    @Test func aLockedItemRefusesAModeAndUndoLocksItAgain() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try file(a, mode: 0o644)
            #expect(Darwin.lchflags(a, UInt32(UF_IMMUTABLE)) == 0)
            defer { unlock(a) }
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = PermissionsVisit()
            let refused = try await t.coordinator.changePermissions(
                .bit(who: 0, what: 2, on: true), paths: [a], visit: visit)
            #expect(refused.items.isEmpty)
            #expect(refused.failures.map(\.message) == ["It is locked. Turn off Locked to change its permissions."])
            #expect(t.history.entries(.undo).isEmpty)
            _ = try await t.coordinator.changePermissions(.locked(false), paths: [a], visit: visit)
            #expect(!locked(a))
            _ = try await t.coordinator.changePermissions(.bit(who: 0, what: 2, on: true), paths: [a], visit: visit)
            #expect(mode(a) == 0o744)
            #expect(try await t.undo().status == .completed)
            #expect(mode(a) == 0o644)
            #expect(locked(a))
            #expect(try await t.undo(.redo).status == .completed)
            #expect(mode(a) == 0o744)
            #expect(!locked(a))
            await t.shutDown()
        }
    }

    // An item whose permissions were changed since, by another app, is left as it is, and said; the others go back.
    @Test func anItemChangedSinceIsLeftAsItIs() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, b) = ("\(root)/a.txt", "\(root)/b.txt")
            try file(a, mode: 0o644)
            try file(b, mode: 0o644)
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changePermissions(
                .mode(0o600), paths: [a, b], visit: PermissionsVisit())
            #expect(Darwin.chmod(a, 0o700) == 0)
            let end = try await t.undo()
            #expect(mode(a) == 0o700)
            #expect(mode(b) == 0o644)
            let skipped = end.result?.items.filter { $0.status == .skipped } ?? []
            #expect(
                skipped.map(\.error) == [
                    "\u{201C}a.txt\u{201D} was left as it is, because its permissions were changed since."
                ])
            // What was left can't be done: nothing of it stays to undo.
            #expect(t.history.top(.undo) == nil)
            #expect(try await t.undo(.redo).status == .completed)
            #expect(mode(b) == 0o600)
            await t.shutDown()
        }
    }

    // A link is left as it is, and so is what it leads to; an item gone is said.
    @Test func aLinkIsLeftAloneAndAnItemGoneIsSaid() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, link) = ("\(root)/a.txt", "\(root)/link")
            try file(a, mode: 0o644)
            #expect(Darwin.symlink(a, link) == 0)
            let t = UndoTest(root: root, trashDir: trashDir)
            let run = try await t.coordinator.changePermissions(
                .mode(0o600), paths: [link, "\(root)/gone.txt"], visit: PermissionsVisit())
            #expect(run.items.isEmpty)
            #expect(run.failures.map(\.message) == ["It no longer exists."])
            #expect(mode(a) == 0o644)
            #expect(t.history.entries(.undo).isEmpty)
            await t.shutDown()
        }
    }

    // The Undo History list names each item with what changed of it.
    @Test func theHistoryListSaysWhatChanged() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try file(a, mode: 0o644)
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = PermissionsVisit()
            _ = try await t.coordinator.changePermissions(.mode(0o600), paths: [a], visit: visit)
            _ = try await t.coordinator.changePermissions(.hidden(true), paths: [a], visit: visit)
            let content = UndoHistoryRows.content(t.history, homePath: "/nowhere")
            let row = try #require(content.undo.first)
            #expect(row.title == "Permissions of \u{201C}a.txt\u{201D}")
            #expect(row.items == ["a.txt: 644 \u{2192} 600, hidden"])
            #expect(row.place == "in \(NodePath.basename(root))")
            #expect(row.icon == .showInfo)
            await t.shutDown()
        }
    }

    // The step is kept and read back as it was written.
    @Test func theStepIsReadBackAsWritten() throws {
        let step = UndoStep.permissions(items: [
            PermissionsUndoItem(
                path: "/a", id: ItemId(dev: 1, ino: 2),
                before: PermissionsSetting(mode: 0o644, locked: false, hidden: false),
                after: PermissionsSetting(mode: 0o600, locked: true, hidden: false))
        ])
        let data = try JSONEncoder().encode(step)
        #expect(try JSONDecoder().decode(UndoStep.self, from: data) == step)
    }
}
