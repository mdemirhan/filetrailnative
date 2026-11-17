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

    /// Every window's runs of several folders with folders still waiting their turn, for the Activity list.
    var waitingRuns: [FolderSizeRunActivity] {
        router.windows.sorted { $0.key < $1.key }.flatMap { windowID, sizes in
            (sizes.value?.waitingRuns ?? []).map {
                FolderSizeRunActivity(id: "run:\(windowID):\($0.run)", waitingCount: $0.count)
            }
        }
    }

    /// The folders waiting in the run `waitingRuns` listed under `id` wait no more.
    func stopRun(_ id: String) {
        let parts = id.split(separator: ":")
        guard parts.count == 3, let windowID = Int(parts[1]), let run = Int(parts[2]) else { return }
        router.windows[windowID]?.value?.cancelWaiting(ofRun: run)
    }

    /// A window closed: its measurements are stopped, those waiting and the one under way.
    func forget(windowID: Int) {
        router.windows[windowID]?.value?.stopAll()
        router.windows[windowID] = nil
        jobs.forgetOwner(windowID)
    }
}
