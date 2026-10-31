// Port of the search:start, search:getUpdate and search:cancel calls the renderer makes (useExplorerSearchController.ts,
// useExplorerTabs.ts), and the runtime the worker keeps for them (packages/core/src/worker/explorerWorker.ts)
import FTFileSystem
import FTFoundation
import Foundation

/// What a window's searches run on: starting one, asking how it is doing from a cursor, and stopping it.
@MainActor
protocol SearchEngine: AnyObject {
    /// The new job's id; it starts running.
    func start(_ request: SearchRequest) throws -> String
    func update(jobID: String, cursor: Int) throws -> TabSearchUpdate
    func cancel(jobID: String)
}

/// The app's one `fd` runtime: every window's searches are its jobs (`search-1`, `search-2`, …). Quitting stops them
/// all, so no `fd` goes on searching after the app.
@MainActor
final class SearchRuntime: SearchEngine {
    static let shared = SearchRuntime()

    private var runtime: FdSearchRuntime?
    /// Why the bundled `fd` could not be found, once it was looked for.
    private var unavailable: (any Error)?

    /// Made on first use: the bundled `fd` is looked for then.
    private func resolved() throws -> FdSearchRuntime {
        if let runtime { return runtime }
        if let unavailable { throw unavailable }
        do {
            let made = FdSearchRuntime(fdBinaryPath: try FdBinary.resolveBundledPath())
            runtime = made
            return made
        } catch {
            unavailable = error
            throw error
        }
    }

    func start(_ request: SearchRequest) throws -> String {
        try resolved().startSearch(request).jobId
    }

    func update(jobID: String, cursor: Int) throws -> TabSearchUpdate {
        TabSearchUpdate(try resolved().getUpdate(jobId: jobID, cursor: cursor))
    }

    func cancel(jobID: String) {
        runtime?.cancelSearch(jobId: jobID)
    }

    /// Every running search is stopped (SIGTERM) and every job forgotten: the app is quitting.
    func close() {
        runtime?.close()
    }
}
