// Writing a disk out before a move's originals go: which failures mean "this disk has no such call"
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct FlushToDiskTests {
    /// The calls of a disk whose flush of the whole of it answers `errnum`, the folder's own flush working as it
    /// does, and what was asked of it, in order.
    static func calls(volumeAnswering errnum: Int32) -> (calls: FlushCalls, asked: Locked<[String]>) {
        let asked = Locked<[String]>([])
        var calls = FlushCalls()
        let folderFlush = calls.fullSync
        calls.syncVolume = { _ in
            asked.mutate { $0.append("disk") }
            return errnum
        }
        calls.syncAll = { asked.mutate { $0.append("every disk") } }
        calls.fullSync = { descriptor in
            asked.mutate { $0.append("folder") }
            return folderFlush(descriptor)
        }
        return (calls, asked)
    }

    // A disk that failed to write out the whole of it has not written it out, even when the folder alone then
    // flushes without error: a failing drive answers so.
    @Test(arguments: [EIO, ENXIO, EROFS, EPERM])
    func aDiskThatFailsToWriteItselfOutIsAnErrorThoughTheFolderFlushes(errnum: Int32) throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            let (calls, asked) = Self.calls(volumeAnswering: errnum)

            let error = #expect(throws: NativeError.self) {
                try NativeWriteFileSystem(flushCalls: calls).flushToDisk(root.path, wholeDisk: true)
            }

            #expect(error?.code == .errno(errnum))
            #expect(error?.path == root.path)
            #expect(asked.value == ["disk"])
        }
    }

    // A disk with no call for the whole of it is flushed the other way: every disk is asked, then the folder.
    @Test(arguments: [ENOTSUP, ENOTTY, EINVAL])
    func aDiskWithNoCallForTheWholeOfItIsFlushedByItsFolder(errnum: Int32) throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            let (calls, asked) = Self.calls(volumeAnswering: errnum)

            try NativeWriteFileSystem(flushCalls: calls).flushToDisk(root.path, wholeDisk: true)

            #expect(asked.value == ["disk", "every disk", "folder"])
        }
    }

    // A file alone never asks the disk for the whole of it.
    @Test func aFileAloneIsFlushedByItself() throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            let (calls, asked) = Self.calls(volumeAnswering: EIO)
            try Disk.write(root.path + "/a.txt", "a")

            try NativeWriteFileSystem(flushCalls: calls).flushToDisk(root.path + "/a.txt", wholeDisk: false)

            #expect(asked.value == ["folder"])
        }
    }

    // What the disks people move files to really answer: the flush of the whole disk works, or says the disk has no
    // such call. Any other answer would keep the originals of every move to such a disk.
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.apfs, .hfs, .exfat, .fat32])
    func theDisksPeopleMoveFilesToCanBeWrittenOut(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { folder in
            try Disk.write(folder.path + "/a.txt", "a")

            let errnum = FlushCalls().syncVolume(folder.path)

            #expect(
                errnum == 0 || FlushCalls.noSuchCall.contains(errnum),
                "sync_volume_np on \(kind.rawValue) answered \(errnum)")
            try NativeWriteFileSystem().flushToDisk(folder.path, wholeDisk: true)
            try NativeWriteFileSystem().flushToDisk(folder.path + "/a.txt", wholeDisk: false)
        }
    }
}
