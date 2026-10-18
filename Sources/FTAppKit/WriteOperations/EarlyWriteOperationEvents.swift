// Port of apps/desktop/src/renderer/lib/earlyWriteOperationEvents.ts
import FTOperations
import Foundation

/// The events of an operation this window may have started but doesn't know the id of yet: one that reports progress,
/// or even finishes, before its start request returns. They are kept only while a start request is waiting, since an
/// idle window hears every operation other windows run, and none of those is its own. Of each operation only its
/// newest progress and its end are kept: what the window shows once it knows the id.
@MainActor
final class EarlyWriteOperationEvents {
    /// Only the latest few operations can be the one a start request is waiting for.
    static let maxOperations = 4

    private struct Kept {
        var latest: WriteOperationEvent?
        var end: WriteOperationEvent?
    }

    // In the order the operations were first heard of.
    private var kept: [(operationId: String, events: Kept)] = []
    private var startsWaiting = 0

    /// `whileStarting`: sends a request that starts an operation, keeping events meanwhile. When it fails, nothing
    /// kept can be its operation's.
    func whileStarting<T>(_ start: () async throws -> T) async rethrows -> T {
        startsWaiting += 1
        do {
            let response = try await start()
            startsWaiting -= 1
            return response
        } catch {
            startsWaiting -= 1
            if startsWaiting == 0 { kept.removeAll() }
            throw error
        }
    }

    /// `note`: an event of an operation whose id this window doesn't know.
    func note(_ event: WriteOperationEvent) {
        guard startsWaiting > 0 else { return }
        var events = kept.first { $0.operationId == event.operationId }?.events ?? Kept()
        if event.status.isTerminal {
            events.end = event
        } else {
            events.latest = event
        }
        if let index = kept.firstIndex(where: { $0.operationId == event.operationId }) {
            kept[index].events = events
        } else {
            kept.append((event.operationId, events))
        }
        while kept.count > Self.maxOperations {
            kept.removeFirst()
        }
    }

    /// `take`: what was kept of the operation this window has just learned it started, in the order it happened;
    /// everything else kept was another window's.
    func take(_ operationId: String) -> [WriteOperationEvent] {
        let events = kept.first { $0.operationId == operationId }?.events
        kept.removeAll()
        return [events?.latest, events?.end].compactMap { $0 }
    }

    /// `forget`: an operation this window has heard of in another way (it took it over).
    func forget(_ operationId: String) {
        kept.removeAll { $0.operationId == operationId }
    }

    /// How many events are kept, for tests.
    var size: Int {
        kept.reduce(0) { $0 + ($1.events.latest == nil ? 0 : 1) + ($1.events.end == nil ? 0 : 1) }
    }
}
