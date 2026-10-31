// A bound on how many tests of a group run at once, with room for the tests that must run alone
import Foundation

/// Up to `width` tests of a group at a time; a test that takes the whole group runs with no other test of it. Tests
/// get their turn in the order they asked, so one that runs alone isn't kept waiting by the others.
public actor TestSlots {
    public nonisolated let width: Int
    private var running = 0
    private var alone = false
    private var waiting: [(alone: Bool, resume: CheckedContinuation<Void, Never>)] = []

    public init(width: Int) {
        self.width = max(1, width)
    }

    /// Runs `body` in a slot of the group, or with the whole group when `alone`.
    public func run(alone: Bool, _ body: @Sendable () async throws -> Void) async rethrows {
        await take(alone: alone)
        do {
            try await body()
        } catch {
            give(alone: alone)
            throw error
        }
        give(alone: alone)
    }

    private func take(alone wantsAlone: Bool) async {
        if waiting.isEmpty && fits(alone: wantsAlone) {
            start(alone: wantsAlone)
            return
        }
        await withCheckedContinuation { waiting.append((wantsAlone, $0)) }
    }

    private func give(alone wasAlone: Bool) {
        running -= 1
        if wasAlone { alone = false }
        while let next = waiting.first, fits(alone: next.alone) {
            waiting.removeFirst()
            start(alone: next.alone)
            next.resume.resume()
        }
    }

    private func fits(alone wantsAlone: Bool) -> Bool {
        wantsAlone ? running == 0 : !alone && running < width
    }

    private func start(alone wantsAlone: Bool) {
        running += 1
        if wantsAlone { alone = true }
    }
}
