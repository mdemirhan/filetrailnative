// The copy throughput budget (docs/port/PLAN.md §4) for a whole paste: a large file pasted to another disk goes as
// fast as a bare copyfile call, and the time a small folder's paste takes is reported
import CFileTrail
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct PasteThroughputTests {
    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    // A 150 MB file pasted to another volume (a real copy, not a clone) by the engine, under its hidden name with
    // its journal entry, and with a bare copyfile call of the same flags. They alternate, 15 runs each, and their
    // medians are compared, so one scheduling spike can't decide it.
    // F-453
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func aPastedLargeFileKeepsWithinFivePercentOfABareCopyfile() async throws {
        try await withTemporaryDirectory(prefix: "paste-throughput") { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let source = root.path + "/big.bin"
                try NativeTestFiles.makeFile(source, megabytes: 150)
                let journal = FileWriteJournal.open(root.path + "/replace-journal.json")
                func bare() throws -> Double {
                    let destination = volume.path + "/bare.bin"
                    let started = ContinuousClock.now
                    let errnum = ft_copyfile(source, destination, nil)
                    let elapsed = ContinuousClock.now - started
                    #expect(errnum == 0)
                    #expect(unlink(destination) == 0)
                    return elapsed / .seconds(1)
                }
                func pasted() async throws -> Double {
                    let fileSystem = NativeWriteFileSystem()
                    let operation = try realOperation(fileSystem, mode: .copy, sources: [source], into: volume.path)
                    let started = ContinuousClock.now
                    let events = await execute(fileSystem, operation, writeJournal: journal)
                    let elapsed = ContinuousClock.now - started
                    #expect(events.last?.result?.status == .completed)
                    #expect(unlink(volume.path + "/big.bin") == 0)
                    return elapsed / .seconds(1)
                }
                // Warm the caches for both.
                _ = try bare()
                _ = try await pasted()
                var bareTimes: [Double] = []
                var pastedTimes: [Double] = []
                for index in 0..<15 {
                    if index % 2 == 0 {
                        bareTimes.append(try bare())
                        pastedTimes.append(try await pasted())
                    } else {
                        pastedTimes.append(try await pasted())
                        bareTimes.append(try bare())
                    }
                }
                let ratio = median(pastedTimes) / median(bareTimes)
                print("paste throughput: pasted \(median(pastedTimes))s, bare copyfile \(median(bareTimes))s")
                #expect(
                    abs(ratio - 1) <= 0.05,
                    "pasted \(median(pastedTimes))s vs bare \(median(bareTimes))s (\(pastedTimes) vs \(bareTimes))")
            }
        }
    }

    // The tree of exec-copy's "copy a folder with nested items, hidden ones, an empty folder and links": the time
    // its paste takes, 25 runs, reported beside the reference's (measured the same way under Bun).
    @Test func reportsTheTimeASmallFoldersPasteTakes() async throws {
        var times: [Double] = []
        for _ in 0..<25 {
            try await withTemporaryDirectory(prefix: "tree-time") { root in
                let folder = root.path + "/source/f"
                try Disk.write(folder + "/a.txt", "source/f/a.txt\n")
                try Disk.write(folder + "/.hidden", "source/f/.hidden\n")
                try Disk.write(folder + "/deep/er/b.txt", "source/f/deep/er/b.txt\n")
                try Disk.makeDirectories(folder + "/empty")
                try Disk.symlink("a.txt", folder + "/link to a")
                try Disk.symlink("nowhere", folder + "/broken")
                try Disk.write(folder + "/run.sh", "#!/bin/sh\n")
                Disk.chmod(folder + "/run.sh", 0o755)
                try Disk.makeDirectories(root.path + "/destination")
                let fileSystem = NativeWriteFileSystem()
                let operation = try realOperation(
                    fileSystem, mode: .copy, sources: [folder], into: root.path + "/destination",
                    policy: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip))
                let started = ContinuousClock.now
                let events = await execute(fileSystem, operation)
                times.append((ContinuousClock.now - started) / .milliseconds(1))
                #expect(events.last?.result?.status == .completed)
            }
        }
        print("exec-copy case 1 paste: median \(median(times)) ms (min \(times.min() ?? 0))")
    }
}
