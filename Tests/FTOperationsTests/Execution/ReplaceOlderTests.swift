// Replace Older on real disks: only files newer than the ones there replace them, folders merge, and a second run
// replaces nothing, as copies keep their dates
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private func setModified(_ path: String, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
}

struct ReplaceOlderTests {
    @Test func replacesOnlyNewerFilesAndASecondRunReplacesNothing() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src"
            let destination = root.path + "/dest"
            try Disk.write(source + "/Project/a.txt", "new a")
            try Disk.write(source + "/Project/b.txt", "old b")
            try Disk.write(source + "/Project/sub/c.txt", "new c")
            try Disk.write(source + "/Project/d.txt", "added d")
            try Disk.write(destination + "/Project/a.txt", "old a")
            try Disk.write(destination + "/Project/b.txt", "new b")
            try Disk.write(destination + "/Project/sub/c.txt", "old c")
            try Disk.write(destination + "/Project/only-here.txt", "kept")
            try setModified(source + "/Project/a.txt", 2_000_000)
            try setModified(destination + "/Project/a.txt", 1_000_000)
            try setModified(source + "/Project/b.txt", 1_000_000)
            try setModified(destination + "/Project/b.txt", 2_000_000)
            try setModified(source + "/Project/sub/c.txt", 2_000_000)
            try setModified(destination + "/Project/sub/c.txt", 1_000_000)

            // Both sides are on the startup disk, APFS: dates compare to the millisecond.
            let policy = CopyPasteReview.policy(for: .replaceOlder, toleranceMs: 1)
            let trash = root.path + "/Trash"
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: false)
            let fileSystem = NativePaste.withTrash(trash)
            let first = try await runPaste(
                mode: .copy, sources: [source + "/Project"], into: destination, policy: policy, fileSystem: fileSystem)
            #expect(first.report.newerToleranceMs == 1)
            #expect(first.result?.status == .partial)
            #expect(Disk.read(destination + "/Project/a.txt") == "new a")
            #expect(Disk.read(destination + "/Project/b.txt") == "new b")
            #expect(Disk.read(destination + "/Project/sub/c.txt") == "new c")
            #expect(Disk.read(destination + "/Project/d.txt") == "added d")
            #expect(Disk.read(destination + "/Project/only-here.txt") == "kept")
            let skipped = first.result?.items.filter { $0.status == .skipped } ?? []
            #expect(skipped.map(\.sourcePath) == [source + "/Project/b.txt"])
            #expect(skipped.map(\.skipReason) == [.notNewer])
            // The replaced files went to the Trash.
            #expect(Disk.list(trash).count == 2)

            let second = try await runPaste(
                mode: .copy, sources: [source + "/Project"], into: destination, policy: policy, fileSystem: fileSystem)
            #expect(second.result?.items.allSatisfy { $0.status == .skipped || $0.status == .completed } == true)
            #expect(
                second.result?.items.filter { $0.status == .skipped }.map(\.skipReason)
                    == [.notNewer, .notNewer, .notNewer, .notNewer])
            #expect(Disk.list(trash).count == 2)
        }
    }

    // FAT keeps local time with no time zone: Replace Older isn't offered for a paste onto it.
    @Test(.tags(.diskImage), .diskImages)
    func isntOfferedOntoAFATDisk() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a.txt", "a")
            try await DiskImage.withSharedVolume(.fat32) { stick in
                try Disk.write(stick.path + "/rob/a.txt", "old")
                let run = try await runPaste(
                    mode: .copy, sources: [root.path + "/a.txt"], into: stick.path + "/rob",
                    policy: NativePaste.keepExisting)
                #expect(run.report.newerToleranceMs == nil)
            }
        }
    }

    // exFAT keeps dates to 10 ms, with the time zone: offered, compared at that.
    @Test(.tags(.diskImage), .diskImages)
    func isOfferedOntoAnExFATDiskAt10Milliseconds() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a.txt", "a")
            try await DiskImage.withSharedVolume(.exfat) { stick in
                try Disk.write(stick.path + "/rob2/a.txt", "old")
                let run = try await runPaste(
                    mode: .copy, sources: [root.path + "/a.txt"], into: stick.path + "/rob2",
                    policy: NativePaste.keepExisting)
                #expect(run.report.newerToleranceMs == 10)
            }
        }
    }
}
