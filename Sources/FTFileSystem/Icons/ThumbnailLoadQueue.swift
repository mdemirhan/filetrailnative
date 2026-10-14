// Port of queueThumbnailLoad and startQueuedLoads (apps/desktop/src/renderer/lib/fileThumbnails.tsx)
import Foundation

/// Previews wanted at once are loaded a few at a time, so one scrolled past before its turn can still be
/// dropped from the queue.
@MainActor
public final class ThumbnailLoadQueue {
    public nonisolated static let maxConcurrentLoads = 4

    private struct Job {
        let id: Int
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

    /// Queues `work`; the handle takes it out of the queue again if it has not started yet.
    @discardableResult
    public func enqueue(_ work: @escaping @MainActor () async -> Void) -> LoadHandle {
        nextID += 1
        let id = nextID
        queued.append(Job(id: id, work: work))
        startQueued()
        return LoadHandle { [weak self] in
            self?.queued.removeAll { $0.id == id }
        }
    }

    public func removeAll() {
        queued.removeAll()
    }

    private func startQueued() {
        while active < maxConcurrent, !queued.isEmpty {
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
