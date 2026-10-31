// Port of the folder size channels of apps/desktop/src/main/bootstrap (folderSize:* and the settled message), as the windows
// of the app use them
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
    }

    private let router = Router()
    let jobs: FolderSizeJobs

    private init() {
        let router = router
        jobs = FolderSizeJobs(
            native: NativeFolderSize(),
            onSettled: { owner, jobId in
                MainActor.assumeIsolated { router.settled(owner: owner, jobId: jobId) }
            })
    }

    /// The cache of the window `windowID`.
    func sizes(for windowID: Int) -> WindowFolderSizes {
        let sizes = WindowFolderSizes(backend: jobs, owner: windowID)
        router.windows[windowID] = Weak(sizes)
        return sizes
    }

    /// A window closed: its measurements are stopped, those waiting and the one under way.
    func forget(windowID: Int) {
        router.windows[windowID]?.value?.stopAll()
        router.windows[windowID] = nil
        jobs.forgetOwner(windowID)
    }
}
