// Port of apps/desktop/src/main/bootstrap/undoExecution.names.test.ts and undoExecution.locked.test.ts: names spelled
// otherwise, packages numbered before their extension, and copies the Trash would refuse (locked, a rule against
// deleting, read-only).
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoNamesLockedTests {
    private func items(_ end: WriteOperationEvent) -> [WriteOperationItem] { end.result?.items ?? [] }

    private func bytes(_ names: [String]) -> [[UInt8]] { names.map { Array($0.utf8) } }

    nonisolated static let nfc = "caf\u{E9}.txt"
    nonisolated static let nfd = "cafe\u{301}.txt"

    // MARK: Names

    // T-c1d0279a F-557
    @Test(arguments: [
        (CopyPasteMode.copy, "X.TXT", "x.txt"), (.copy, nfd, nfc), (.cut, "X.TXT", "x.txt"), (.cut, nfd, nfc),
    ])
    func asksNothingAndPutsTheOldItemBackWhenAReplaceIsSpelledDifferently(
        mode: CopyPasteMode, newName: String, oldName: String
    ) async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.mkdir("\(root)/paste-trash")
            try UndoDisk.write("\(root)/src/\(newName)", "new")
            try UndoDisk.write("\(root)/dst/\(oldName)", "old")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(
                mode, ["\(root)/src/\(newName)"], into: "\(root)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash("\(root)/paste-trash"))
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed.isEmpty)
            #expect(try await t.undo().status == .completed)
            #expect(bytes(UndoDisk.names("\(root)/dst")) == bytes([newName]))
            #expect(try UndoDisk.read("\(root)/dst/\(newName)") == "old")
            await t.shutDown()
        }
    }

    // T-365c8be9 F-557
    @Test func renamesAnItemWithoutAUsableIdBackAskingNothing() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/notes.txt", "")
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                // The ids FAT and exFAT give empty files, too large to go by.
                fileSystem.lstatImpl = { path in
                    var stats = try base.lstat(path)
                    if NodePath.basename(path).lowercased() == "notes.txt" { stats.ino = UInt64.max }
                    return stats
                }
            }
            try await t.rename("\(root)/notes.txt", "Notes.txt")
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed.isEmpty)
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names(root).filter { $0.hasSuffix(".txt") } == ["notes.txt"])
            await t.shutDown()
        }
    }

    // T-a88a3a81 F-557
    @Test func takesAHardLinkToTheItemUnderItsOldNameForAnotherItem() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            #expect(Darwin.link("\(root)/b.txt", "\(root)/a.txt") == 0)
            #expect(try await t.prepare().nameTaken == ["a.txt"])
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names(root).filter { $0.hasSuffix(".txt") } == ["a 2.txt", "a.txt"])
            await t.shutDown()
        }
    }

    // MARK: Undoing a rename of a folder with an item in it that was skipped

    // T-73097054 F-392 F-557
    @Test func takesTheItemBackWithItsFolderUnderItsOwnName() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/P")
            try UndoDisk.write("\(root)/P/a.txt", "a")
            // Taken after the sheet checked the names.
            try UndoDisk.write("\(root)/P/b.txt", "b")
            let t = UndoTest(root: root, trashDir: trashDir)
            let renamed = try await t.batchRename(
                BatchRenameRequest(
                    items: [
                        .init(sourcePath: "\(root)/P", destinationName: "Q", isFolder: true),
                        .init(sourcePath: "\(root)/P/a.txt", destinationName: "b.txt", isFolder: false),
                    ], onConflict: .skip, numberSeparator: " "))
            #expect(items(renamed).map(\.status) == [.completed, .skipped])
            #expect(UndoDisk.names("\(root)/Q") == ["a.txt", "b.txt"])
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(root)/P") == ["a.txt", "b.txt"])
            #expect(!UndoDisk.names(root).contains("Q"))
            await t.shutDown()
        }
    }

    // MARK: Undoing a rename of several that changed the case of a name

    // T-d923dd5b F-384 F-557
    @Test func doesntTakeTheBatchsOwnItemForOneInTheWay() async throws {
        // "B" became "c" and "a" became "b": on a disk that ignores case, "B" finds the batch's own item (now "b"),
        // which makes way for it. Nothing is asked.
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/B", "B")
            try UndoDisk.write("\(root)/a", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.batchRename([("\(root)/B", "c"), ("\(root)/a", "b")])
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed.isEmpty)
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names(root).filter { !$0.hasPrefix(".") } == ["B", "a"])
            await t.shutDown()
        }
    }

    // T-be16f64c F-390 F-557
    @Test func numbersAPackageBeforeItsExtensionAndAPlainFolderAfterItsName() async throws {
        try await withUndoFolder { root, trashDir in
            let names = ["Tool.app", "Backup.sparsebundle", "Photos.v2"]
            for name in names { try UndoDisk.mkdir("\(root)/\(name)") }
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.trash("\(root)/Tool.app", "\(root)/Backup.sparsebundle", "\(root)/Photos.v2")
            for name in names { try UndoDisk.mkdir("\(root)/\(name)") }
            #expect(try await t.undo().status == .completed)
            #expect(
                UndoDisk.names(root).filter { $0.contains(" 2") } == [
                    "Backup 2.sparsebundle", "Photos.v2 2", "Tool 2.app",
                ])
            await t.shutDown()
        }
    }

    // T-f4baea67 F-390 F-557
    @Test func goesByItsExtensionWhenMacOSCantSay() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/Talk.key")
            let t = UndoTest(root: root, trashDir: trashDir) { $0.isPackageImpl = { _ in nil } }
            try await t.trash("\(root)/Talk.key")
            try UndoDisk.mkdir("\(root)/Talk.key")
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names(root).contains("Talk 2.key"))
            await t.shutDown()
        }
    }

    // T-ef48525f F-390 F-392 F-557
    @Test func numbersAPackageBeforeItsExtensionWhenARenameOfSeveralIsUndone() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/Report.pages")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.batchRename([("\(root)/Report.pages", "Draft.pages", true)])
            try UndoDisk.mkdir("\(root)/Report.pages")
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names(root).filter { $0.hasSuffix(".pages") } == ["Report 2.pages", "Report.pages"])
            await t.shutDown()
        }
    }

    // MARK: Locked

    nonisolated static let userImmutable = UInt32(UF_IMMUTABLE)

    private func isLockedOnDisk(_ path: String) throws -> Bool {
        try NativeFS.getFlags(path) & Self.userImmutable != 0
    }

    private func lock(_ path: String) throws {
        try NativeFS.setFlags(path, try NativeFS.getFlags(path) | Self.userImmutable)
    }

    private func duplicateLocked(_ t: UndoTest, _ root: String) async throws {
        try UndoDisk.write("\(root)/a.txt", "a")
        try lock("\(root)/a.txt")
        try await t.paste(.copy, ["\(root)/a.txt"], into: root, action: .duplicate)
    }

    // T-0e1214dc F-556
    @Test func movesTheCopyToTheTrashStillLockedAndRedoPutsItBackLocked() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            try await duplicateLocked(t, root)
            #expect(try isLockedOnDisk("\(root)/a copy.txt"))
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed.isEmpty)
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/a copy.txt"))
            #expect(t.inTrash() == ["1-a copy.txt"])
            #expect(try isLockedOnDisk("\(trashDir)/1-a copy.txt"))
            #expect(try await t.undo(.redo).status == .completed)
            #expect(try isLockedOnDisk("\(root)/a copy.txt"))
            #expect(try isLockedOnDisk("\(root)/a.txt"))
            await t.shutDown()
        }
    }

    // T-bd5b494c F-556
    @Test func movesACopyRedoPutBackLockedToTheTrashAgainOnTheNextUndo() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            try await duplicateLocked(t, root)
            try await t.undo()
            try await t.undo(.redo)
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/a copy.txt"))
            #expect(try isLockedOnDisk("\(trashDir)/2-a copy.txt"))
            #expect(try await t.undo(.redo).status == .completed)
            #expect(try isLockedOnDisk("\(root)/a copy.txt"))
            await t.shutDown()
        }
    }

    // T-99ee81a4 F-556
    @Test func doesntUnlockAnItemPutBackFromTheTrashThatWasLockedSince() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.trash("\(root)/a.txt")
            try await t.undo()
            try lock("\(root)/a.txt")
            let redone = try await t.undo(.redo)
            #expect(items(redone).map(\.status) == [.failed])
            #expect(items(redone).first?.error == "“a.txt” is locked. Unlock it in Finder's Get Info and try again.")
            #expect(try isLockedOnDisk("\(root)/a.txt"))
            await t.shutDown()
        }
    }

    // T-ccfd0f8e F-556
    @Test(arguments: [UndoDirection.undo, .redo])
    func saysSoWhenACopyCantBeLockedAgain(direction: UndoDirection) async throws {
        try await withUndoFolder { root, trashDir in
            let refuseLock = UndoFlag()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.setFlagsImpl = { path, flags in
                    if refuseLock.isSet && flags & UndoNamesLockedTests.userImmutable != 0 {
                        throw codedError("EPERM", "EPERM: operation not permitted")
                    }
                    try NativeFS.setFlags(path, flags)
                }
            }
            try await duplicateLocked(t, root)
            if direction == .redo { try await t.undo() }
            refuseLock.set(true)
            let ended = try await t.undo(direction)
            // Done, with a note: nothing is left for the same command to try again.
            #expect(ended.status == .completed)
            #expect(items(ended).map(\.status) == [.completed])
            #expect(items(ended).first?.note == true)
            #expect(
                items(ended).first?.error
                    == "“a copy.txt” was moved, but its lock or permissions couldn't be put back. Set them in Finder's Get Info."
            )
            // Done all the same: the other command is next.
            #expect(t.history.top(direction) == nil)
            await t.shutDown()
        }
    }

    // T-dc718490 F-556
    @Test func keepsACopyInTheTrashToPutBackAgainWhenItCantBeUnlocked() async throws {
        try await withUndoFolder { root, trashDir in
            let refuseUnlock = UndoFlag()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.setFlagsImpl = { path, flags in
                    if refuseUnlock.isSet && flags & UndoNamesLockedTests.userImmutable == 0 {
                        throw codedError("EPERM", "EPERM: operation not permitted")
                    }
                    try NativeFS.setFlags(path, flags)
                }
            }
            try await duplicateLocked(t, root)
            try await t.undo()
            refuseUnlock.set(true)
            let redone = try await t.undo(.redo)
            #expect(redone.status == .failed)
            #expect(t.inTrash() == ["1-a copy.txt"])
            #expect(t.history.menu().redo == "Duplicate of “a copy.txt”")
            refuseUnlock.set(false)
            #expect(try await t.undo(.redo).status == .completed)
            #expect(try isLockedOnDisk("\(root)/a copy.txt"))
            await t.shutDown()
        }
    }

    /// Flags kept in memory for the test, not on the disk.
    final class FlagStore: @unchecked Sendable {
        private let lock = NSLock()
        private var flags: [String: UInt32] = [:]

        subscript(path: String) -> UInt32 {
            get { lock.withLock { flags[path] ?? 0 } }
            set { lock.withLock { flags[path] = newValue } }
        }
    }

    // T-420b717f F-556
    @Test func saysSoWhenAnItemTheTrashRefusedCantBeLockedAgain() async throws {
        try await withUndoFolder { root, trashDir in
            let flags = FlagStore()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.getFlagsImpl = { flags[$0] }
                fileSystem.setFlagsImpl = { path, value in
                    if value & UndoNamesLockedTests.userImmutable != 0 {
                        throw codedError("EPERM", "EPERM: operation not permitted")
                    }
                    flags[path] = value
                }
                fileSystem.trashImpl = { _ in throw codedError("EPERM", "EPERM: operation not permitted") }
            }
            try await t.newFolder(root, "F")
            flags["\(root)/F"] = Self.userImmutable
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.failed])
            #expect(
                items(undone).first?.error?.hasSuffix(" “F” couldn't be locked again. Lock it in Finder's Get Info.")
                    == true)
            await t.shutDown()
        }
    }

    // T-3be2b3ad F-556
    @Test func putsTheLockBackWhenTheTrashRefusesTheCopyForAnotherReason() async throws {
        try await withUndoFolder { root, trashDir in
            let flags = FlagStore()
            flags["\(root)/a.txt"] = Self.userImmutable
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.getFlagsImpl = { flags[$0] }
                fileSystem.setFlagsImpl = { path, value in flags[path] = value }
                fileSystem.trashImpl = { _ in throw codedError("EPERM", "EPERM: operation not permitted") }
            }
            try await t.newFolder(root, "F")
            flags["\(root)/F"] = Self.userImmutable
            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(flags["\(root)/F"] == Self.userImmutable)
            await t.shutDown()
        }
    }

    // MARK: A copy the Trash would refuse

    private nonisolated static func shell(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func aclOf(_ path: String) throws -> String {
        try Self.shell("/bin/ls", ["-led", path]).split(separator: "\n").dropFirst().joined(separator: "\n")
    }

    // T-4ae1fb00 F-556
    @Test func movesACopyWithARuleAgainstDeletingItToTheTrashRuleAndAll() async throws {
        try await withUndoFolder { root, trashDir in
            defer { _ = try? Self.shell("/bin/chmod", ["-R", "-N", root]) }
            try UndoDisk.mkdir("\(root)/Documents")
            try UndoDisk.write("\(root)/Documents/a.txt", "a")
            _ = try Self.shell("/bin/chmod", ["+a", "group:everyone deny delete", "\(root)/Documents"])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.copy, ["\(root)/Documents"], into: root, action: .duplicate)
            #expect(try aclOf("\(root)/Documents copy").contains("deny delete"))
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/Documents copy"))
            #expect(try aclOf("\(trashDir)/1-Documents copy").contains("deny delete"))
            #expect(try await t.undo(.redo).status == .completed)
            #expect(try aclOf("\(root)/Documents copy").contains("deny delete"))
            // And again: the copy Redo put back is still the operation's own.
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/Documents copy"))
            #expect(try aclOf("\(trashDir)/2-Documents copy").contains("deny delete"))
            await t.shutDown()
        }
    }

    // T-5a3cf5eb F-556
    @Test func movesACopyOfAReadOnlyFolderToTheTrashStillReadOnly() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/cache")
            try UndoDisk.write("\(root)/cache/a.txt", "a")
            #expect(Darwin.chmod("\(root)/cache", 0o555) == 0)
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.copy, ["\(root)/cache"], into: root, action: .duplicate)
            func mode(_ path: String) throws -> String {
                try Self.shell("/usr/bin/stat", ["-f", "%Lp", path]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/cache copy"))
            #expect(try mode("\(trashDir)/1-cache copy") == "555")
            #expect(try await t.undo(.redo).status == .completed)
            #expect(try mode("\(root)/cache copy") == "555")
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/cache copy"))
            #expect(try mode("\(trashDir)/2-cache copy") == "555")
            await t.shutDown()
        }
    }
}
