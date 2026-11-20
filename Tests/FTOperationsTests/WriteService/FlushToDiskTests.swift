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

    /// The calls of a disk whose full sync of one item answers `fullSync` and whose plain sync answers `plain`, its
    /// flush of the whole of it answering `volume`, and what was asked of it, in order.
    static func calls(volumeAnswering volume: Int32 = 0, fullSyncAnswering fullSync: Int32, fsyncAnswering plain: Int32)
        -> (calls: FlushCalls, asked: Locked<[String]>)
    {
        let whole = Self.calls(volumeAnswering: volume)
        var calls = whole.calls
        let asked = whole.asked
        calls.fullSync = { _ in
            asked.mutate { $0.append("full sync") }
            return fullSync
        }
        calls.fsync = { _ in
            asked.mutate { $0.append("plain sync") }
            return plain
        }
        return (calls, asked)
    }

    /// The disk's own calls, and what its full sync answered for each item it was asked for.
    private static func callsNotingFullSync() -> (calls: FlushCalls, answers: Locked<[Int32]>) {
        let answers = Locked<[Int32]>([])
        var calls = FlushCalls()
        let fullSync = calls.fullSync
        calls.fullSync = { descriptor in
            let answer = fullSync(descriptor)
            answers.mutate { $0.append(answer) }
            return answer
        }
        return (calls, answers)
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

    // A file whose full sync failed has not been written out, even when the plain sync then works: that one hands the
    // drive what waits and no more, and a drive that failed to write out its cache answers so.
    @Test(arguments: [EIO, ENXIO, EROFS, EPERM])
    func aFileWhoseFullSyncFailsIsAnErrorThoughThePlainSyncWorks(errnum: Int32) throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            let (calls, asked) = Self.calls(fullSyncAnswering: errnum, fsyncAnswering: 0)
            let file = root.path + "/a.txt"
            try Disk.write(file, "a")

            let error = #expect(throws: NativeError.self) {
                try NativeWriteFileSystem(flushCalls: calls).flushToDisk(file, wholeDisk: false)
            }

            #expect(error?.code == .errno(errnum))
            #expect(error?.path == file)
            #expect(error?.message.contains(", fcntl '") == true)
            #expect(asked.value == ["full sync"])
        }
    }

    // So too the folder of a disk with no call for the whole of it, flushed in the disk's place.
    @Test(arguments: [EIO, ENXIO])
    func aFolderWhoseFullSyncFailsIsAnErrorOnADiskWithNoCallForTheWholeOfIt(errnum: Int32) throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            let (calls, asked) = Self.calls(volumeAnswering: ENOTSUP, fullSyncAnswering: errnum, fsyncAnswering: 0)

            let error = #expect(throws: NativeError.self) {
                try NativeWriteFileSystem(flushCalls: calls).flushToDisk(root.path, wholeDisk: true)
            }

            #expect(error?.code == .errno(errnum))
            #expect(error?.path == root.path)
            #expect(asked.value == ["disk", "every disk", "full sync"])
        }
    }

    // Where there is no full sync to make (a disk with no such call; ENODEV is a device's answer), the plain sync is
    // as much as can be asked, for a file and for the folder flushed in a disk's place.
    @Test(arguments: [ENOTSUP, ENOTTY, EINVAL, ENODEV])
    func anItemWithNoFullSyncIsFlushedThePlainWay(errnum: Int32) throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            try Disk.write(root.path + "/a.txt", "a")
            let (calls, asked) = Self.calls(fullSyncAnswering: errnum, fsyncAnswering: 0)

            try NativeWriteFileSystem(flushCalls: calls).flushToDisk(root.path + "/a.txt", wholeDisk: false)

            #expect(asked.value == ["full sync", "plain sync"])
            let (wholeCalls, wholeAsked) = Self.calls(
                volumeAnswering: ENOTSUP, fullSyncAnswering: errnum, fsyncAnswering: 0)

            try NativeWriteFileSystem(flushCalls: wholeCalls).flushToDisk(root.path, wholeDisk: true)

            #expect(wholeAsked.value == ["disk", "every disk", "full sync", "plain sync"])
        }
    }

    // The plain sync's own failure is told.
    @Test(arguments: [EIO, ENXIO])
    func aPlainSyncThatFailsIsAnError(errnum: Int32) throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            let (calls, asked) = Self.calls(fullSyncAnswering: ENOTSUP, fsyncAnswering: errnum)
            let file = root.path + "/a.txt"
            try Disk.write(file, "a")

            let error = #expect(throws: NativeError.self) {
                try NativeWriteFileSystem(flushCalls: calls).flushToDisk(file, wholeDisk: false)
            }

            #expect(error?.code == .errno(errnum))
            #expect(error?.message.contains(", fsync '") == true)
            #expect(asked.value == ["full sync", "plain sync"])
        }
    }

    // A disk with neither call is left to itself.
    @Test(arguments: [ENOTSUP, ENOTTY, EINVAL])
    func aDiskWithNeitherSyncIsLeftToItself(errnum: Int32) throws {
        try withTemporaryDirectory(prefix: "flush") { root in
            let (calls, asked) = Self.calls(fullSyncAnswering: ENOTTY, fsyncAnswering: errnum)
            try Disk.write(root.path + "/a.txt", "a")

            try NativeWriteFileSystem(flushCalls: calls).flushToDisk(root.path + "/a.txt", wholeDisk: false)

            #expect(asked.value == ["full sync", "plain sync"])
        }
    }

    // What the disks people move files to really answer: the flush of the whole disk works, or says the disk has no
    // such call, and so does the full sync of each kind of item that is flushed by itself: a file, an empty file, a
    // folder (for a disk with no call for the whole of it), a pipe where the disk has them, and a link, in whose place
    // the folder it is in is flushed. Any other answer would keep the originals of every move to such a disk.
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.apfs, .hfs, .exfat, .fat32])
    func theDisksPeopleMoveFilesToCanBeWrittenOut(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { folder in
            try Disk.write(folder.path + "/a.txt", "a")

            let errnum = FlushCalls().syncVolume(folder.path)

            #expect(
                errnum == 0 || FlushCalls.noSuchCall.contains(errnum),
                "sync_volume_np on \(kind.rawValue) answered \(errnum)")
            try NativeWriteFileSystem().flushToDisk(folder.path, wholeDisk: true)

            try Disk.write(folder.path + "/empty.txt", "")
            try Disk.write(folder.path + "/dir/in.txt", "in")
            try Disk.makeDirectories(folder.path + "/dir/empty")
            try Disk.symlink("a.txt", folder.path + "/link")
            // FAT and exFAT have no pipes.
            let pipe = mkfifo(folder.path + "/pipe", 0o644) == 0 ? ["pipe"] : []
            for name in ["a.txt", "empty.txt", "dir", "dir/empty", "link"] + pipe {
                let (calls, answers) = Self.callsNotingFullSync()

                try NativeWriteFileSystem(flushCalls: calls).flushToDisk(folder.path + "/" + name, wholeDisk: false)

                let answer = try #require(answers.value.first)
                #expect(
                    answer == 0 || FlushCalls.noFullSync.contains(answer),
                    "F_FULLFSYNC of \(name) on \(kind.rawValue) answered \(answer)")
            }
            // The folder, flushed in the place of a disk with no call for the whole of it.
            let noting = Self.callsNotingFullSync()
            var calls = noting.calls
            calls.syncVolume = { _ in ENOTSUP }
            calls.syncAll = {}

            try NativeWriteFileSystem(flushCalls: calls).flushToDisk(folder.path, wholeDisk: true)

            #expect(noting.answers.value.count == 1)
        }
    }

    // A device, and the folder of devices, which is on a disk with no such call: neither has a full sync to make, and
    // neither is an error.
    @Test(arguments: ["/dev/null", "/dev"])
    func aDeviceAndTheFolderOfDevicesHaveNoFullSync(path: String) throws {
        let (calls, answers) = Self.callsNotingFullSync()

        try NativeWriteFileSystem(flushCalls: calls).flushToDisk(path, wholeDisk: false)

        let answer = try #require(answers.value.first)
        #expect(answer == 0 || FlushCalls.noFullSync.contains(answer), "F_FULLFSYNC of \(path) answered \(answer)")
    }
}
