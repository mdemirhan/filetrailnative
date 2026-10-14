// Port of apps/desktop/src/renderer/hooks/useFolderSizeCache.ts
import FTFileSystem
import FTFoundation
import Foundation

/// A size the jobs know of a folder.
struct SizeProbe: Equatable {
    var path: String
    var sizeBytes: Int64
    var diskBytes: Int64
    var fileCount: Int
    var folderCount: Int
}

/// How a measurement stands.
struct JobState: Equatable {
    var status: FolderSizeJobStatus
    var sizeBytes: Int64?
    var diskBytes: Int64?
    var fileCount: Int?
    var folderCount: Int?
    var measuredFolderCount = 0
    var error: String?
}

struct JobStart: Equatable {
    var jobId: String
    var status: FolderSizeJobStatus
}

/// What a window asks of the folder size jobs (the original's `folderSize:*` channels).
@MainActor
protocol FolderSizeBackend: AnyObject {
    func probeMany(_ paths: [String]) -> [SizeProbe]
    func start(_ request: FolderSizeStartRequest, owner: Int) -> JobStart
    func state(jobId: String) -> JobState
    func cancel(jobId: String)
}

extension FolderSizeJobs: FolderSizeBackend {
    func probeMany(_ paths: [String]) -> [SizeProbe] {
        let probes: [FolderSizeProbe] = probeMany(paths)
        return probes.map {
            SizeProbe(
                path: $0.path, sizeBytes: $0.sizeBytes, diskBytes: $0.diskBytes, fileCount: $0.fileCount,
                folderCount: $0.folderCount)
        }
    }

    func start(_ request: FolderSizeStartRequest, owner: Int) -> JobStart {
        let response: FolderSizeStartResponse = start(request, owner: Optional(owner))
        return JobStart(jobId: response.jobId, status: response.status)
    }

    func state(jobId: String) -> JobState {
        let job = getStatus(jobId: jobId)
        return JobState(
            status: job.status, sizeBytes: job.sizeBytes, diskBytes: job.diskBytes, fileCount: job.fileCount,
            folderCount: job.folderCount, measuredFolderCount: job.measuredFolderCount, error: job.error)
    }
}

/// One window's view of the folder sizes: what it knows of each folder's size, asked of the jobs as the views draw
/// folders and kept current while a calculation runs. The cache is per window: other windows' walks do not repaint
/// this one (B-INFO-143).
@MainActor
final class WindowFolderSizes {
    /// A polled calculation is looked at this often.
    static let pollInterval = 0.2
    /// A folder not known is asked about again only after this cooldown, so redraws do not re-send the question.
    static let probeMissCooldown = 5.0
    /// Every folder drawn gets asked about, so the cache is capped; evicted paths are simply asked about again.
    static let maxEntries = 5_000
    static let maxProbesPerRequest = 5_000
    /// The window repaints for new sizes at most this often.
    static let repaintInterval = 0.1

    /// "ask": a size the window doesn't know, or one that may have changed (kept on no answer). "refresh": one a
    /// write may have changed, forgotten when the jobs no longer know it.
    enum ProbeKind { case ask, refresh }

    private struct Slot {
        var entry: FolderSizeEntry
        var sequence: Int
    }

    private let backend: any FolderSizeBackend
    private let owner: Int
    private let scheduler: any TimerScheduling
    private let now: () -> TimeInterval
    private let homePath: String

    private var cache: [String: Slot] = [:]
    private var sequence = 0
    /// Changes whenever a cached entry does, for views that derive from the cache (sorting by size).
    private(set) var version = 0
    /// Told once per repaint, after the entries changed.
    var onChange: (@MainActor () -> Void)?

    private var lastRepaint = -TimeInterval.infinity
    private var repaintTimer: TimerToken?
    private var pollTimers: [String: TimerToken] = [:]
    private var pollJobs: [String: String] = [:]
    private var polls: [String: Poll] = [:]
    private var lookNow: [String: () -> Void] = [:]
    private var settledEarly: [String] = []
    private var finishWaiters: [String: [(FolderSizeEntry) -> Void]] = [:]
    private var folderRun = 0
    private var probeMissedAt: [String: (time: TimeInterval, sequence: Int)] = [:]
    private var probeSequence = 0
    private var probeQueue: [String: ProbeKind] = [:]
    private var probeQueueOrder: [String] = []
    private var probeFlushQueued = false

    init(
        backend: any FolderSizeBackend, owner: Int, homePath: String = NSHomeDirectory(),
        scheduler: any TimerScheduling = TaskTimerScheduler(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.backend = backend
        self.owner = owner
        self.homePath = homePath
        self.scheduler = scheduler
        self.now = now
    }

    isolated deinit {
        stopAll()
    }

    /// Unmounting stops all polling timers and the pending repaint (B-INFO-144).
    func stopAll() {
        for timer in pollTimers.values { timer.cancel() }
        pollTimers.removeAll()
        pollJobs.removeAll()
        lookNow.removeAll()
        repaintTimer?.cancel()
        repaintTimer = nil
    }

    // MARK: Repainting

    /// A repaint asked for within the interval after the last one waits for its end, and stands for all asked for
    /// meanwhile.
    private func bumpVersion() {
        guard repaintTimer == nil else { return }
        let wait = lastRepaint + Self.repaintInterval - now()
        if wait <= 0 {
            repaint()
        } else {
            repaintTimer = scheduler.schedule(after: wait) { [weak self] in self?.repaint() }
        }
    }

    private func repaint() {
        repaintTimer = nil
        lastRepaint = now()
        version += 1
        onChange?()
    }

    // MARK: The cache

    /// Stores an entry without repainting; the caller repaints once for all it stored.
    private func setEntry(_ path: String, _ entry: FolderSizeEntry) {
        sequence += 1
        cache[path] = Slot(entry: entry, sequence: sequence)
        trimCache()
        if case .calculating = entry { return }
        let waiters = finishWaiters.removeValue(forKey: path) ?? []
        for resolve in waiters { resolve(entry) }
    }

    private func updateEntry(_ path: String, _ entry: FolderSizeEntry) {
        setEntry(path, entry)
        bumpVersion()
    }

    /// Over the limit, the oldest go but the calculations under way, a tenth at a time: one at a time, each entry
    /// stored would walk past the places of all those let go before it (B-INFO-142).
    private func trimCache() {
        guard cache.count > Self.maxEntries else { return }
        var over = cache.count - Int((Double(Self.maxEntries) * 0.9).rounded(.up))
        let oldest = cache.sorted { $0.value.sequence < $1.value.sequence }
        for (path, slot) in oldest where over > 0 {
            if case .calculating = slot.entry { continue }
            cache[path] = nil
            over -= 1
        }
    }

    private func noteProbeMiss(_ path: String) {
        probeSequence += 1
        probeMissedAt[path] = (now(), probeSequence)
        if probeMissedAt.count > Self.maxEntries {
            let over = probeMissedAt.count - Int((Double(Self.maxEntries) * 0.9).rounded(.up))
            for (key, _) in probeMissedAt.sorted(by: { $0.value.sequence < $1.value.sequence }).prefix(over) {
                probeMissedAt[key] = nil
            }
        }
    }

    // MARK: Probes

    /// A folder's size, or idle when it isn't known: then the jobs are asked (all the folders a redraw asks about,
    /// in one request), unless they were asked lately (B-INFO-131, B-INFO-132).
    func entry(_ path: String) -> FolderSizeEntry {
        if let slot = cache[path] { return slot.entry }
        if let missed = probeMissedAt[path], now() - missed.time < Self.probeMissCooldown {
            return .idle
        }
        // Marked at once, so the rest of the redraw doesn't ask again.
        noteProbeMiss(path)
        queueProbes([path], .ask)
        return .idle
    }

    /// The size of a folder once it is calculated.
    func readySize(_ path: String) -> Int64? {
        if case .ready(let size, _, _, _) = entry(path) { return size }
        return nil
    }

    /// What the cache holds, without asking anything.
    func cachedEntry(_ path: String) -> FolderSizeEntry? { cache[path]?.entry }

    var isCalculating: Bool {
        cache.values.contains { if case .calculating = $0.entry { true } else { false } }
    }

    private func queueProbes(_ paths: some Sequence<String>, _ kind: ProbeKind) {
        for path in paths {
            // A refresh is the stronger question: a size it can't confirm is forgotten.
            if probeQueue[path] == .refresh { continue }
            if probeQueue[path] == nil { probeQueueOrder.append(path) }
            probeQueue[path] = kind
        }
        if !probeQueue.isEmpty, !probeFlushQueued {
            probeFlushQueued = true
            Task { @MainActor [weak self] in self?.flushProbes() }
        }
    }

    /// Sends the questions queued, as few requests as fit, and stores the answers: a folder being calculated
    /// meanwhile is left to report its own size. One repaint for all (B-INFO-133).
    func flushProbes() {
        probeFlushQueued = false
        let queued = probeQueueOrder.map { ($0, probeQueue[$0] ?? .ask) }
        probeQueue.removeAll()
        probeQueueOrder.removeAll()
        var changed = false
        var start = 0
        while start < queued.count {
            let batch = Array(queued[start..<min(queued.count, start + Self.maxProbesPerRequest)])
            start += Self.maxProbesPerRequest
            let known = Dictionary(
                backend.probeMany(batch.map(\.0)).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for (path, kind) in batch {
                let current = cache[path]?.entry
                if case .calculating? = current { continue }
                if let probe = known[path] {
                    probeMissedAt[path] = nil
                    let size = FolderSizeEntry.ready(
                        sizeBytes: probe.sizeBytes, diskBytes: probe.diskBytes, fileCount: probe.fileCount,
                        folderCount: probe.folderCount)
                    if current != size {
                        setEntry(path, size)
                        changed = true
                    }
                } else if kind == .refresh {
                    probeMissedAt[path] = nil
                    if current != nil {
                        cache[path] = nil
                        changed = true
                    }
                } else if current == nil {
                    noteProbeMiss(path)
                }
            }
        }
        if changed { bumpVersion() }
    }

    /// The folders inside `path` without a size, or all of them (`includeKnown`), asked about again at once: a walk
    /// of `path` measured some or all of them (B-INFO-140).
    private func askAgainInside(_ path: String, includeKnown: Bool) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var inside: [String] = []
        for missed in probeMissedAt.keys where missed.hasPrefix(prefix) { inside.append(missed) }
        for (cached, slot) in cache where cached.hasPrefix(prefix) {
            if case .calculating = slot.entry { continue }
            // A folder whose own calculation was stopped or failed shows no size either.
            var wanted = includeKnown
            switch slot.entry {
            case .idle, .error: wanted = true
            default: break
            }
            if wanted { inside.append(cached) }
        }
        queueProbes(inside, .ask)
    }

    // MARK: Calculating

    /// A calculation being looked at, with the folders inside it measured so far, as last seen: more are asked about
    /// as they come.
    private final class Poll {
        var measuredFolderCount = 0
    }

    private func stopPolling(_ path: String) {
        pollTimers.removeValue(forKey: path)?.cancel()
        polls[path] = nil
        if let jobId = pollJobs.removeValue(forKey: path) { lookNow[jobId] = nil }
    }

    private func startPolling(_ path: String, _ jobId: String) {
        stopPolling(path)
        let poll = Poll()
        polls[path] = poll
        pollJobs[path] = jobId
        lookNow[jobId] = { [weak self] in self?.look(path, jobId, poll) }
        arm(path, jobId, poll)
        if let index = settledEarly.firstIndex(of: jobId) {
            settledEarly.remove(at: index)
            look(path, jobId, poll)
        }
    }

    private func arm(_ path: String, _ jobId: String, _ poll: Poll) {
        pollTimers[path] = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            guard let self, self.polls[path] === poll else { return }
            self.look(path, jobId, poll)
            if self.polls[path] === poll { self.arm(path, jobId, poll) }
        }
    }

    private func look(_ path: String, _ jobId: String, _ poll: Poll) {
        // Another calculation of this folder took over meanwhile.
        guard polls[path] === poll else { return }
        let result = backend.state(jobId: jobId)
        switch result.status {
        case .ready where result.sizeBytes != nil:
            stopPolling(path)
            let size = result.sizeBytes ?? 0
            updateEntry(
                path,
                .ready(
                    sizeBytes: size, diskBytes: result.diskBytes ?? size, fileCount: result.fileCount ?? 0,
                    folderCount: result.folderCount ?? 0))
            // Known sizes inside are asked about too: they may have changed.
            askAgainInside(path, includeKnown: true)
        case .error:
            stopPolling(path)
            updateEntry(path, .error(message: result.error ?? "Unknown error"))
            askAgainInside(path, includeKnown: false)
        case .cancelled:
            stopPolling(path)
            updateEntry(path, .idle)
            askAgainInside(path, includeKnown: false)
        default:
            if result.measuredFolderCount > poll.measuredFolderCount {
                poll.measuredFolderCount = result.measuredFolderCount
                askAgainInside(path, includeKnown: false)
            }
        }
    }

    /// The jobs say a measurement has ended: it is looked at now, not at the next poll, so measuring many small
    /// folders one after another isn't held up between them (B-INFO-145).
    func settled(jobId: String) {
        if let look = lookNow[jobId] {
            look()
            return
        }
        settledEarly.append(jobId)
        // Only the few that came just before their wait began are of use.
        if settledEarly.count > 64 { settledEarly.removeFirst(settledEarly.count - 64) }
    }

    /// `automatic` for a measurement the app starts by itself (the Info panel's), which the jobs run at a lower
    /// priority (B-INFO-134, B-INFO-135, B-INFO-136).
    func calculate(_ path: String, recalculate: Bool = false, automatic: Bool = false) {
        // An earlier calculation of the folder gives way to this one.
        stopPolling(path)
        updateEntry(path, .calculating(jobID: ""))
        let response = backend.start(
            FolderSizeStartRequest(path: path, recalculate: recalculate, automatic: automatic), owner: owner)
        if response.status == .ready {
            let status = backend.state(jobId: response.jobId)
            if status.status == .ready, let size = status.sizeBytes {
                updateEntry(
                    path,
                    .ready(
                        sizeBytes: size, diskBytes: status.diskBytes ?? size, fileCount: status.fileCount ?? 0,
                        folderCount: status.folderCount ?? 0))
                askAgainInside(path, includeKnown: true)
                return
            }
        }
        updateEntry(path, .calculating(jobID: response.jobId))
        startPolling(path, response.jobId)
    }

    func recalculate(_ path: String) {
        calculate(path, recalculate: true)
    }

    /// Several folders, one after another: the jobs measure one at a time, and a new calculation stops the one under
    /// way. With `recalculate` false, folders whose size is known or being calculated are left alone. A folder
    /// stopped part way stops the run.
    func calculate(_ paths: [String], recalculate: Bool = false) {
        folderRun += 1
        let run = folderRun
        func next(_ index: Int) {
            var index = index
            while index < paths.count {
                guard folderRun == run else { return }
                let path = paths[index]
                index += 1
                if !recalculate, let entry = cache[path]?.entry {
                    switch entry {
                    case .ready, .calculating: continue
                    default: break
                    }
                }
                let resume = index
                finishWaiters[path, default: []].append { [weak self] entry in
                    guard self != nil else { return }
                    if case .idle = entry { return }
                    next(resume)
                }
                calculate(path, recalculate: recalculate)
                return
            }
        }
        next(0)
    }

    /// Stop: polling stops, the jobs are told to cancel, the entry returns to idle and the sizes of folders inside
    /// that were already measured stay shown (B-INFO-137).
    func cancel(_ path: String) {
        if case .calculating(let jobID)? = cache[path]?.entry {
            stopPolling(path)
            if !jobID.isEmpty { backend.cancel(jobId: jobID) }
        }
        updateEntry(path, .idle)
        askAgainInside(path, includeKnown: false)
    }

    /// Stops a run of several folders, and the one of them being measured.
    func cancel(_ paths: [String]) {
        folderRun += 1
        for path in paths {
            if case .calculating? = cache[path]?.entry { cancel(path) }
        }
    }

    // MARK: Writes

    /// Changed items may have changed the sizes of the folders holding them. The jobs have taken what a delete
    /// removed off the sizes they could, and forgotten the rest: each is asked about again. A move to the Trash
    /// changes the Trash too.
    func forgetChangedSizes(_ changedPaths: [String], intoTrash: Bool) {
        let changes = ChangeMatcher(changedPaths: changedPaths)
        // Where the Trash is, the folders holding it may have changed; the Trash itself too.
        let trashPath = intoTrash ? homeTrashPath : nil
        let trash = trashPath.map { ChangeMatcher(changedPaths: [$0]) }
        var toRefresh: [String] = []
        var forgotten = false
        for (path, slot) in cache {
            if case .calculating = slot.entry { continue }
            if changes.holdsChange(path) || path == trashPath || trash?.holdsChange(path) == true {
                toRefresh.append(path)
            } else if changes.isAtOrInsideChange(path) {
                // What changed, and what is inside it: the jobs forgot these.
                cache[path] = nil
                forgotten = true
            }
        }
        for missed in Array(probeMissedAt.keys) where changes.isAffected(missed) {
            probeMissedAt[missed] = nil
        }
        queueProbes(toRefresh, .refresh)
        if forgotten { bumpVersion() }
    }

    private var homeTrashPath: String? {
        homePath.isEmpty
            ? nil : homePath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + "/.Trash"
    }
}
