// Port of createFolderSizeHandlers and the folder-size listeners of apps/desktop/src/main/bootstrap/responseCache.ts
import FTFoundation
import Foundation

public enum FolderSizeJobStatus: String, Equatable, Sendable {
    case queued, running, ready, cancelled, error

    var isFinished: Bool { self != .queued && self != .running }
}

/// One measurement as a window sees it.
public struct FolderSizeJob: Equatable, Sendable {
    public var jobId: String
    public var path: String
    public var status: FolderSizeJobStatus
    public var sizeBytes: Int64?
    public var diskBytes: Int64?
    public var fileCount: Int?
    public var folderCount: Int?
    /// The folders inside it whose sizes it has stored so far: the window asks again for the sizes it is
    /// waiting on when this goes up.
    public var measuredFolderCount: Int
    public var error: String?
}

public struct FolderSizeStartRequest: Sendable {
    public var path: String
    public var recalculate: Bool
    /// A measurement the app started itself: it walks at a lower priority.
    public var automatic: Bool

    public init(path: String, recalculate: Bool = false, automatic: Bool = false) {
        self.path = path
        self.recalculate = recalculate
        self.automatic = automatic
    }
}

public struct FolderSizeStartResponse: Equatable, Sendable {
    public var jobId: String
    public var status: FolderSizeJobStatus
}

/// The size known of one folder.
public struct FolderSizeProbe: Equatable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var diskBytes: Int64
    public var fileCount: Int
    public var folderCount: Int
}

public typealias FolderSizeStatus = FolderSizeJob

/// Each folder size job queue, told what a write changed, and when one starts and ends: a size stored while a
/// write runs may have been measured after it had already removed something, so taking the removal off it when
/// the write ends could count the removal twice. (`noteWriteStarting`, `noteWriteEnded` and the folder-size
/// half of `clearResponseCaches` of the original.)
@MainActor
public enum FolderSizeWrites {
    private final class Listener {
        weak var jobs: FolderSizeJobs?

        init(_ jobs: FolderSizeJobs) {
            self.jobs = jobs
        }
    }

    private static var listeners: [Listener] = []

    static func register(_ jobs: FolderSizeJobs) {
        listeners.removeAll { $0.jobs == nil }
        listeners.append(Listener(jobs))
    }

    /// Called as a write starts changing what is on disk.
    public static func noteWriteStarting() {
        for jobs in live { jobs.writeStarting() }
    }

    /// Called once what a write changed has been cleared (`forget`), or when it ended without saying.
    public static func noteWriteEnded() {
        for jobs in live { jobs.writeEnded() }
    }

    /// After a write: the sizes of the folders it touched (what holds them, and what is inside them) are
    /// measured again when next asked for. Items a delete removed are taken off the sizes of the folders that
    /// held them instead, where that can be done exactly (see `FolderSizeAdjust`).
    public static func forget(changedPaths: [String] = [], removedItems: [RemovedItem] = []) {
        guard !changedPaths.isEmpty || !removedItems.isEmpty else { return }
        for jobs in live { jobs.forget(changedPaths: changedPaths, removedItems: removedItems) }
    }

    private static var live: [FolderSizeJobs] {
        listeners.compactMap(\.jobs)
    }
}

/// The folder size jobs: the queue, the cache of what is measured, and what writes do to both.
@MainActor
public final class FolderSizeJobs {
    /// Finished folder-size jobs are kept so repeated status polls stay answerable, but only the most
    /// recent ones; queued and running jobs are never evicted.
    static let maxFinishedJobs = 256

    private let native: any FolderSizeNative
    private let homePath: String
    private let homeTrashPath: String
    private let homeKey: PathKey
    private let homeTrashKey: PathKey
    // Told when a measurement ends (measured, failed or stopped), with the window that asked: it learns at
    // once, rather than at its next look.
    private let onSettled: ((Int?, String) -> Void)?

    // Only a store adds a size, so none goes while removals are taken off. What was stored while a write ran
    // is noted there, until its end has been cleared.
    private let cache = FolderSizeCache()
    // Each measurement run stores its sizes under a number of its own (see `FolderSizeStats`).
    private var measurementCount = 0
    // Whether a measurement that reached the home folder's Trash could read it, and so counted what is in it
    // (only an app with Full Disk Access can): what a move to the Trash does to the sizes of the folders
    // holding the Trash. Learned by measuring, and kept apart from the sizes, which are forgotten when the
    // Trash changes.
    private var homeTrashCounted: Bool?
    // A measurement under way when a write changes what it walks may have seen part of the change: it is
    // stopped and run again rather than kept.
    private var outdatedJobIds = Set<String>()

    // The jobs, oldest first: setting a job moves it to the newest position.
    private var jobs: [String: FolderSizeJob] = [:]
    private var jobOrder: [String: Int] = [:]
    private var jobSequence = 0

    private var activeJobId: String?
    // Measurements waiting for the one that runs, in the order they run. Each window has at most one here:
    // asking again replaces it.
    private var queuedJobIds: [String] = []
    // The window that asked for each job. A window's new measurement stops its own earlier one, never
    // another window's: that one finishes, and the new one waits for it.
    private var jobOwners: [String: Int?] = [:]
    // The jobs the app started itself, which walk at a lower priority.
    private var backgroundJobIds = Set<String>()
    // Set when the app quits: nothing more is measured.
    private var stopped = false

    /// `homePath`: where the home folder is (tests use their own): its Trash is where deleted items go.
    public init(
        native: any FolderSizeNative, homePath: String = NSHomeDirectory(),
        onSettled: ((Int?, String) -> Void)? = nil
    ) {
        self.native = native
        self.homePath = homePath
        homeTrashPath = NodePath.join(homePath, ".Trash")
        homeKey = PathKey(homePath)
        homeTrashKey = PathKey(homeTrashPath)
        self.onSettled = onSettled
        FolderSizeWrites.register(self)
    }

    // MARK: Write interaction

    fileprivate func writeStarting() {
        cache.startRecording()
    }

    fileprivate func writeEnded() {
        cache.stopRecording()
    }

    fileprivate func forget(changedPaths: [String], removedItems: [RemovedItem]) {
        cache.forgetAffected(changedPaths)
        forgetStoredDuringWrite(removedItems)
        FolderSizeAdjust.adjustForRemovals(
            cache, removedItems, HomeTrash(path: homeTrashPath, counted: homeTrashCounted))
        let touchedPaths =
            changedPaths
            + removedItems.flatMap { removed in
                removed.intoHomeTrash == false ? [removed.path] : [removed.path, homeTrashPath]
            }
        // Cancelled but still stopping, it may yet finish: what it stores then is outdated too.
        if let activeJobId, let activeJob = jobs[activeJobId], !outdatedJobIds.contains(activeJobId),
            WriteEffects.isAffectedByChange(activeJob.path, changedPaths: touchedPaths)
        {
            outdatedJobIds.insert(activeJobId)
            if activeJob.status == .running {
                // Stopped now rather than left to finish a walk that is thrown away.
                native.cancelFolderSize()
            }
        }
    }

    /// The sizes stored since the write started of the folders whose totals its removals change (those that
    /// held a removed item, and the Trash and those holding it when it went there): they may already leave
    /// the item out, so they are measured again instead.
    private func forgetStoredDuringWrite(_ removedItems: [RemovedItem]) {
        if removedItems.isEmpty { return }
        cache.forgetRecordedHolding(removedItems.map(\.path), atToo: false)
        if removedItems.contains(where: { $0.intoHomeTrash != false }) {
            cache.forgetRecordedHolding([homeTrashPath], atToo: true)
        }
    }

    // MARK: Jobs

    /// How many jobs are kept (`getResponseCacheSizes().folderSizeJobs`).
    public var jobCount: Int { jobs.count }

    /// Lets go of every job (`resetResponseCacheState`).
    public func clearJobs() {
        jobs.removeAll()
        jobOrder.removeAll()
    }

    private func setFolderSizeJob(_ jobId: String, _ job: FolderSizeJob) {
        // Re-inserting moves the job to the newest position, so a long walk that just finished is not the
        // first finished job evicted before its result is polled.
        jobSequence += 1
        jobs[jobId] = job
        jobOrder[jobId] = jobSequence
    }

    /// Sets a measurement's state, telling its window once it has ended.
    private func setJob(_ jobId: String, _ job: FolderSizeJob) {
        let wasFinished = (jobs[jobId]?.status ?? .queued).isFinished
        setFolderSizeJob(jobId, job)
        if !wasFinished && job.status.isFinished {
            onSettled?(jobOwners[jobId] ?? nil, jobId)
        }
    }

    private func pruneFinishedJobs() {
        var finishedCount = jobs.values.reduce(0) { $0 + ($1.status.isFinished ? 1 : 0) }
        if finishedCount <= Self.maxFinishedJobs { return }
        for jobId in jobOrder.sorted(by: { $0.value < $1.value }).map(\.key) {
            if finishedCount <= Self.maxFinishedJobs { break }
            if jobs[jobId]?.status.isFinished == true {
                jobs[jobId] = nil
                jobOrder[jobId] = nil
                finishedCount -= 1
            }
        }
    }

    private func isOwned(_ jobId: String, by owner: Int?) -> Bool {
        guard let entry = jobOwners[jobId] else { return false }
        return entry == owner
    }

    private func forgetJob(_ jobId: String) {
        jobOwners[jobId] = nil
        backgroundJobIds.remove(jobId)
    }

    private func cancelQueuedJobs(of owner: Int?) {
        queuedJobIds = queuedJobIds.filter { queuedId in
            if !isOwned(queuedId, by: owner) {
                return true
            }
            forgetJob(queuedId)
            if var queued = jobs[queuedId] {
                queued.status = .cancelled
                setJob(queuedId, queued)
            }
            return false
        }
    }

    private func generateJobId() -> String {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let random = String(UInt32.random(in: 0..<0x100_0000), radix: 16)
        return "folder-size-\(millis)-\(String(repeating: "0", count: 6 - random.count))\(random)"
    }

    private func job(
        _ jobId: String, _ path: String, _ status: FolderSizeJobStatus, measuredFolderCount: Int = 0,
        error: String? = nil
    ) -> FolderSizeJob {
        FolderSizeJob(
            jobId: jobId, path: path, status: status, sizeBytes: nil, diskBytes: nil, fileCount: nil,
            folderCount: nil, measuredFolderCount: measuredFolderCount, error: error)
    }

    private func processQueue() {
        while !queuedJobIds.isEmpty {
            let nextJobId = queuedJobIds.removeFirst()
            if let next = jobs[nextJobId], next.status == .queued {
                runJob(nextJobId, path: next.path)
                return
            }
        }
    }

    /// Whether a measurement walked the home folder's Trash: a folder is finished only after the folders inside
    /// it, so the Trash comes before the home folder.
    private final class Run {
        var homeTrashWalked = false
        var runAgain = false
    }

    private func noteWalked(_ run: Run, _ dirs: [FinishedFolders.Folder]) {
        for folder in dirs {
            let key = PathKey(folder.path)
            if key == homeTrashKey {
                run.homeTrashWalked = true
            }
            if key == homeKey {
                homeTrashCounted = run.homeTrashWalked
            }
        }
    }

    /// Every folder a measurement walks is on the disk it started on.
    private func storeMeasured(_ dev: Int64?, _ dirs: [FinishedFolders.Folder], measurement: Int) -> Int {
        for folder in dirs {
            cache.store(
                folder.path,
                FolderSizeStats(
                    sizeBytes: folder.totals.sizeBytes, diskBytes: folder.totals.diskBytes,
                    fileCount: folder.totals.fileCount, folderCount: folder.totals.folderCount, dev: dev,
                    measurement: measurement))
        }
        return dirs.count
    }

    private func runJob(_ jobId: String, path: String) {
        activeJobId = jobId
        measurementCount += 1
        let measurement = measurementCount
        // Kept when measured again, so the window never sees it go down.
        setJob(jobId, job(jobId, path, .running, measuredFolderCount: jobs[jobId]?.measuredFolderCount ?? 0))

        let run = Run()
        // The folders inside `path` are stored as each is finished, even once the measurement is cancelled or
        // fails (each was finished whole), but not once a write has made it outdated: they may have seen part
        // of the change, and it is run again.
        let onFinished: @MainActor (FinishedFolders) -> Void = { [self] measured in
            noteWalked(run, measured.dirs)
            if outdatedJobIds.contains(jobId) {
                return
            }
            let stored = storeMeasured(measured.dev, measured.dirs, measurement: measurement)
            if var current = jobs[jobId] {
                current.measuredFolderCount += stored
                setJob(jobId, current)
            }
        }
        let walk = native.getFolderSize(path, background: backgroundJobIds.contains(jobId), onFinished: onFinished)
        Task { @MainActor [self] in
            switch await walk.result {
            case .success(let result):
                measured(result, jobId: jobId, path: path, measurement: measurement, run: run)
            case .failure(let error):
                failed(error, jobId: jobId, path: path, run: run)
            }
            finally(jobId, path: path, run: run)
        }
    }

    private func measured(_ result: FolderSizeResult, jobId: String, path: String, measurement: Int, run: Run) {
        noteWalked(run, result.dirs)
        let key = PathKey(path)
        if key == homeTrashKey {
            homeTrashCounted = true
        } else if key == homeKey {
            homeTrashCounted = run.homeTrashWalked
        }
        if outdatedJobIds.remove(jobId) != nil {
            run.runAgain = true
            return
        }
        cache.store(
            path,
            FolderSizeStats(
                sizeBytes: result.total, diskBytes: result.diskTotal, fileCount: result.fileCount,
                folderCount: result.folderCount, dev: result.dev, measurement: measurement))
        let stored = storeMeasured(result.dev, result.dirs, measurement: measurement)
        var ready = job(jobId, path, .ready, measuredFolderCount: (jobs[jobId]?.measuredFolderCount ?? 0) + stored)
        ready.sizeBytes = result.total
        ready.diskBytes = result.diskTotal
        ready.fileCount = result.fileCount
        ready.folderCount = result.folderCount
        setJob(jobId, ready)
    }

    private func failed(_ error: any Error, jobId: String, path: String, run: Run) {
        // Stopped because a write outdated it (or failing after one did): run again.
        if outdatedJobIds.remove(jobId) != nil {
            run.runAgain = true
            return
        }
        let walkError = error as? FolderSizeError
        if PathKey(path) == homeTrashKey && (walkError?.code == "EPERM" || walkError?.code == "EACCES") {
            homeTrashCounted = false
        }
        let current = jobs[jobId]
        if current?.status == .cancelled {
            // Already marked as cancelled by the cancel handler
        } else {
            let message = walkError?.message ?? error.localizedDescription
            setJob(
                jobId, job(jobId, path, .error, measuredFolderCount: current?.measuredFolderCount ?? 0, error: message))
        }
    }

    private func finally(_ jobId: String, path: String, run: Run) {
        if activeJobId == jobId {
            activeJobId = nil
        }
        // Measured again under the same job, which the window is still waiting on: at once, or after the
        // measurements other windows asked for meanwhile. One this window asked for meanwhile has taken its
        // place (and cancelled it).
        let current = jobs[jobId]
        if stopped {
            forgetJob(jobId)
            return
        }
        if run.runAgain && current?.status == .running {
            if queuedJobIds.isEmpty {
                pruneFinishedJobs()
                runJob(jobId, path: path)
                return
            }
            if var queued = current {
                queued.status = .queued
                setJob(jobId, queued)
            }
            queuedJobIds.append(jobId)
        } else {
            forgetJob(jobId)
        }
        pruneFinishedJobs()
        processQueue()
    }

    // MARK: Requests

    /// `owner` is the window asking.
    @discardableResult
    public func start(_ request: FolderSizeStartRequest, owner: Int? = nil) -> FolderSizeStartResponse {
        if request.recalculate {
            cache.delete(request.path)
        }

        if let cached = cache.get(request.path) {
            let jobId = generateJobId()
            var ready = job(jobId, request.path, .ready)
            ready.sizeBytes = cached.sizeBytes
            ready.diskBytes = cached.diskBytes
            ready.fileCount = cached.fileCount
            ready.folderCount = cached.folderCount
            setJob(jobId, ready)
            pruneFinishedJobs()
            return FolderSizeStartResponse(jobId: jobId, status: .ready)
        }

        let jobId = generateJobId()

        if stopped {
            setFolderSizeJob(jobId, job(jobId, request.path, .cancelled))
            return FolderSizeStartResponse(jobId: jobId, status: .cancelled)
        }

        jobOwners[jobId] = .some(owner)
        if request.automatic {
            backgroundJobIds.insert(jobId)
        }

        if let activeJobId {
            cancelQueuedJobs(of: owner)
            if isOwned(activeJobId, by: owner) {
                // Cancel this window's active walk so the new one can start promptly. The native cancel sets a
                // flag its walkers check before each listing, so the walk stops quickly; the new job, queued
                // first, starts once the active job has ended.
                native.cancelFolderSize()
                if var activeJob = jobs[activeJobId] {
                    activeJob.status = .cancelled
                    setJob(activeJobId, activeJob)
                }
                queuedJobIds.insert(jobId, at: 0)
            } else {
                // Another window's walk goes on; this one waits its turn.
                queuedJobIds.append(jobId)
            }
            setJob(jobId, job(jobId, request.path, .queued))
            return FolderSizeStartResponse(jobId: jobId, status: .queued)
        }

        runJob(jobId, path: request.path)
        return FolderSizeStartResponse(jobId: jobId, status: .running)
    }

    /// The sizes known of `paths`, answered from what is stored: nothing is measured, and no job is made, so
    /// asking about every folder on screen costs one lookup each.
    public func probeMany(_ paths: [String]) -> [FolderSizeProbe] {
        paths.compactMap { path in
            guard let stats = cache.get(path) else { return nil }
            return FolderSizeProbe(
                path: path, sizeBytes: stats.sizeBytes, diskBytes: stats.diskBytes, fileCount: stats.fileCount,
                folderCount: stats.folderCount)
        }
    }

    public func getStatus(jobId: String) -> FolderSizeStatus {
        jobs[jobId]
            ?? FolderSizeJob(
                jobId: jobId, path: "", status: .error, sizeBytes: nil, diskBytes: nil, fileCount: nil,
                folderCount: nil, measuredFolderCount: 0, error: "Unknown folder size job.")
    }

    public func cancel(jobId: String) {
        guard var current = jobs[jobId] else { return }
        current.status = .cancelled
        setJob(jobId, current)
        if jobId == activeJobId {
            native.cancelFolderSize()
        }
        if queuedJobIds.contains(jobId) {
            queuedJobIds.removeAll { $0 == jobId }
            forgetJob(jobId)
        }
    }

    /// A window closed, or loading its page again: its measurements are stopped, those waiting and the one
    /// under way, and none is run again for it.
    public func forgetOwner(_ owner: Int) {
        cancelQueuedJobs(of: owner)
        if let activeJobId, var activeJob = jobs[activeJobId], activeJob.status == .running,
            isOwned(activeJobId, by: owner)
        {
            activeJob.status = .cancelled
            setJob(activeJobId, activeJob)
            native.cancelFolderSize()
        }
    }

    /// The app quits: the walk under way is stopped, and nothing waiting or measured again runs after it. A
    /// walk left running would keep the app's process alive with no window until it finished.
    public func stopAll() {
        stopped = true
        for queuedId in queuedJobIds {
            if var queued = jobs[queuedId] {
                queued.status = .cancelled
                setFolderSizeJob(queuedId, queued)
            }
            forgetJob(queuedId)
        }
        queuedJobIds = []
        if let activeJobId, var activeJob = jobs[activeJobId], activeJob.status == .running {
            activeJob.status = .cancelled
            setFolderSizeJob(activeJobId, activeJob)
        }
        if activeJobId != nil {
            native.cancelFolderSize()
        }
    }

    public func clearCache() {
        cache.clear()
    }

    public func cachedSize(_ path: String) -> Int64? {
        cache.get(path)?.sizeBytes
    }
}
