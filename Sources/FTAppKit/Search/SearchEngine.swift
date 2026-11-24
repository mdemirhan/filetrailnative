import FTFileSystem
import FTFoundation
import Foundation

/// What a window's searches run on: starting one, asking how it is doing from a cursor, and stopping it.
@MainActor
protocol SearchEngine: AnyObject {
    /// The new job's id; it starts running.
    func start(_ request: SearchRequest) throws -> String
    func update(jobID: String, cursor: Int) throws -> SearchUpdate
    func cancel(jobID: String)
}

/// The app's one search runtime: every window's searches are its jobs (`search-1`, `search-2`, …), each a walk of the
/// disk on threads of its own. Quitting stops them all.
@MainActor
final class SearchRuntime: SearchEngine {
    static let shared = SearchRuntime()

    private let runtime = WalkSearchRuntime()

    func start(_ request: SearchRequest) throws -> String {
        runtime.startSearch(request).jobId
    }

    func update(jobID: String, cursor: Int) throws -> SearchUpdate {
        try runtime.getUpdate(jobId: jobID, cursor: cursor)
    }

    func cancel(jobID: String) {
        runtime.cancelSearch(jobId: jobID)
    }

    /// Every running search is stopped and every job forgotten: the app is quitting.
    func close() {
        runtime.close()
    }
}
