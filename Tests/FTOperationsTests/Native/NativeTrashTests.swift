// Port of the nativeTrashItem cases of packages/native-fs/src/native-fs.test.ts, with native_trash.m's error mapping
import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private typealias Files = NativeTestFiles

struct NativeTrashTests {
    // /dev is a disk without a Trash, which the Trash tells with NSFeatureUnsupportedError: the one failure for which
    // deleting for good may be offered (see TrashItem). Nothing there can be moved by anyone but root, who doesn't
    // run this. It is the process's first Trash call (see TrashProbe).
    // T-5a759850 F-406 F-407
    @Test(.enabled(if: getuid() != 0, "root could move /dev/null"))
    func failsWithENOTSUPOnADiskWithoutATrash() throws {
        let result = try #require(TrashProbe.devNull)
        let error = #expect(throws: NativeError.self) { try result.get() }
        #expect(error?.code == "ENOTSUP")
        #expect(error?.cocoaCode == 3328)  // NSFeatureUnsupportedError
        #expect(error?.message.contains("null") == true)
        #expect(error?.syscall == "trash" && error?.path == "/dev/null")
    }

    // T-357aad4e F-406
    @Test(.tags(.diskImage), .diskImages)
    func movesItemsToTheirDisksTrashAndSaysWhereEachWentEvenUnderANewName() async throws {
        TrashProbe.touch()
        try await DiskImage.withVolume(.apfs) { volume in
            let file = volume.path + "/a.txt"
            let folder = volume.path + "/Folder"
            try Files.write(file, "first")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            try Files.write(folder + "/inside.txt", "inside")
            let disk = PosixFileSystem()
            let fileIno = try disk.stat(file).ino
            let folderIno = try disk.stat(folder).ino

            // Fails, as the original's does, whenever the Trash can't move the item; then says whether the Mac
            // gave the disk a volume reference at all (see TrashProbe.volumeReference).
            let fileMoved: String?
            do {
                fileMoved = try NativeFS.trashItem(file)
            } catch {
                Issue.record("the Trash refused \(file): \(TrashProbe.volumeReferenceReport(of: volume.path))")
                throw error
            }
            let fileInTrash = try #require(fileMoved)
            let folderInTrash = try #require(try NativeFS.trashItem(folder))

            #expect(fileInTrash.hasPrefix(volume.path + "/.Trashes"))
            #expect(!Files.exists(file))
            #expect(try disk.stat(fileInTrash).ino == fileIno)
            #expect(try disk.stat(folderInTrash).ino == folderIno)
            #expect(Files.read(folderInTrash + "/inside.txt") == Array("inside".utf8))

            // A second "a.txt" can't take the first one's name in the Trash.
            try Files.write(file, "second")
            let secondInTrash = try #require(try NativeFS.trashItem(file))
            #expect(secondInTrash != fileInTrash)
            #expect(Files.read(secondInTrash) == Array("second".utf8))
            #expect(Files.read(fileInTrash) == Array("first".utf8))
        }
    }

    // What the Trash test says when it fails: the startup disk, mounted first, always has a volume reference.
    @Test func theStartupDiskHasAFileManagerVolumeReference() throws {
        let result = try #require(TrashProbe.volumeReference(of: NSHomeDirectory()))
        let number = try result.get()
        #expect(number < 0)
        #expect(TrashProbe.volumeReferenceReport(of: NSHomeDirectory()).contains("knows the disk"))
    }

    // T-897ba460 F-406 F-407
    @Test func failsWithENOENTAndTheTrashsOwnSentenceForAnItemThatIsntThere() throws {
        TrashProbe.touch()
        try withTemporaryDirectory(prefix: "native-fs-trash") { root in
            let missing = root.appending("missing.txt").path
            let error = #expect(throws: NativeError.self) { try NativeFS.trashItem(missing) }
            #expect(error?.code == "ENOENT")
            #expect(error?.cocoaCode == 4)  // NSFileNoSuchFileError
            #expect(error?.syscall == "trash" && error?.path == missing)
            #expect(error?.message.contains("missing.txt") == true)
        }
    }

    // N/A T-d235c612 the path is a typed String: a call without one doesn't compile.

    // F-407
    @Test func mapsTheTrashsErrorsToErrnos() {
        func cocoa(_ code: Int, underlying: NSError? = nil) -> NSError {
            NSError(
                domain: NSCocoaErrorDomain, code: code,
                userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        #expect(NativeFS.trashErrno(of: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))) == EBUSY)
        #expect(
            NativeFS.trashErrno(
                of: cocoa(NSFileWriteUnknownError, underlying: NSError(domain: NSPOSIXErrorDomain, code: 13)))
                == EACCES)
        #expect(NativeFS.trashErrno(of: cocoa(NSFeatureUnsupportedError)) == ENOTSUP)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileNoSuchFileError)) == ENOENT)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileReadNoSuchFileError)) == ENOENT)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileWriteNoPermissionError)) == EACCES)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileReadNoPermissionError)) == EACCES)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileWriteVolumeReadOnlyError)) == EROFS)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileWriteOutOfSpaceError)) == ENOSPC)
        #expect(NativeFS.trashErrno(of: cocoa(NSUserCancelledError)) == ECANCELED)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileWriteFileExistsError)) == EEXIST)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileWriteInvalidFileNameError)) == EINVAL)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileReadInvalidFileNameError)) == EINVAL)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileLockingError)) == ENOLCK)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileReadTooLargeError)) == EFBIG)
        // A bare "unknown" says nothing about the disk having no Trash.
        #expect(NativeFS.trashErrno(of: cocoa(NSFileWriteUnknownError)) == 0)
        let notSupported = NSError(domain: NSOSStatusErrorDomain, code: -1426)
        #expect(NativeFS.trashErrno(of: cocoa(NSFileWriteUnknownError, underlying: notSupported)) == ENOTSUP)
        #expect(NativeFS.trashErrno(of: NSError(domain: "Other", code: 1)) == 0)
    }

    // The Trash's sentence when it gave one, with the errno's name and the Cocoa code; Node's errno wording without.
    // F-407
    @Test func shapesTheTrashsFailures() {
        let unknown = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "“a” couldn’t be moved to the trash."])
        let error = NativeFS.trashError(unknown, path: "/v/a")
        #expect(error.message == "“a” couldn’t be moved to the trash.")
        #expect(error.code == nil && error.errnum == nil)
        #expect(error.cocoaCode == NSFileWriteUnknownError && error.syscall == "trash" && error.path == "/v/a")

        let posix = NativeFS.trashError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), path: "/v/a")
        #expect(posix.code == "EACCES" && posix.errnum == EACCES && posix.cocoaCode == nil)

        let none = NativeFS.trashError(nil, path: "/v/a")
        #expect(none.message == "EIO: Input/output error, trash '/v/a'")
        #expect(none.code == "EIO")
    }
}
