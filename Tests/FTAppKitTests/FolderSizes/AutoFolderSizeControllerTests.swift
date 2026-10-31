// Ports the cases of apps/desktop/src/renderer/hooks/useAutoFolderSize.test.tsx that need time and the folder size cache
// (B-INFO-169 to B-INFO-172), over the stand-in jobs of WindowFolderSizesTests
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
        // Long enough that a busy Mac doesn't let it pass between two selections 5 ms apart.
        auto = AutoFolderSizeController(sizes: sizes, delay: 0.3)
    }

    private func wait(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // T-0d2d52b8 B-INFO-169 B-INFO-171 F-824: a folder that stays selected is measured, at low priority and not forced; it is stopped
    // when another is selected.
    @Test func measuresAFolderThatStaysSelectedAndStopsItWhenAnotherIsSelected() async {
        auto.setPath("/Users/demo/a")
        await wait()
        #expect(jobs.starts.count == 1)
        #expect(jobs.starts.first?.path == "/Users/demo/a")
        #expect(jobs.starts.first?.automatic == true && jobs.starts.first?.recalculate == false)
        auto.setPath("/Users/demo/b")
        #expect(jobs.cancels == ["job-1"])
        #expect(sizes.cachedEntry("/Users/demo/a") == .idle)
    }

    // T-351a9dd4 B-INFO-169: folders passed on the way are never measured.
    @Test func foldersPassedOnTheWayAreNotMeasured() async {
        auto.setPath("/Users/demo/a")
        try? await Task.sleep(for: .milliseconds(5))
        auto.setPath("/Users/demo/b")
        try? await Task.sleep(for: .milliseconds(5))
        auto.setPath(nil)
        await wait()
        #expect(jobs.starts.isEmpty)
    }

    // T-0b52dad4 B-INFO-169 B-INFO-203: the Info Row's folder waits the same moment as the panel's.
    @Test func waitsTheSameMomentForTheInfoRowsFolderAsForThePanels() async {
        func path(_ selected: String) -> String? {
            AutoFolderSize.path(
                infoPanelOpen: false, infoRowOpen: true, selectedPaths: [selected],
                selected: (selected, FTFoundation.EntryKind.directory), homePath: "/Users/demo")
        }
        auto.setPath(path("/Users/demo/a"))
        for name in ["b", "c", "d"] {
            try? await Task.sleep(for: .milliseconds(5))
            auto.setPath(path("/Users/demo/\(name)"))
        }
        #expect(jobs.starts.isEmpty)
        await wait()
        #expect(jobs.starts.map(\.path) == ["/Users/demo/d"])
        #expect(jobs.starts.first?.automatic == true)
    }

    // T-71d4c4fb B-INFO-170: known sizes, failures and other calculations are left alone.
    @Test func knownSizesFailuresAndOtherCalculationsAreLeftAlone() async {
        jobs.known = ["/Users/demo/known": 5]
        _ = sizes.entry("/Users/demo/known")
        sizes.flushProbes()
        auto.setPath("/Users/demo/known")
        await wait()
        #expect(jobs.starts.isEmpty)
        // Another folder being measured: a new calculation would stop it.
        sizes.calculate("/Users/demo/other")
        let before = jobs.starts.count
        auto.setPath("/Users/demo/fresh")
        await wait()
        #expect(jobs.starts.count == before)
    }

    // B-INFO-171: a calculation Calculate Size started is not stopped when the selection moves on.
    @Test func aCalculationStartedByCalculateSizeIsNotStopped() async {
        sizes.calculate("/Users/demo/a")
        auto.setPath("/Users/demo/a")
        await wait()
        #expect(jobs.starts.count == 1)
        auto.setPath(nil)
        #expect(jobs.cancels.isEmpty)
    }

    // T-e316ae44 B-INFO-171: nor is one Calculate Size started over the controller's own: only its own job is stopped.
    @Test func aCalculationStartedOverItsOwnIsNotStopped() async {
        auto.setPath("/Users/demo/a")
        await wait()
        #expect(jobs.starts.map(\.automatic) == [true])
        jobs.nextStart = JobStart(jobId: "job-2", status: .running)
        sizes.calculate("/Users/demo/a", recalculate: true)
        auto.setPath(nil)
        #expect(jobs.cancels.isEmpty)
        #expect(sizes.cachedEntry("/Users/demo/a") == .calculating(jobID: "job-2"))
    }
}
