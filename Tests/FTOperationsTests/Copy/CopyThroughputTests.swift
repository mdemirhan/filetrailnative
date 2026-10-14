// The copy throughput budget (docs/port/PLAN.md §4): the stoppable copy is as fast as a bare copyfile call
import CFileTrail
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct CopyThroughputTests {
    // A 150 MB file copied to another volume (a real copy, not a clone) with the stoppable copy, its stop flag and
    // progress, and with a bare copyfile call of the same flags and no callback. Other builds load the machine
    // meanwhile: the two alternate, 15 runs each (one copy takes a fifth of a second, so a few runs are noisy), and
    // their medians are compared, so one scheduling spike can't decide it.
    // F-404 F-410
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func theStoppableCopyKeepsWithinFivePercentOfABareCopyfile() async throws {
        try await withTemporaryDirectory(prefix: "copy-throughput") { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let source = root.appending("big.bin").path
                try NativeTestFiles.makeFile(source, megabytes: 150)
                let stoppable = StoppableCopy()
                var run = 0
                func timed(_ copy: (String) throws -> Void) throws -> Double {
                    run += 1
                    let destination = volume.path + "/copy-\(run).bin"
                    let started = ContinuousClock.now
                    try copy(destination)
                    let elapsed = ContinuousClock.now - started
                    #expect(unlink(destination) == 0)
                    return elapsed / .seconds(1)
                }
                let bare: (String) throws -> Void = { destination in
                    let errnum = ft_copyfile(source, destination, nil)
                    if errnum != 0 {
                        throw NativeError.errno(errnum, syscall: "copyfile", path: source, dest: destination)
                    }
                }
                let stoppableCopy: (String) throws -> Void = { destination in
                    try stoppable.copyFile(source, to: destination, stop: StopSignal(), onProgress: { _ in })
                }
                // Warm the caches for both.
                _ = try timed(bare)
                _ = try timed(stoppableCopy)
                var bareTimes: [Double] = []
                var stoppableTimes: [Double] = []
                for index in 0..<15 {
                    if index % 2 == 0 {
                        bareTimes.append(try timed(bare))
                        stoppableTimes.append(try timed(stoppableCopy))
                    } else {
                        stoppableTimes.append(try timed(stoppableCopy))
                        bareTimes.append(try timed(bare))
                    }
                }
                let bareMedian = median(bareTimes)
                let stoppableMedian = median(stoppableTimes)
                let ratio = stoppableMedian / bareMedian
                #expect(
                    abs(ratio - 1) <= 0.05,
                    "stoppable \(stoppableMedian)s vs bare \(bareMedian)s (\(stoppableTimes) vs \(bareTimes))")
            }
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
