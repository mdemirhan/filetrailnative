// The copy throughput budget (tools/bench/budgets.json, ): a large file pasted to another disk, and the stoppable copy on
// its own, go as fast as a bare copyfile call, and the time a small folder's paste takes is reported
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

    // A 150 MB file copied to another volume (a real copy, not a clone) three ways: by the engine's paste, under its
    // hidden name with its journal entry; by the stoppable copy, with its stop flag and progress; and by a bare
    // copyfile call of the same flags and no callback. Each of the first two keeps within 5 % of the bare call. Other
    // builds load the machine meanwhile: the three take turns, 15 runs each (one copy takes a fifth of a second, so
    // a few runs are noisy), and their medians are compared, so one scheduling spike can't decide it.
    // F-404 F-410 F-453
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func aPastedLargeFileAndTheStoppableCopyKeepWithinFivePercentOfABareCopyfile() async throws {
        try await withTemporaryDirectory(prefix: "paste-throughput") { root in
            try await DiskImage.withSharedVolume(.apfs) { volume in
                let source = root.path + "/big.bin"
                try NativeTestFiles.makeFile(source, megabytes: 150)
                let journal = FileWriteJournal.open(root.path + "/replace-journal.json")
                let stoppable = StoppableCopy()
                func timed(_ destination: String, _ copy: () throws -> Void) throws -> Double {
                    let started = ContinuousClock.now
                    try copy()
                    let elapsed = ContinuousClock.now - started
                    #expect(unlink(destination) == 0)
                    return elapsed / .seconds(1)
                }
                func bare() throws -> Double {
                    let destination = volume.path + "/bare.bin"
                    return try timed(destination) {
                        let errnum = ft_copyfile(source, destination, nil)
                        if errnum != 0 {
                            throw NativeError.errno(errnum, syscall: "copyfile", path: source, dest: destination)
                        }
                    }
                }
                func stopped() throws -> Double {
                    let destination = volume.path + "/stoppable.bin"
                    return try timed(destination) {
                        try stoppable.copyFile(source, to: destination, stop: StopSignal(), onProgress: { _ in })
                    }
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
                // Warm the caches for all three.
                _ = try bare()
                _ = try stopped()
                _ = try await pasted()
                var bareTimes: [Double] = []
                var stoppableTimes: [Double] = []
                var pastedTimes: [Double] = []
                for index in 0..<15 {
                    switch index % 3 {
                    case 0:
                        bareTimes.append(try bare())
                        stoppableTimes.append(try stopped())
                        pastedTimes.append(try await pasted())
                    case 1:
                        stoppableTimes.append(try stopped())
                        pastedTimes.append(try await pasted())
                        bareTimes.append(try bare())
                    default:
                        pastedTimes.append(try await pasted())
                        bareTimes.append(try bare())
                        stoppableTimes.append(try stopped())
                    }
                }
                let (bareMedian, stoppableMedian) = (median(bareTimes), median(stoppableTimes))
                let pastedMedian = median(pastedTimes)
                print(
                    "paste throughput: pasted \(pastedMedian)s, stoppable copy \(stoppableMedian)s,"
                        + " bare copyfile \(bareMedian)s")
                #expect(
                    abs(stoppableMedian / bareMedian - 1) <= 0.05,
                    "stoppable \(stoppableMedian)s vs bare \(bareMedian)s (\(stoppableTimes) vs \(bareTimes))")
                #expect(
                    abs(pastedMedian / bareMedian - 1) <= 0.05,
                    "pasted \(pastedMedian)s vs bare \(bareMedian)s (\(pastedTimes) vs \(bareTimes))")
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
