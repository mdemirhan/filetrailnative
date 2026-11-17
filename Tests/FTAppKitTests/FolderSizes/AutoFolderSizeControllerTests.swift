import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
struct AutoFolderSizeControllerTests {
    let jobs = FakeJobs()
    let timers = ManualTimers()
    let sizes: WindowFolderSizes
    let auto: AutoFolderSizeController

    init() {
        sizes = WindowFolderSizes(backend: jobs, owner: 1, homePath: "/Users/demo", scheduler: timers) { [timers] in
            timers.time
        }
        auto = AutoFolderSizeController(sizes: sizes, scheduler: timers)
    }

    /// Past the moment a folder has to stay selected.
    private func wait() {
        timers.advance(AutoFolderSize.delayMilliseconds / 1000 + 0.001)
    }

    /// Less than that moment.
    private func aMomentLater() {
        timers.advance(0.005)
    }

    // A folder that stays selected is measured, at low priority and not forced; it is stopped
    // when another is selected.
    @Test func measuresAFolderThatStaysSelectedAndStopsItWhenAnotherIsSelected() {
        auto.setPath("/Users/demo/a")
        wait()
        #expect(jobs.starts.count == 1)
        #expect(jobs.starts.first?.path == "/Users/demo/a")
        #expect(jobs.starts.first?.automatic == true && jobs.starts.first?.recalculate == false)
        auto.setPath("/Users/demo/b")
        #expect(jobs.cancels == ["job-1"])
        #expect(sizes.cachedEntry("/Users/demo/a") == .idle)
    }

    // Folders passed on the way are never measured.
    @Test func foldersPassedOnTheWayAreNotMeasured() {
        auto.setPath("/Users/demo/a")
        aMomentLater()
        auto.setPath("/Users/demo/b")
        aMomentLater()
        auto.setPath(nil)
        wait()
        #expect(jobs.starts.isEmpty)
    }

    // The Info Row's folder waits the same moment as the panel's.
    @Test func waitsTheSameMomentForTheInfoRowsFolderAsForThePanels() {
        func path(_ selected: String) -> String? {
            AutoFolderSize.path(
                infoPanelOpen: false, infoRowOpen: true, selectedPaths: [selected],
                selected: (selected, FTFoundation.EntryKind.directory), homePath: "/Users/demo")
        }
        auto.setPath(path("/Users/demo/a"))
        for name in ["b", "c", "d"] {
            aMomentLater()
            auto.setPath(path("/Users/demo/\(name)"))
        }
        #expect(jobs.starts.isEmpty)
        wait()
        #expect(jobs.starts.map(\.path) == ["/Users/demo/d"])
        #expect(jobs.starts.first?.automatic == true)
    }

    // A known size is left alone; another folder being measured is neither waited for nor stopped: the jobs run
    // what was asked for first.
    @Test func knownSizesAreLeftAloneAndOtherCalculationsAreNotStopped() {
        jobs.known = ["/Users/demo/known": 5]
        _ = sizes.entry("/Users/demo/known")
        sizes.flushProbes()
        auto.setPath("/Users/demo/known")
        wait()
        #expect(jobs.starts.isEmpty)
        jobs.nextStart = FolderSizeStartResponse(jobId: "other", status: .running)
        sizes.calculate("/Users/demo/other")
        jobs.nextStart = FolderSizeStartResponse(jobId: "auto", status: .queued)
        auto.setPath("/Users/demo/fresh")
        wait()
        #expect(jobs.starts.map(\.path) == ["/Users/demo/other", "/Users/demo/fresh"])
        #expect(jobs.starts.last?.automatic == true)
        #expect(jobs.cancels.isEmpty)
        // Left while it waits, it is taken back.
        auto.setPath(nil)
        #expect(jobs.cancels == ["auto"])
    }

    // A failed measurement is not run again by itself.
    @Test func aFailedFolderIsLeftAlone() {
        jobs.statuses["job-1"] = FolderSizeJob(jobId: "job-1", path: "/Users/demo/a", status: .error, error: "No")
        sizes.calculate("/Users/demo/a")
        timers.advance(WindowFolderSizes.pollInterval)
        auto.setPath("/Users/demo/a")
        wait()
        #expect(jobs.starts.count == 1)
    }

    // A calculation Calculate Size started is not stopped when the selection moves on.
    @Test func aCalculationStartedByCalculateSizeIsNotStopped() {
        sizes.calculate("/Users/demo/a")
        auto.setPath("/Users/demo/a")
        wait()
        #expect(jobs.starts.count == 1)
        auto.setPath(nil)
        #expect(jobs.cancels.isEmpty)
    }

    // Calculate Size on the folder being measured by itself joins that measurement, under the same job: asked for
    // now, it is not stopped when the selection moves on, nor when it is measured by itself again and left again.
    @Test func itsOwnCalculationAskedForSinceIsNotStopped() {
        auto.setPath("/Users/demo/a")
        wait()
        #expect(jobs.starts.map(\.automatic) == [true])
        sizes.calculate("/Users/demo/a")
        #expect(jobs.starts.map(\.automatic) == [true, false])
        #expect(sizes.isAskedFor("/Users/demo/a"))
        auto.setPath(nil)
        #expect(jobs.cancels.isEmpty)
        #expect(sizes.cachedEntry("/Users/demo/a") == .calculating(jobID: "job-1"))
        // Once it has ended, the next one the app starts is its own again.
        jobs.finish("job-1", "/Users/demo/a", size: 5)
        sizes.settled(jobId: "job-1")
        #expect(!sizes.isAskedFor("/Users/demo/a"))
    }

    // Nor is one Calculate Size started over the controller's own: only its own job is stopped.
    @Test func aCalculationStartedOverItsOwnIsNotStopped() {
        auto.setPath("/Users/demo/a")
        wait()
        #expect(jobs.starts.map(\.automatic) == [true])
        jobs.nextStart = FolderSizeStartResponse(jobId: "job-2", status: .running)
        sizes.calculate("/Users/demo/a", recalculate: true)
        auto.setPath(nil)
        #expect(jobs.cancels.isEmpty)
        #expect(sizes.cachedEntry("/Users/demo/a") == .calculating(jobID: "job-2"))
    }
}
