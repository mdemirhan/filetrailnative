import Foundation

/// Previews wanted at once are loaded a few at a time, so one scrolled past before its turn can still be
/// dropped from the queue. Those asked for ahead of need (the next page of the Previews view) wait behind every
/// one wanted now, and move up among them once one is wanted after all.
@MainActor
public final class ThumbnailLoadQueue {
    public nonisolated static let maxConcurrentLoads = 4

    private struct Job {
        let id: Int
        var isAhead: Bool
        let work: @MainActor () async -> Void
    }

    private let maxConcurrent: Int
    private var queued: [Job] = []
    private var active = 0
    private var nextID = 0

    public init(maxConcurrent: Int = ThumbnailLoadQueue.maxConcurrentLoads) {
        self.maxConcurrent = maxConcurrent
    }

    public var activeCount: Int { active }
    public var queuedCount: Int { queued.count }
    /// How many of those queued were asked for ahead of need.
    public var queuedAheadCount: Int { queued.count(where: \.isAhead) }

    /// Queues `work`; the handle takes it out of the queue again if it has not started yet.
    @discardableResult
    public func enqueue(_ work: @escaping @MainActor () async -> Void) -> LoadHandle {
        let id = add(ahead: false, work)
        return LoadHandle { [weak self] in self?.remove(id) }
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
            Task { [weak self] in
                await job.work()
                self?.active -= 1
                self?.startQueued()
            }
        }
    }
}
