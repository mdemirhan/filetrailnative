// Searches run by File Trail's own walk of the disk (search.c): each job a walk on a few threads, whose matches are
// kept as they are found. The UI asks for the results found since its last look (`getUpdate`).
import CFileTrail
import Darwin
import FTFoundation
import Foundation
import os

public final class WalkSearchRuntime: @unchecked Sendable {
    private static let maxFinishedJobRecords = 64

    /// One search's walk: what it keeps of each item, and what it has kept. Worker threads add to it; the runtime reads
    /// it under its lock.
    final class Walk: @unchecked Sendable {
        let rootPath: String
        let match: SearchNameMatch
        let conditions: SearchConditionCheck
        let limit: Int
        private let lock = NSLock()
        /// Items the conditions read beyond their folder's entry.
        private let read = OSAllocatedUnfairLock(initialState: 0)
        private var items: [SearchResultItem] = []
        private(set) var truncated = false
        private(set) var tooSlow = false
        fileprivate var handle: OpaquePointer?

        /// One for each of the walk's threads, each touched by its own thread alone.
        private let scratches: [SearchNameMatch.Scratch]

        init(rootPath: String, match: SearchNameMatch, conditions: SearchConditionCheck, limit: Int, threads: Int) {
            self.rootPath = rootPath
            self.match = match
            self.conditions = conditions
            self.limit = limit
            scratches = (0..<max(1, threads)).map { _ in SearchNameMatch.Scratch() }
        }

        deinit {
            if let handle { ft_search_destroy(handle) }
        }

        var count: Int { lock.withLock { items.count } }

        var itemsRead: Int { read.withLock { $0 } }

        /// Walks to the end on the calling thread and the walk's workers.
        func run() -> ft_search_result {
            guard let handle else { return ft_search_result(errnum: ENOMEM, unreadable_folders: 0, stopped: 0) }
            return ft_search_run(handle)
        }

        func cancel() {
            if let handle { ft_search_cancel(handle) }
        }

        func items(from cursor: Int) -> (items: [SearchResultItem], next: Int) {
            lock.withLock {
                let start = max(0, min(cursor, items.count))
                return (Array(items[start...]), items.count)
            }
        }

        /// Whether an item the walk passed is what the search looks for, from a worker thread (`FT_SEARCH_…`). Its
        /// name, or its whole path, is matched from its bytes; a pattern that took too long ends the walk.
        /// The conditions that the folder's entry answers (kind, extension, a link) come after the name, as cheap.
        func match(_ path: UnsafeRawBufferPointer, nameOffset: Int, worker: Int, isFolder: Bool, isLink: Bool) -> Int32
        {
            let pathBytes = path.bindMemory(to: UInt8.self)
            // A folder the search leaves out, before anything else is asked of it: neither listed nor gone into.
            if isFolder, conditions.skips(UnsafeBufferPointer(rebasing: pathBytes[nameOffset...])) {
                return Int32(FT_SEARCH_SKIP)
            }
            let scratch = scratches[worker % scratches.count]
            switch match.outcome(path: pathBytes, nameOffset: nameOffset, worker: worker, scratch: scratch) {
            case .noMatch:
                return Int32(FT_SEARCH_NO_MATCH)
            case .tooSlow:
                lock.withLock { tooSlow = true }
                return Int32(FT_SEARCH_STOP)
            case .match:
                let name = String(decoding: pathBytes[nameOffset...], as: UTF8.self)
                guard conditions.keepsByEntry(name: name, isFolder: isFolder, isLink: isLink) else {
                    return Int32(FT_SEARCH_NO_MATCH)
                }
                return Int32(FT_SEARCH_MATCH)
            }
        }

        /// `/.vol/<disk>/<number>`: a path to the item named at `nameOffset` of `path`, in the open `folder`, that
        /// is short however deep the item is. Nil where it can't be read from its folder; a disk that has no such
        /// paths (FAT, a network disk) fails the reads made by it, as a path too long does.
        static func pathByNumber(
            _ path: UnsafeRawBufferPointer, nameOffset: Int, folder: Int32, info: inout stat?
        ) -> String? {
            guard folder >= 0, let base = path.baseAddress else { return nil }
            if info == nil {
                // The walk's path ends in a NUL, so the name is a C string.
                var read = stat()
                let name = (base + nameOffset).assumingMemoryBound(to: CChar.self)
                guard fstatat(folder, name, &read, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                info = read
            }
            return info.map { "/.vol/\($0.st_dev)/\($0.st_ino)" }
        }

        /// A match the walk keeps, from a worker thread. True ends the walk: the results reached the limit.
        /// The conditions that read the item are checked here, of what the name and the entry kept.
        func keep(
            _ path: UnsafeRawBufferPointer, nameOffset: Int, isFolder: Bool, isHidden: Bool, isLink: Bool,
            info: UnsafePointer<stat>? = nil, folder: Int32 = -1
        ) -> Bool {
            let fullPath = String(decoding: path, as: UTF8.self)
            if conditions.readsEachItem {
                read.withLock { $0 += 1 }
                // The walk goes deeper than a path one call takes (`PATH_MAX`): the conditions' reads, which are by
                // path, then go by the item's number on its disk, found from its folder.
                var read = info?.pointee
                let readPath =
                    path.count >= Int(PATH_MAX)
                    ? Self.pathByNumber(path, nameOffset: nameOffset, folder: folder, info: &read) : nil
                guard
                    conditions.keepsByItem(
                        path: readPath ?? fullPath, isFolder: isFolder, isHidden: isHidden, isLink: isLink, info: read)
                else { return false }
            } else if !conditions.keepsByItem(path: fullPath, isFolder: isFolder, isHidden: isHidden, isLink: isLink) {
                return false
            }
            let name = String(decoding: path[nameOffset...], as: UTF8.self)
            // The folder is the path up to the slash before the name ("/" for an item at the top of the disk).
            let parentPath =
                nameOffset <= 1 ? "/" : String(decoding: path[..<(nameOffset - 1)], as: UTF8.self)
            var item = SearchResults.item(
                rootPath: rootPath, path: fullPath, name: name, parentPath: parentPath, isFolder: isFolder,
                isHidden: isHidden)
            if isLink {
                item.isSymlink = true
                item.kind = .symlinkFile
            }
            return lock.withLock {
                guard items.count < limit else {
                    truncated = true
                    return true
                }
                items.append(item)
                if items.count >= limit {
                    truncated = true
                    return true
                }
                return false
            }
        }
    }

    private struct Job {
        var walk: Walk
        var status: SearchJobStatus = .running
        var error: String?
        var unreadableFolders = false
        var done = false
    }

    private struct FinishedJob {
        var status: SearchJobStatus
        var truncated: Bool
        var error: String?
        var itemCount: Int
        var unreadableFolders: Bool
    }

    /// Worker threads per walk; 0 for the walk's own default.
    private let threads: Int
    /// The results a search stops at.
    private let limit: Int
    /// Walks whose threads haven't ended yet, stopped or not.
    private let walking = OSAllocatedUnfairLock(initialState: 0)
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var finishedJobs: [String: FinishedJob] = [:]
    private var finishedOrder: [String] = []
    private var sequence = 0

    /// The threads a walk uses unless told otherwise.
    public static var defaultThreads: Int { Int(ft_search_default_threads()) }

    public init(threads: Int = 0, limit: Int = SearchLimits.resultLimit) {
        self.threads = threads
        self.limit = limit
    }

    /// How many walks are still on their threads: one stopped is counted until its threads have let go.
    public var walksRunning: Int { walking.withLock { $0 } }

    public func startSearch(_ request: SearchRequest) -> SearchStartResponse {
        let rootPath = NodePath.resolve(request.rootPath)
        let conditions = SearchConditionCheck(request.conditions)
        // A search for hidden items lists them, whether or not the folder shows them.
        var request = request
        request.includeHidden = request.includeHidden || conditions.wantsHidden
        let match: SearchNameMatch
        do {
            match = try SearchNameMatch(request, copies: threads > 0 ? threads : Self.defaultThreads)
        } catch {
            return failed(error.message)
        }
        let walk = Walk(
            rootPath: rootPath, match: match, conditions: conditions, limit: limit,
            threads: threads > 0 ? threads : Self.defaultThreads)
        let options = ft_search_options(
            recursive: request.recursive ? 1 : 0, include_hidden: request.includeHidden ? 1 : 0,
            skip_git: request.skipGitFolders ? 1 : 0, skip_system_volumes: rootPath == "/" ? 1 : 0,
            threads: Int32(threads), qos_class: 0, include_links: conditions.wantsLinks ? 1 : 0,
            wants_stat: conditions.needsStat ? 1 : 0)
        let handle = ft_search_create(
            rootPath, options, Self.match, Self.keep, Unmanaged.passUnretained(walk).toOpaque())
        guard let handle else {
            return failed(Errno.description(of: ENOMEM))
        }
        walk.handle = handle
        let jobId = lock.withLock {
            sequence += 1
            let id = "search-\(sequence)"
            jobs[id] = Job(walk: walk)
            return id
        }
        // The walk keeps the thread it starts on busy until it ends; the thread holds the walk until then.
        walking.withLock { $0 += 1 }
        let walking = walking
        let thread = Thread { [weak self] in
            let result = walk.run()
            self?.finish(jobId, walk: walk, result: result)
            walking.withLock { $0 -= 1 }
        }
        thread.qualityOfService = .userInitiated
        thread.name = "File Trail search"
        thread.start()
        return SearchStartResponse(jobId: jobId, status: .running)
    }

    /// A job that ended before it began: its pattern can't be used.
    private func failed(_ message: String) -> SearchStartResponse {
        let jobId = lock.withLock {
            sequence += 1
            let id = "search-\(sequence)"
            rememberFinished(
                id,
                FinishedJob(status: .error, truncated: false, error: message, itemCount: 0, unreadableFolders: false))
            return id
        }
        return SearchStartResponse(jobId: jobId, status: .error)
    }

    private static let match: ft_search_match = { context, worker, path, length, nameOffset, isFolder, isLink in
        guard let context, let path else { return Int32(FT_SEARCH_STOP) }
        let walk = Unmanaged<Walk>.fromOpaque(context).takeUnretainedValue()
        return walk.match(
            UnsafeRawBufferPointer(start: path, count: length), nameOffset: nameOffset, worker: Int(worker),
            isFolder: isFolder != 0, isLink: isLink != 0)
    }

    private static let keep: ft_search_keep = {
        context, _, path, length, nameOffset, isFolder, isHidden, isLink, info, folder in
        guard let context, let path else { return 1 }
        let walk = Unmanaged<Walk>.fromOpaque(context).takeUnretainedValue()
        let bytes = UnsafeRawBufferPointer(start: path, count: length)
        return walk.keep(
            bytes, nameOffset: nameOffset, isFolder: isFolder != 0, isHidden: isHidden != 0, isLink: isLink != 0,
            info: info, folder: folder) ? 1 : 0
    }

    private func finish(_ jobId: String, walk: Walk, result: ft_search_result) {
        lock.withLock {
            guard var job = jobs[jobId], !job.done else { return }
            job.unreadableFolders = result.unreadable_folders != 0
            if walk.tooSlow {
                job.status = .error
                job.error = SearchPatternError.tooSlow.message
            } else if walk.truncated {
                job.status = .truncated
            } else if result.errnum != 0 {
                job.status = .error
                job.error = "Can’t search “\(walk.rootPath)”: \(Errno.description(of: result.errnum))"
            } else {
                job.status = .complete
            }
            job.done = true
            jobs[jobId] = job
        }
    }

    public func getUpdate(jobId: String, cursor: Int) throws -> SearchUpdate {
        try lock.withLock {
            guard let job = jobs[jobId] else {
                guard let finished = finishedJobs[jobId] else { throw UnknownSearchJob(jobId: jobId) }
                return SearchUpdate(
                    jobId: jobId, status: finished.status, items: [],
                    nextCursor: max(0, min(cursor, finished.itemCount)), done: true, truncated: finished.truncated,
                    error: finished.error, unreadableFolders: finished.unreadableFolders)
            }
            let (items, next) = job.walk.items(from: cursor)
            let truncated = job.status == .truncated
            let update = SearchUpdate(
                jobId: jobId, status: job.status, items: items, nextCursor: next, done: job.done,
                truncated: truncated, error: job.error, unreadableFolders: job.unreadableFolders,
                itemsRead: job.walk.itemsRead)
            if job.done {
                // The final response carries every remaining item, so the job is let go, its end remembered so later
                // polls answer the same.
                jobs[jobId] = nil
                rememberFinished(
                    jobId,
                    FinishedJob(
                        status: job.status, truncated: truncated, error: job.error, itemCount: next,
                        unreadableFolders: job.unreadableFolders))
            }
            return update
        }
    }

    /// Stops a job. One unknown or already finished is fine.
    public func cancelSearch(jobId: String) {
        let walk: Walk? = lock.withLock {
            guard var job = jobs[jobId] else { return nil }
            let running = !job.done
            if running {
                job.status = .cancelled
                job.done = true
            }
            jobs[jobId] = nil
            rememberFinished(
                jobId,
                FinishedJob(
                    status: job.status, truncated: job.status == .truncated, error: job.error,
                    itemCount: job.walk.count, unreadableFolders: job.unreadableFolders))
            return running ? job.walk : nil
        }
        walk?.cancel()
    }

    /// Every search still running is stopped and every job forgotten: the app is quitting.
    public func close() {
        let walks: [Walk] = lock.withLock {
            let running = jobs.values.filter { !$0.done }.map(\.walk)
            jobs.removeAll()
            finishedJobs.removeAll()
            finishedOrder.removeAll()
            return running
        }
        for walk in walks {
            walk.cancel()
        }
    }

    private func rememberFinished(_ jobId: String, _ finished: FinishedJob) {
        finishedJobs[jobId] = finished
        finishedOrder.removeAll { $0 == jobId }
        finishedOrder.append(jobId)
        while finishedJobs.count > Self.maxFinishedJobRecords, let oldest = finishedOrder.first {
            finishedOrder.removeFirst()
            finishedJobs[oldest] = nil
        }
    }
}
