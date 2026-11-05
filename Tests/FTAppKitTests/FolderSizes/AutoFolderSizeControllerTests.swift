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

    // Known sizes, failures and other calculations are left alone.
    @Test func knownSizesFailuresAndOtherCalculationsAreLeftAlone() {
        jobs.known = ["/Users/demo/known": 5]
        _ = sizes.entry("/Users/demo/known")
        sizes.flushProbes()
        auto.setPath("/Users/demo/known")
        wait()
        #expect(jobs.starts.isEmpty)
        // Another folder being measured: a new calculation would stop it.
        sizes.calculate("/Users/demo/other")
        let before = jobs.starts.count
        auto.setPath("/Users/demo/fresh")
        wait()
        #expect(jobs.starts.count == before)
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

    // Nor is one Calculate Size started over the controller's own: only its own job is stopped.
    @Test func aCalculationStartedOverItsOwnIsNotStopped() {
        auto.setPath("/Users/demo/a")
        wait()
        #expect(jobs.starts.map(\.automatic) == [true])
        jobs.nextStart = JobStart(jobId: "job-2", status: .running)
        sizes.calculate("/Users/demo/a", recalculate: true)
        auto.setPath(nil)
        #expect(jobs.cancels.isEmpty)
        #expect(sizes.cachedEntry("/Users/demo/a") == .calculating(jobID: "job-2"))
    }
}
