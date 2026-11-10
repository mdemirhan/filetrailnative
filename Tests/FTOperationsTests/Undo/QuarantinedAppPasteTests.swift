// An app from the internet pasted on its own runs from where it is put, instead of being translocated by macOS: its
// copy is marked to run in place, and a move on one disk copies it to get that mark.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized)
struct QuarantinedAppPasteTests {
    private static let quarantine = "com.apple.quarantine"
    /// QTN_FLAG_DO_NOT_TRANSLOCATE.
    private static let runsInPlace: UInt32 = 0x100

    private func makeApp(_ path: String, quarantined: Bool = true) throws {
        try Disk.makeDirectories(path + "/Contents/MacOS")
        try UndoDisk.write(path + "/Contents/MacOS/run", "new")
        if quarantined {
            #expect(NativeTestFiles.setXattr(path, Self.quarantine, "0083;00000000;Safari;") == 0)
        }
    }

    /// The flags of the item's quarantine; nil when it isn't in quarantine.
    private func flags(_ path: String) -> UInt32? {
        var value = [UInt8](repeating: 0, count: 128)
        guard getxattr(path, Self.quarantine, &value, value.count, 0, 0) >= 4 else { return nil }
        return UInt32(String(decoding: value.prefix(4), as: UTF8.self), radix: 16)
    }

    private func runsInPlace(_ path: String) -> Bool {
        flags(path).map { $0 & Self.runsInPlace != 0 } == true
    }

    private func inode(_ path: String) -> UInt64? {
        Disk.lstat(path)?.ino
    }

    /// `body` gets a test with a "Downloads" and an "Applications" folder, and the paths of those folders.
    private func withFolders(_ body: (UndoTest, String, String, String) async throws -> Void) async throws {
        try await withUndoFolder { root, trashDir in
            let (downloads, applications) = (root + "/Downloads", root + "/Applications")
            try Disk.makeDirectories(downloads)
            try Disk.makeDirectories(applications)
            let test = UndoTest(root: root, trashDir: trashDir)
            try await body(test, downloads, applications, trashDir)
            await test.shutDown()
        }
    }

    @Test func aLoneAppInQuarantineMovedOnItsDiskRunsInPlaceAndUndoTakesItBack() async throws {
        try await withFolders { test, downloads, applications, _ in
            try makeApp(downloads + "/Foo.app")

            let result = try await test.paste(.cut, [downloads + "/Foo.app"], into: applications)

            #expect(result.status == .completed)
            #expect(Disk.lstat(downloads + "/Foo.app") == nil)
            #expect(Disk.read(applications + "/Foo.app/Contents/MacOS/run") == "new")
            #expect(runsInPlace(applications + "/Foo.app"))
            #expect(UndoDisk.names(applications) == ["Foo.app"])

            try await test.undo()

            #expect(Disk.lstat(applications + "/Foo.app") == nil)
            #expect(Disk.read(downloads + "/Foo.app/Contents/MacOS/run") == "new")
        }
    }

    @Test func aLoneAppInQuarantineMovedOverAnotherRunsInPlaceAndUndoPutsBothBack() async throws {
        try await withFolders { test, downloads, applications, trashDir in
            try makeApp(downloads + "/Foo.app")
            try Disk.makeDirectories(applications + "/Foo.app/Contents")
            try UndoDisk.write(applications + "/Foo.app/Contents/old", "old")

            let result = try await test.paste(
                .cut, [downloads + "/Foo.app"], into: applications, policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: UndoTestFileSystem.folderTrash(trashDir)))

            #expect(result.status == .completed)
            #expect(Disk.lstat(downloads + "/Foo.app") == nil)
            #expect(Disk.read(applications + "/Foo.app/Contents/MacOS/run") == "new")
            #expect(Disk.lstat(applications + "/Foo.app/Contents/old") == nil)
            #expect(runsInPlace(applications + "/Foo.app"))

            try await test.undo()

            #expect(Disk.read(downloads + "/Foo.app/Contents/MacOS/run") == "new")
            #expect(Disk.read(applications + "/Foo.app/Contents/old") == "old")
        }
    }

    @Test func anAppOutOfQuarantineIsRenamedAndStaysOutOfQuarantine() async throws {
        try await withFolders { test, downloads, applications, _ in
            try makeApp(downloads + "/Foo.app", quarantined: false)
            let before = inode(downloads + "/Foo.app")

            _ = try await test.paste(.cut, [downloads + "/Foo.app"], into: applications)

            #expect(inode(applications + "/Foo.app") == before)
            #expect(flags(applications + "/Foo.app") == nil)
        }
    }

    @Test func anAppInQuarantineMovedWithAnotherItemIsRenamedAndNotMarked() async throws {
        try await withFolders { test, downloads, applications, _ in
            try makeApp(downloads + "/Foo.app")
            try UndoDisk.write(downloads + "/beside.dylib", "x")
            let before = inode(downloads + "/Foo.app")

            _ = try await test.paste(
                .cut, [downloads + "/Foo.app", downloads + "/beside.dylib"], into: applications)

            #expect(inode(applications + "/Foo.app") == before)
            #expect(flags(applications + "/Foo.app") == 0x83)
        }
    }

    @Test func aLoneAppInQuarantineCopiedOnItsDiskRunsInPlaceAndTheOriginalStays() async throws {
        try await withFolders { test, downloads, applications, _ in
            try makeApp(downloads + "/Foo.app")

            _ = try await test.paste(.copy, [downloads + "/Foo.app"], into: applications)

            #expect(runsInPlace(applications + "/Foo.app"))
            #expect(flags(downloads + "/Foo.app") == 0x83)
        }
    }

    @Test func anAppInQuarantineCopiedInsideAFolderIsNotMarked() async throws {
        try await withFolders { test, downloads, applications, _ in
            try makeApp(downloads + "/Folder/Foo.app")

            _ = try await test.paste(.copy, [downloads + "/Folder"], into: applications)

            #expect(flags(applications + "/Folder/Foo.app") == 0x83)
        }
    }

    @Test func aLoneAppInQuarantineMovedToAnotherDiskRunsInPlace() async throws {
        try await withFolders { test, downloads, applications, _ in
            try makeApp(downloads + "/Foo.app")

            let result = try await test.paste(
                .cut, [downloads + "/Foo.app"], into: applications,
                fileSystem: NativePaste.asOnAnotherDisk(downloads))

            #expect(result.status == .completed)
            #expect(Disk.lstat(downloads + "/Foo.app") == nil)
            #expect(runsInPlace(applications + "/Foo.app"))
        }
    }

    // An original that can't be read once the app is in place may still be there (here its emptied folder is): it
    // is recorded as a copy made, never as moved.
    @Test func aLoneAppWhoseOriginalCantBeReadAfterTheMoveIsRecordedAsMadeNotMoved() async throws {
        try await withFolders { _, downloads, applications, _ in
            try makeApp(downloads + "/Foo.app")
            let fileSystem = TestFileSystem()
            let base = fileSystem.base
            fileSystem.lstatImpl = { path in
                if path.hasSuffix("/Downloads/Foo.app") && Disk.exists(applications + "/Foo.app") {
                    throw NativeError(message: "EIO: \(path)", code: "EIO", path: path)
                }
                return try base.lstat(path)
            }

            let run = try await runPaste(
                mode: .cut, sources: [downloads + "/Foo.app"], into: applications, fileSystem: fileSystem)

            #expect(runsInPlace(applications + "/Foo.app"))
            #expect(Disk.exists(downloads + "/Foo.app"))
            guard case .undoable(let units)? = run.result?.undoLog else {
                Issue.record("Not undoable: \(String(describing: run.result?.undoLog))")
                return
            }
            let steps = units.flatMap(\.steps)
            #expect(steps.count == 1)
            if case .created(let path, _, _)? = steps.first {
                #expect(path.hasSuffix("/Applications/Foo.app"))
            } else {
                Issue.record("Not recorded as made: \(steps)")
            }
        }
    }
}
