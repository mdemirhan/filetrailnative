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
    /// What the measured size leaves out, once it is ready.
    public var partial: FolderSizePartial

    public init(
        jobId: String, path: String, status: FolderSizeJobStatus, sizeBytes: Int64? = nil, diskBytes: Int64? = nil,
        fileCount: Int? = nil, folderCount: Int? = nil, measuredFolderCount: Int = 0, error: String? = nil,
        partial: FolderSizePartial = []
    ) {
        self.jobId = jobId
        self.path = path
        self.status = status
        self.sizeBytes = sizeBytes
        self.diskBytes = diskBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.measuredFolderCount = measuredFolderCount
        self.error = error
        self.partial = partial
    }
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

    public init(jobId: String, status: FolderSizeJobStatus) {
        self.jobId = jobId
        self.status = status
    }
}

/// The size known of one folder.
public struct FolderSizeProbe: Equatable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var diskBytes: Int64
    public var fileCount: Int
    public var folderCount: Int
    /// What the size leaves out.
    public var partial: FolderSizePartial

    public init(
        path: String, sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int,
        partial: FolderSizePartial = []
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.diskBytes = diskBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.partial = partial
    }
}

/// Each folder size job queue, told what a write changed, and when one starts and ends: a size stored while a
/// write runs may have been measured after it had already removed something, so taking the removal off it when
/// the write ends could count the removal twice.
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
    /// The most measurements asked for (not automatic) that wait, for the whole app: past it, the one waiting
    /// longest is dropped. The one running is never dropped.
    public static let maxAskedWaiting = 10

    private let native: any FolderSizeNative
    private let homePath: String
    private let homeTrashPath: String
    private let homeKey: PathKey
    private let homeTrashKey: PathKey
    // Told when a measurement ends (measured, failed or stopped), with the window that asked: it learns at
    // once, rather than at its next look.
    private let onSettled: ((Int?, String) -> Void)?
    // Told when sizes were stored, so every window can show those it is waiting for, not only the one that asked.
    private let onStored: (() -> Void)?

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
    // Measurements waiting for the one that runs, in the order they were asked for. The next to run is the first
    // asked for (not automatic), then the first of the window in front (`frontOwner`), then the first asked.
    private var queuedJobIds: [String] = []
    // The windows that asked for each job, in the order they asked: a window asking for a folder already being
    // measured or waiting joins its job. nil stands for a caller that names no window.
    private var jobOwners: [String: [Int?]] = [:]
    // The jobs the app started itself (automatic), which walk at a lower priority and give way: an automatic walk
    // of a window not in front is stopped for any measurement asked for and for the front window's automatic one.
    private var backgroundJobIds = Set<String>()
    // Automatic walks stopped to give way: back in the queue once the walk has ended.
    private var preemptedJobIds = Set<String>()
    // The size a folder had when it was asked to be measured again (Recalculate forgets it first): what the folders
    // holding it take the difference from once it is measured.
    private var previousSizes: [String: FolderSizeStats] = [:]
    /// Told when what is measured or waits changes (`activity`), as often as a walk moves on: the caller spaces out
    /// what it does with it.
    public var onActivityChanged: (() -> Void)?

    /// What is being measured and what waits, the one measured first, for the Activity list.
    public var activity: [FolderSizeActivity] {
        liveJobIds.compactMap { jobId in
            guard let job = jobs[jobId], !job.status.isFinished else { return nil }
            return FolderSizeActivity(
                jobId: jobId, path: job.path, isRunning: job.status == .running,
                isAutomatic: backgroundJobIds.contains(jobId), measuredFolderCount: job.measuredFolderCount)
        }
    }

    /// The window in front (the key window's front tab): its measurements go first among their kind, and its
    /// automatic walk is never stopped to give way.
    public var frontOwner: Int? {
        didSet { if frontOwner != oldValue { preemptForQueued() } }
    }
    // Set when the app quits: nothing more is measured.
    private var stopped = false
    // Makes each job's id. Random ids (the time in milliseconds and 24 random bits) can repeat
    // among the hundreds of jobs a test starts in one millisecond, so such tests count on ids of their own.
    var makeJobId: () -> String = FolderSizeJobs.randomJobId

    /// `homePath`: where the home folder is (tests use their own): its Trash is where deleted items go.
    public init(
        native: any FolderSizeNative, homePath: String = NSHomeDirectory(),
        onSettled: ((Int?, String) -> Void)? = nil, onStored: (() -> Void)? = nil
    ) {
        self.native = native
        self.homePath = homePath
        homeTrashPath = NodePath.join(homePath, ".Trash")
        homeKey = PathKey(homePath)
        homeTrashKey = PathKey(homeTrashPath)
        self.onSettled = onSettled
        self.onStored = onStored
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

    /// How many jobs are kept.
    public var jobCount: Int { jobs.count }

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
            for owner in jobOwners[jobId] ?? [nil] {
                onSettled?(owner, jobId)
            }
        }
        onActivityChanged?()
    }

    private func pruneFinishedJobs() {
        var finishedCount = jobs.values.reduce(0) { $0 + ($1.status.isFinished ? 1 : 0) }
        // The oldest finished go first; usually one is over.
        while finishedCount > Self.maxFinishedJobs {
            var oldest: (jobId: String, sequence: Int)?
            for (jobId, job) in jobs where job.status.isFinished {
                let sequence = jobOrder[jobId] ?? 0
                if oldest == nil || sequence < (oldest?.sequence ?? 0) {
                    oldest = (jobId, sequence)
                }
            }
            guard let oldest else { return }
            jobs[oldest.jobId] = nil
            jobOrder[oldest.jobId] = nil
            finishedCount -= 1
        }
    }

    private func forgetJob(_ jobId: String) {
        previousSizes[jobId] = nil
        jobOwners[jobId] = nil
        backgroundJobIds.remove(jobId)
        preemptedJobIds.remove(jobId)
    }

    /// The jobs waiting or running, the one running first.
    private var liveJobIds: [String] { (activeJobId.map { [$0] } ?? []) + queuedJobIds }

    /// Whether `jobId` is one the window in front asked for.
    private func isFront(_ jobId: String) -> Bool {
        guard let frontOwner else { return false }
        return jobOwners[jobId]?.contains(frontOwner) == true
    }

    /// Takes a waiting job off the queue as stopped, telling every window that asked.
    private func dropQueued(_ jobId: String) {
        queuedJobIds.removeAll { $0 == jobId }
        if var queued = jobs[jobId] {
            queued.status = .cancelled
            setJob(jobId, queued)
        }
        forgetJob(jobId)
    }

    /// Stops the running walk to give way: its job waits again once the walk has ended.
    private func preemptActive() {
        guard let activeJobId, var active = jobs[activeJobId], active.status == .running else { return }
        preemptedJobIds.insert(activeJobId)
        active.status = .queued
        setJob(activeJobId, active)
        native.cancelFolderSize()
    }

    /// An automatic walk of a window not in front gives way to a measurement asked for, and to the front window's
    /// automatic one, waiting.
    private func preemptForQueued() {
        guard let activeJobId, backgroundJobIds.contains(activeJobId), !isFront(activeJobId),
            !preemptedJobIds.contains(activeJobId)
        else { return }
        let waitingFor = queuedJobIds.contains { queued in
            jobs[queued]?.status == .queued && (!backgroundJobIds.contains(queued) || isFront(queued))
        }
        if waitingFor { preemptActive() }
    }

    /// Past `maxAskedWaiting` measurements asked for waiting, the one waiting longest is dropped.
    private func dropAskedOverLimit() {
        var asked = queuedJobIds.filter { !backgroundJobIds.contains($0) && !preemptedJobIds.contains($0) }
        while asked.count > Self.maxAskedWaiting {
            dropQueued(asked.removeFirst())
        }
    }

    nonisolated static func randomJobId() -> String {
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
        queuedJobIds.removeAll { jobs[$0]?.status != .queued }
        // Asked for before automatic; of each, the front window's first; then in the order asked.
        var next: (index: Int, rank: (Int, Int, Int))?
        for (index, jobId) in queuedJobIds.enumerated() {
            let rank = (backgroundJobIds.contains(jobId) ? 1 : 0, isFront(jobId) ? 0 : 1, index)
            if next == nil || rank < (next?.rank ?? rank) { next = (index, rank) }
        }
        guard let next else { return }
        let jobId = queuedJobIds.remove(at: next.index)
        guard let job = jobs[jobId] else { return }
        runJob(jobId, path: job.path)
    }

    /// The sizes a walk just stored answer the measurements waiting for them (a folder inside the one walked): they
    /// end now, with no walk of their own.
    private func answerWaiting(from dirs: [FinishedFolders.Folder]) {
        guard !queuedJobIds.isEmpty, !dirs.isEmpty else { return }
        let waiting = queuedJobIds.filter { jobs[$0]?.status == .queued && !preemptedJobIds.contains($0) }
        guard !waiting.isEmpty else { return }
        let stored = Set(dirs.map { PathKey($0.path) })
        for jobId in waiting {
            guard let path = jobs[jobId]?.path, stored.contains(PathKey(path)), let stats = cache.get(path) else {
                continue
            }
            queuedJobIds.removeAll { $0 == jobId }
            var ready = job(jobId, path, .ready)
            ready.sizeBytes = stats.sizeBytes
            ready.diskBytes = stats.diskBytes
            ready.fileCount = stats.fileCount
            ready.folderCount = stats.folderCount
            ready.partial = stats.partial
            setJob(jobId, ready)
            forgetJob(jobId)
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
                    measurement: measurement, partial: folder.totals.partial))
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
            answerWaiting(from: measured.dirs)
            onStored?()
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
        let measuredStats = FolderSizeStats(
            sizeBytes: result.total, diskBytes: result.diskTotal, fileCount: result.fileCount,
            folderCount: result.folderCount, dev: result.dev, measurement: measurement, partial: result.partial)
        let old = previousSizes.removeValue(forKey: jobId) ?? cache.get(path)
        // The folders holding it take the difference, or are forgotten, before its new size is stored.
        FolderSizeAdjust.adjustForRemeasure(cache, path, old: old, new: measuredStats)
        cache.store(path, measuredStats)
        let stored = storeMeasured(result.dev, result.dirs, measurement: measurement)
        answerWaiting(from: result.dirs)
        defer { onStored?() }
        var ready = job(jobId, path, .ready, measuredFolderCount: (jobs[jobId]?.measuredFolderCount ?? 0) + stored)
        ready.sizeBytes = result.total
        ready.diskBytes = result.diskTotal
        ready.fileCount = result.fileCount
        ready.folderCount = result.folderCount
        ready.partial = result.partial
        setJob(jobId, ready)
    }

    private func failed(_ error: any Error, jobId: String, path: String, run: Run) {
        // Stopped because a write outdated it (or failing after one did): run again.
        if outdatedJobIds.remove(jobId) != nil {
            run.runAgain = true
            return
        }
        let walkError = error as? FolderSizeError
        if PathKey(path) == homeTrashKey && (walkError?.errnum == EPERM || walkError?.errnum == EACCES) {
            homeTrashCounted = false
        }
        if walkError?.rootChanged == true {
            // Another folder is at the path now, or none: the sizes stored of the folders inside, by this walk as
            // it went or by an earlier one, are not theirs.
            cache.forgetAtOrInside([path])
            onStored?()
        }
        let current = jobs[jobId]
        if current?.status == .cancelled || preemptedJobIds.contains(jobId) {
            // Already marked as cancelled by the cancel handler, or waiting again after giving way.
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
        if preemptedJobIds.remove(jobId) != nil && current?.status == .queued {
            // Gave way: it waits again, in its place.
            queuedJobIds.append(jobId)
        } else if run.runAgain && current?.status == .running {
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

    /// `owner` is the window asking. A folder already being measured or waiting is joined, whoever asked; a
    /// measurement asked for never stops another (it waits), and an automatic one replaces the window's other
    /// automatic one.
    @discardableResult
    public func start(_ request: FolderSizeStartRequest, owner: Int? = nil) -> FolderSizeStartResponse {
        if !stopped, let joined = join(request, owner: owner) {
            return joined
        }
        let previous = cache.get(request.path)
        if request.recalculate {
            cache.delete(request.path)
        }

        if let cached = cache.get(request.path) {
            let jobId = makeJobId()
            var ready = job(jobId, request.path, .ready)
            ready.sizeBytes = cached.sizeBytes
            ready.diskBytes = cached.diskBytes
            ready.fileCount = cached.fileCount
            ready.folderCount = cached.folderCount
            ready.partial = cached.partial
            setJob(jobId, ready)
            pruneFinishedJobs()
            return FolderSizeStartResponse(jobId: jobId, status: .ready)
        }

        let jobId = makeJobId()

        if stopped {
            setFolderSizeJob(jobId, job(jobId, request.path, .cancelled))
            return FolderSizeStartResponse(jobId: jobId, status: .cancelled)
        }

        if request.automatic, let owner {
            leaveAutomatic(of: owner)
        }
        jobOwners[jobId] = [owner]
        previousSizes[jobId] = previous
        if request.automatic {
            backgroundJobIds.insert(jobId)
        }

        if activeJobId != nil {
            queuedJobIds.append(jobId)
            setJob(jobId, job(jobId, request.path, .queued))
            dropAskedOverLimit()
            preemptForQueued()
            return FolderSizeStartResponse(jobId: jobId, status: jobs[jobId]?.status ?? .cancelled)
        }

        runJob(jobId, path: request.path)
        return FolderSizeStartResponse(jobId: jobId, status: .running)
    }

    /// Joins the job measuring or waiting to measure the same folder, if there is one: the window is told when it
    /// ends, and a measurement asked for makes an automatic job one asked for (it no longer gives way; a walk
    /// running keeps its priority).
    private func join(_ request: FolderSizeStartRequest, owner: Int?) -> FolderSizeStartResponse? {
        let key = PathKey(request.path)
        guard
            let jobId = liveJobIds.first(where: { liveId in
                guard let live = jobs[liveId], !live.status.isFinished else { return false }
                return PathKey(live.path) == key
            }), let live = jobs[jobId]
        else { return nil }
        if request.automatic, let owner, !(jobOwners[jobId]?.contains(owner) ?? false) {
            leaveAutomatic(of: owner)
        }
        if !(jobOwners[jobId]?.contains(owner) ?? false) {
            jobOwners[jobId, default: []].append(owner)
        }
        if !request.automatic && backgroundJobIds.remove(jobId) != nil {
            if preemptedJobIds.contains(jobId) {
                // It gave way while automatic; asked for now, it is no longer put aside.
                dropAskedOverLimit()
            } else if queuedJobIds.contains(jobId) {
                dropAskedOverLimit()
            }
        }
        preemptForQueued()
        onActivityChanged?()
        return FolderSizeStartResponse(jobId: jobId, status: jobs[jobId]?.status ?? live.status)
    }

    /// A window has one automatic measurement at a time: its other one goes, stopped if it runs, unless another
    /// window asked for it too, which keeps it.
    private func leaveAutomatic(of owner: Int) {
        for jobId in liveJobIds where backgroundJobIds.contains(jobId) && jobOwners[jobId]?.contains(owner) == true {
            cancel(jobId: jobId, owner: owner)
        }
    }

    /// The sizes known of `paths`, answered from what is stored: nothing is measured, and no job is made, so
    /// asking about every folder on screen costs one lookup each.
    public func probeMany(_ paths: [String]) -> [FolderSizeProbe] {
        paths.compactMap { path in
            guard let stats = cache.get(path) else { return nil }
            return FolderSizeProbe(
                path: path, sizeBytes: stats.sizeBytes, diskBytes: stats.diskBytes, fileCount: stats.fileCount,
                folderCount: stats.folderCount, partial: stats.partial)
        }
    }

    public func getStatus(jobId: String) -> FolderSizeJob {
        jobs[jobId]
            ?? FolderSizeJob(
                jobId: jobId, path: "", status: .error, sizeBytes: nil, diskBytes: nil, fileCount: nil,
                folderCount: nil, measuredFolderCount: 0, error: "Unknown folder size job.")
    }

    public func cancel(jobId: String) {
        cancel(jobId: jobId, owner: nil, forEveryone: true)
    }

    /// `owner` no longer wants the measurement: it stops when no other window asked for it, and goes on for those
    /// that did.
    public func cancel(jobId: String, owner: Int?) {
        cancel(jobId: jobId, owner: owner, forEveryone: false)
    }

    private func cancel(jobId: String, owner: Int?, forEveryone: Bool) {
        // One that has ended keeps its answer.
        guard var current = jobs[jobId], !current.status.isFinished else { return }
        if !forEveryone, var owners = jobOwners[jobId], let index = owners.firstIndex(of: owner), owners.count > 1 {
            owners.remove(at: index)
            jobOwners[jobId] = owners
            return
        }
        let wasPreempted = preemptedJobIds.remove(jobId) != nil
        current.status = .cancelled
        setJob(jobId, current)
        if jobId == activeJobId && !wasPreempted {
            native.cancelFolderSize()
        }
        if queuedJobIds.contains(jobId) {
            queuedJobIds.removeAll { $0 == jobId }
            forgetJob(jobId)
        }
    }

    /// A window closed, or loading its page again: its measurements are stopped, those waiting and the one
    /// under way, unless another window asked for them too, and none is run again for it.
    public func forgetOwner(_ owner: Int) {
        for jobId in liveJobIds where jobOwners[jobId]?.contains(owner) == true {
            cancel(jobId: jobId, owner: owner)
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

    public func cachedSize(_ path: String) -> Int64? {
        cache.get(path)?.sizeBytes
    }
}
