import FTFoundation
import Foundation

/// Previews wanted at once are loaded a few at a time, so one scrolled past before its turn can still be
/// dropped from the queue. Those asked for ahead of need (the next page of the Previews view) wait behind every
/// one wanted now, and move up among them once one is wanted after all. One scrolled past once it started is told to
/// stop (its task is cancelled), and its place goes to the next once it has; one that hasn't a while later is on a disk
/// that stopped answering, and its place goes to the next all the same.
@MainActor
public final class ThumbnailLoadQueue {
    public nonisolated static let maxConcurrentLoads = 4
    /// The Icons view's previews are small (64 to 256 pixels) and a screen at its smallest size shows hundreds: this
    /// many load at once, so a folder's previews arrive about a third sooner when Quick Look makes them anew. The
    /// Previews view's large pictures keep `maxConcurrentLoads`.
    public nonisolated static let iconLoads = 12

    private struct Job {
        let id: Int
        var isAhead: Bool
        let work: @MainActor () async -> Void
    }

    private let maxConcurrent: Int
    private var queued: [Job] = []
    private var active = 0
    private var nextID = 0
    /// The jobs started, by their numbers.
    private var running: [Int: Task<Void, Never>] = [:]

    public init(maxConcurrent: Int = ThumbnailLoadQueue.maxConcurrentLoads) {
        self.maxConcurrent = maxConcurrent
    }

    public var activeCount: Int { active }
    public var queuedCount: Int { queued.count }
    /// How many of those queued were asked for ahead of need.
    public var queuedAheadCount: Int { queued.count(where: \.isAhead) }

    /// Queues `work`; the handle takes it out of the queue again if it has not started yet, and tells it to stop if it
    /// has.
    @discardableResult
    public func enqueue(_ work: @escaping @MainActor () async -> Void) -> LoadHandle {
        let id = add(ahead: false, work)
        return LoadHandle { [weak self] in
            guard let self, !self.remove(id) else { return }
            self.stop(id)
        }
    }

    /// Queues `work`, after every job wanted now when `ahead` (it is asked for ahead of need), and gives the job's
    /// number for `remove` and `wantNow`.
    func add(ahead: Bool, _ work: @escaping @MainActor () async -> Void) -> Int {
        nextID += 1
        let job = Job(id: nextID, isAhead: ahead, work: work)
        if ahead {
            queued.append(job)
        } else {
            queued.insert(job, at: firstAhead)
        }
        startQueued()
        return job.id
    }

    /// Takes the job out of the queue if it has not started yet, and says whether it had not.
    @discardableResult
    func remove(_ id: Int) -> Bool {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return false }
        queued.remove(at: index)
        return true
    }

    /// Tells the job to stop if it started: its task is cancelled, and its place goes to the next once its work returns.
    /// Work that hasn't returned `abandonAfter` later is reading a file on a disk that stopped answering, which no
    /// cancelling ends: its place is given up then, so that a few such files don't keep every preview of every folder
    /// waiting until the disk gives up. No more than `maxAbandoned` are let go of this way, each still holding a
    /// thread.
    func stop(_ id: Int) {
        guard let task = running[id] else { return }
        task.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + abandonAfter) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running[id] != nil, !self.abandoned.contains(id),
                    self.abandoned.count < Self.maxAbandoned
                else { return }
                self.abandoned.insert(id)
                self.active -= 1
                self.startQueued()
            }
        }
    }

    /// How long a job told to stop has to return before its place is given up.
    var abandonAfter: TimeInterval = 2
    static let maxAbandoned = 16
    /// The jobs told to stop whose place was given up before their work returned.
    private var abandoned: Set<Int> = []
    /// How many of those there are, for a test.
    var abandonedCount: Int { abandoned.count }

    /// A job asked for ahead of need is wanted now: it goes after those wanted now, before the other ones ahead.
    func wantNow(_ id: Int) {
        guard let index = queued.firstIndex(where: { $0.id == id }), queued[index].isAhead else { return }
        var job = queued.remove(at: index)
        job.isAhead = false
        queued.insert(job, at: firstAhead)
    }

    private var firstAhead: Int {
        queued.firstIndex { $0.isAhead } ?? queued.count
    }

    public func removeAll() {
        queued.removeAll()
    }

    /// Those asked for ahead of need leave one load free for a preview wanted now, which then starts at once.
    private func startQueued() {
        while active < maxConcurrent, let next = queued.first,
            !next.isAhead || active < max(1, maxConcurrent - 1)
        {
            let job = queued.removeFirst()
            active += 1
            running[job.id] = Task { [weak self] in
                await job.work()
                guard let self else { return }
                self.running[job.id] = nil
                // Its place was given up already when it was let go of.
                if self.abandoned.remove(job.id) == nil { self.active -= 1 }
                self.startQueued()
                if self.active == 0, self.queued.isEmpty { StallLog.mark("previews", ["queue": self.maxConcurrent]) }
            }
        }
    }
}
