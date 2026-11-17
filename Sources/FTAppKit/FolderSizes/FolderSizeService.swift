import FTFileSystem
import FTFoundation
import Foundation

/// The app's folder size jobs, shared by every window (one measurement is under way per app at a time), and each
/// window's cache over them. Made the first time a window asks.
@MainActor
final class FolderSizeService {
    static let shared = FolderSizeService()

    /// Tells the window that asked for a measurement that it ended.
    @MainActor
    private final class Router {
        var windows: [Int: Weak<WindowFolderSizes>] = [:]

        func settled(owner: Int?, jobId: String) {
            guard let owner else { return }
            windows[owner]?.value?.settled(jobId: jobId)
        }

        func stored() {
            for window in windows.values { window.value?.sizesStored() }
        }
    }

    private let router = Router()
    let jobs: FolderSizeJobs

    private init() {
        let router = router
        jobs = FolderSizeJobs(
            native: NativeFolderSize(),
            onSettled: { owner, jobId in
                MainActor.assumeIsolated { router.settled(owner: owner, jobId: jobId) }
            },
            onStored: {
                MainActor.assumeIsolated { router.stored() }
            })
        jobs.onActivityChanged = { ActivityCenter.shared.sizesChanged() }
    }

    /// The cache of the window `windowID`.
    func sizes(for windowID: Int) -> WindowFolderSizes {
        let sizes = WindowFolderSizes(backend: jobs, owner: windowID)
        sizes.onRunsChanged = { ActivityCenter.shared.sizesChanged() }
        router.windows[windowID] = Weak(sizes)
        return sizes
    }

    /// Every window's runs of several folders under way, for the Activity list.
    var activeRuns: [FolderSizeRunActivity] {
        router.windows.sorted { $0.key < $1.key }.flatMap { windowID, sizes in
            (sizes.value?.activeRuns ?? []).map {
                FolderSizeRunActivity(
                    id: "run:\(windowID):\($0.run)", folderCount: $0.total, doneCount: $0.done, jobId: $0.jobId,
                    isWaiting: $0.waiting)
            }
        }
    }

    private func run(_ id: String) -> (sizes: WindowFolderSizes, run: Int)? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, let windowID = Int(parts[1]), let run = Int(parts[2]),
            let sizes = router.windows[windowID]?.value
        else { return nil }
        return (sizes, run)
    }

    /// Stops the run `activeRuns` listed under `id`.
    func stopRun(_ id: String) {
        guard let found = run(id) else { return }
        found.sizes.cancelRun(found.run)
    }

    /// How that run ended: true when every folder had its turn, false when stopped, nil when not known.
    func runCompleted(_ id: String) -> Bool? {
        guard let found = run(id) else { return nil }
        return found.sizes.runCompleted(found.run)
    }

    /// A window closed: its measurements are stopped, those waiting and the one under way.
    func forget(windowID: Int) {
        router.windows[windowID]?.value?.stopAll()
        router.windows[windowID] = nil
        jobs.forgetOwner(windowID)
    }
}
