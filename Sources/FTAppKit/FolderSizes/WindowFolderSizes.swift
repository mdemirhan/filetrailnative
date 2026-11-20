import FTFileSystem
import FTFoundation
import Foundation

/// What a window asks of the folder size jobs: the jobs themselves, or a stand-in in tests.
@MainActor
protocol FolderSizeBackend: AnyObject {
    func probeMany(_ paths: [String]) -> [FolderSizeProbe]
    func start(_ request: FolderSizeStartRequest, owner: Int) -> FolderSizeStartResponse
    func getStatus(jobId: String) -> FolderSizeJob
    /// The window no longer wants the measurement: it stops unless another window asked for it too.
    func cancel(jobId: String, owner: Int)
}

extension FolderSizeJobs: FolderSizeBackend {
    /// A window always names itself.
    func start(_ request: FolderSizeStartRequest, owner: Int) -> FolderSizeStartResponse {
        start(request, owner: Optional(owner))
    }

    func cancel(jobId: String, owner: Int) {
        cancel(jobId: jobId, owner: Optional(owner))
    }
}

/// One window's view of the folder sizes: what it knows of each folder's size, asked of the jobs as the views draw
/// folders and kept current while a calculation runs. The cache is per window: other windows' walks do not repaint
/// this one.
@MainActor
final class WindowFolderSizes {
    /// A polled calculation is looked at this often.
    static let pollInterval = 0.2
    /// A folder not known is asked about again only after this cooldown, so redraws do not re-send the question.
    static let probeMissCooldown = 5.0
    /// Every folder drawn gets asked about, so the cache is capped; evicted paths are simply asked about again. What
    /// was stored or read since the last repaint is kept over the cap.
    static let maxEntries = 5_000
    /// The window repaints for new sizes at most this often.
    static let repaintInterval = 0.1
    /// While sizes are being stored (a walk, any window's), what the window shows is asked about again at most
    /// this often.
    static let storedInterval = 0.5

    /// "ask": a size the window doesn't know, or one that may have changed (kept on no answer). "refresh": one a
    /// write may have changed, forgotten when the jobs no longer know it.
    enum ProbeKind { case ask, refresh }

    private struct Slot {
        var entry: FolderSizeEntry
        /// What a ready size leaves out.
        var partial: FolderSizePartial = []
        var sequence: Int
        /// The repaint (`version`) at which it was last stored or read.
        var readAt: Int
    }

    private let backend: any FolderSizeBackend
    private let owner: Int
    private let scheduler: any TimerScheduling
    private let now: () -> TimeInterval
    private let homePath: String

    private var cache: [String: Slot] = [:]
    private var sequence = 0
    /// The repaint at which the cache was last trimmed: once a repaint is enough, since what is stored or read
    /// meanwhile stays until the next.
    private var trimmedAt = -1
    /// Changes whenever a cached entry does, for views that derive from the cache (sorting by size).
    private(set) var version = 0
    /// Who is told once per repaint, after the entries changed: each pane of the window, while it is there.
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let changed: @MainActor () -> Void
    }

    private var lastRepaint = -TimeInterval.infinity
    private var repaintTimer: TimerToken?
    private var storedTimer: TimerToken?
    private var pollTimers: [String: TimerToken] = [:]
    private var pollJobs: [String: String] = [:]
    private var polls: [String: Poll] = [:]
    private var lookNow: [String: () -> Void] = [:]
    private var settledEarly: [String] = []
    private var finishWaiters: [String: [(FolderSizeEntry) -> Void]] = [:]
    /// The runs of several folders under way, each with the folders it has yet to finish: a new one doesn't stop
    /// another.
    private var folderRuns: [Int: Set<String>] = [:]
    private var lastFolderRun = 0
    /// The folders of a run whose turn hasn't come, each with its run: they show as waiting, with no job yet.
    private var runWaiting: [String: Int] = [:]
    /// Each run under way of more than one folder, for the Activity list: how many folders it has, how many it has
    /// done with, and the one it is on.
    private var runStates: [Int: (total: Int, done: Int, current: String?)] = [:]
    /// How the last runs ended (true: every folder had its turn; false: stopped), for the Activity list's rows.
    private var runEnds: [Int: Bool] = [:]
    /// The measurement asked for of each folder (Calculate Size, by any route), by its job, while it runs or
    /// waits. One the app started by itself that was then asked for keeps its job, and is no longer the app's own
    /// to stop.
    private var askedJobs: [String: String] = [:]
    private var probeMissedAt: [String: (time: TimeInterval, sequence: Int)] = [:]
    private var probeSequence = 0
    private var probeQueue: [String: ProbeKind] = [:]
    private var probeQueueOrder: [String] = []
    private var probeFlushQueued = false

    init(
        backend: any FolderSizeBackend, owner: Int, homePath: String = DiskPath.home.string,
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

    /// Unmounting stops all polling timers and the pending repaint.
    func stopAll() {
        for timer in pollTimers.values { timer.cancel() }
        pollTimers.removeAll()
        pollJobs.removeAll()
        lookNow.removeAll()
        repaintTimer?.cancel()
        repaintTimer = nil
        storedTimer?.cancel()
        storedTimer = nil
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
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.changed() }
    }

    /// `changed` is told once per repaint for as long as `owner` is there. The window's panes share its sizes, so
    /// each one adds itself: a second pane, opened or closed, leaves the first one told.
    func observe(_ owner: AnyObject, _ changed: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
        observers.append(Observer(owner: owner, changed: changed))
    }

    // MARK: The cache

    /// Stores an entry without repainting; the caller repaints once for all it stored.
    private func setEntry(_ path: String, _ entry: FolderSizeEntry, partial: FolderSizePartial = []) {
        sequence += 1
        cache[path] = Slot(entry: entry, partial: partial, sequence: sequence, readAt: version)
        trimCache()
        if case .calculating = entry { return }
        let waiters = finishWaiters.removeValue(forKey: path) ?? []
        for resolve in waiters { resolve(entry) }
    }

    private func updateEntry(_ path: String, _ entry: FolderSizeEntry, partial: FolderSizePartial = []) {
        setEntry(path, entry, partial: partial)
        bumpVersion()
    }

    /// Over the limit, the oldest go but the calculations under way, a tenth at a time: one at a time, each entry
    /// stored would walk past the places of all those let go before it. What was stored or read since the last
    /// repaint stays, over the limit if need be: a size sort reads every folder listed, and letting some of them go
    /// would have them asked about and stored again, letting others go, at every repaint.
    private func trimCache() {
        guard cache.count > Self.maxEntries, trimmedAt != version else { return }
        trimmedAt = version
        var over = cache.count - Int((Double(Self.maxEntries) * 0.9).rounded(.up))
        let oldest = cache.sorted { $0.value.sequence < $1.value.sequence }
        for (path, slot) in oldest where over > 0 {
            if case .calculating = slot.entry { continue }
            if slot.readAt == version { continue }
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
    /// in one request), unless they were asked lately.
    func entry(_ path: String) -> FolderSizeEntry {
        if let slot = cache[path] {
            if slot.readAt != version { cache[path]?.readAt = version }
            return slot.entry
        }
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

    /// What a ready size leaves out, and why (empty: complete); nil without a ready size. Nothing shows it yet.
    func partial(_ path: String) -> FolderSizePartial? {
        guard let slot = cache[path], case .ready = slot.entry else { return nil }
        return slot.partial
    }

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

    /// Asks the questions queued in one go and stores the answers: a folder being calculated meanwhile is left to
    /// report its own size. One repaint for all.
    func flushProbes() {
        probeFlushQueued = false
        let queued = probeQueueOrder.map { ($0, probeQueue[$0] ?? .ask) }
        probeQueue.removeAll()
        probeQueueOrder.removeAll()
        var changed = false
        let known = Dictionary(
            backend.probeMany(queued.map(\.0)).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for (path, kind) in queued {
            let current = cache[path]?.entry
            if case .calculating? = current { continue }
            if let probe = known[path] {
                probeMissedAt[path] = nil
                let size = FolderSizeEntry.ready(
                    sizeBytes: probe.sizeBytes, diskBytes: probe.diskBytes, fileCount: probe.fileCount,
                    folderCount: probe.folderCount)
                if current != size || cache[path]?.partial != probe.partial {
                    setEntry(path, size, partial: probe.partial)
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
        if changed { bumpVersion() }
    }

    /// Sizes were stored, by any window's measurement: what this window shows without a size, or with one that may
    /// have changed, is asked about again (no walk: the answers are looked up), at most every `storedInterval`, so
    /// a folder another window measured shows here when its size arrives.
    func sizesStored() {
        guard storedTimer == nil else { return }
        storedTimer = scheduler.schedule(after: Self.storedInterval) { [weak self] in
            guard let self else { return }
            self.storedTimer = nil
            var shown = Array(self.probeMissedAt.keys)
            for (path, slot) in self.cache {
                if case .calculating = slot.entry { continue }
                shown.append(path)
            }
            self.queueProbes(shown, .ask)
        }
    }

    /// The folders inside `path` without a size, or all of them (`includeKnown`), asked about again at once: a walk
    /// of `path` measured some or all of them.
    private func askAgainInside(_ path: String, includeKnown: Bool, kind: ProbeKind = .ask) {
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
        queueProbes(inside, kind)
    }

    // MARK: Calculating

    /// A calculation being looked at, with the folders inside it measured so far, as last seen: more are asked about
    /// as they come.
    private final class Poll {
        var measuredFolderCount = 0
    }

    private func stopPolling(_ path: String) {
        askedJobs[path] = nil
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
        let result = backend.getStatus(jobId: jobId)
        switch result.status {
        case .ready where result.sizeBytes != nil:
            stopPolling(path)
            let size = result.sizeBytes ?? 0
            updateEntry(
                path,
                .ready(
                    sizeBytes: size, diskBytes: result.diskBytes ?? size, fileCount: result.fileCount ?? 0,
                    folderCount: result.folderCount ?? 0),
                partial: result.partial)
            // Known sizes inside are asked about too: they may have changed.
            askAgainInside(path, includeKnown: true)
        case .error:
            stopPolling(path)
            updateEntry(path, .error(message: result.error ?? "Unknown error"))
            // A folder moved away or replaced while it was measured has the sizes inside it forgotten by the jobs:
            // those shown here go with them.
            askAgainInside(path, includeKnown: true, kind: .refresh)
        case .cancelled:
            stopPolling(path)
            updateEntry(path, .idle)
            askAgainInside(path, includeKnown: false)
        default:
            // Waiting, or measured now: what it shows follows.
            let waiting = result.status == .queued
            if case .calculating(let jobID, let was)? = cache[path]?.entry, was != waiting {
                updateEntry(path, .calculating(jobID: jobID, waiting: waiting))
            }
            if result.measuredFolderCount > poll.measuredFolderCount {
                poll.measuredFolderCount = result.measuredFolderCount
                askAgainInside(path, includeKnown: false)
            }
        }
    }

    /// The jobs say a measurement has ended: it is looked at now, not at the next poll, so measuring many small
    /// folders one after another isn't held up between them.
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
    /// priority.
    func calculate(_ path: String, recalculate: Bool = false, automatic: Bool = false) {
        // Asked for before the app measured it by itself, it stays asked for: the jobs join the two.
        let asked = !automatic || askedJobs[path] != nil
        // Asked for by itself, it no longer waits for its turn in a run.
        leaveRun(path)
        // An earlier calculation of the folder gives way to this one.
        stopPolling(path)
        updateEntry(path, .calculating(jobID: ""))
        let response = backend.start(
            FolderSizeStartRequest(path: path, recalculate: recalculate, automatic: automatic), owner: owner)
        if response.status == .ready {
            let status = backend.getStatus(jobId: response.jobId)
            if status.status == .ready, let size = status.sizeBytes {
                updateEntry(
                    path,
                    .ready(
                        sizeBytes: size, diskBytes: status.diskBytes ?? size, fileCount: status.fileCount ?? 0,
                        folderCount: status.folderCount ?? 0),
                    partial: status.partial)
                askAgainInside(path, includeKnown: true)
                return
            }
        }
        updateEntry(path, .calculating(jobID: response.jobId, waiting: response.status == .queued))
        startPolling(path, response.jobId)
        if asked { askedJobs[path] = response.jobId }
    }

    /// Whether the measurement of `path` under way, running or waiting, was asked for, not only started by the app
    /// itself.
    func isAskedFor(_ path: String) -> Bool { askedJobs[path] != nil }

    func recalculate(_ path: String) {
        calculate(path, recalculate: true)
    }

    /// Several folders, one after another, as one request: each waits for the one before, and says so until its
    /// turn comes. Folders being calculated, or waiting to be, are left alone: their answer is as fresh as a new
    /// one's. With `recalculate` false, so are folders whose size is known. A
    /// folder stopped part way (Stop, or dropped from the jobs' queue) stops the run; another run doesn't, and
    /// Stop on a folder whose turn hasn't come takes only that one out.
    func calculate(_ paths: [String], recalculate: Bool = false) {
        lastFolderRun += 1
        let run = lastFolderRun
        var wanted: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            switch cache[path]?.entry {
            case .calculating: continue
            case .ready where !recalculate: continue
            default: break
            }
            wanted.append(path)
        }
        guard !wanted.isEmpty else { return }
        folderRuns[run] = Set(wanted)
        if wanted.count > 1 { runStates[run] = (wanted.count, 0, nil) }
        for path in wanted.dropFirst() {
            runWaiting[path] = run
            setEntry(path, .calculating(jobID: "", waiting: true))
        }
        bumpVersion()
        func next(_ index: Int) {
            var index = index
            while index < wanted.count {
                guard folderRuns[run] != nil else { return }
                let path = wanted[index]
                index += 1
                // Stopped, or asked for by itself, while it waited.
                guard index == 1 || runWaiting[path] == run else {
                    runStates[run]?.done += 1
                    continue
                }
                let resume = index
                finishWaiters[path, default: []].append { [weak self] entry in
                    guard let self else { return }
                    self.folderRuns[run]?.remove(path)
                    self.runStates[run]?.done += 1
                    self.runStates[run]?.current = nil
                    if case .idle = entry {
                        self.endRun(run, completed: false)
                        return
                    }
                    next(resume)
                }
                runWaiting[path] = nil
                runStates[run]?.current = path
                calculate(path, recalculate: recalculate)
                activityChanged()
                return
            }
            endRun(run, completed: true)
        }
        next(0)
        activityChanged()
    }

    /// The run is over or stopped: its folders still waiting show no size again.
    private func endRun(_ run: Int, completed: Bool) {
        guard folderRuns.removeValue(forKey: run) != nil else { return }
        if runStates.removeValue(forKey: run) != nil {
            runEnds[run] = completed
            // Only the last few are of use: a list open since they ended.
            for old in runEnds.keys.sorted().dropLast(32) { runEnds[old] = nil }
        }
        var changed = false
        for (path, waitingRun) in runWaiting where waitingRun == run {
            runWaiting[path] = nil
            if case .calculating(let jobID, _)? = cache[path]?.entry, jobID.isEmpty {
                setEntry(path, .idle)
                changed = true
            }
        }
        if changed { bumpVersion() }
        activityChanged()
    }

    /// `path` no longer waits for its turn in a run.
    private func leaveRun(_ path: String) {
        guard let run = runWaiting.removeValue(forKey: path) else { return }
        folderRuns[run]?.remove(path)
        activityChanged()
    }

    /// The runs of several folders under way, for the Activity list: each one's folders, how many it is done with,
    /// the job measuring the one it is on, and whether that one waits its turn behind another measurement.
    var activeRuns: [(run: Int, total: Int, done: Int, jobId: String?, waiting: Bool)] {
        runStates.sorted { $0.key < $1.key }.map { run, state in
            var jobId: String?
            var waiting = true
            if let current = state.current, case .calculating(let id, let isWaiting)? = cache[current]?.entry {
                jobId = id.isEmpty ? nil : id
                waiting = isWaiting
            }
            return (run, state.total, state.done, jobId, waiting)
        }
    }

    /// How the run `run` ended: true when every folder had its turn, false when it was stopped; nil while it runs or
    /// when that is no longer known.
    func runCompleted(_ run: Int) -> Bool? { runEnds[run] }

    /// Stops a run of several folders: the folder being measured for it and those still waiting.
    func cancelRun(_ run: Int) {
        guard let paths = folderRuns[run] else { return }
        cancel(Array(paths))
    }

    /// Told when the runs waiting changed; the Activity list follows.
    var onRunsChanged: () -> Void = {}

    private func activityChanged() { onRunsChanged() }

    /// Stop: polling stops, the jobs are told to cancel, the entry returns to idle and the sizes of folders inside
    /// that were already measured stay shown. A folder waiting its turn in a run leaves the run.
    func cancel(_ path: String) {
        leaveRun(path)
        if case .calculating(let jobID, _)? = cache[path]?.entry {
            stopPolling(path)
            if !jobID.isEmpty { backend.cancel(jobId: jobID, owner: owner) }
        }
        updateEntry(path, .idle)
        askAgainInside(path, includeKnown: false)
    }

    /// Stops the runs of several folders holding any of `paths`, and those of them being measured or waiting.
    func cancel(_ paths: [String]) {
        let stopping = Set(paths)
        for (run, runPaths) in folderRuns where !runPaths.isDisjoint(with: stopping) {
            endRun(run, completed: false)
        }
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
