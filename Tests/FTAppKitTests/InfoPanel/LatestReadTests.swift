import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// What every read of the Info panel and the Info Row does: waits, replaces what waits, drops what is late.
@MainActor
@Suite("latest read")
struct LatestReadTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func add(_ item: String) { lock.withLock { value.append(item) } }
        var items: [String] { lock.withLock { value } }
    }

    // Moving through items quickly reads only where it stops.
    @Test func askingAgainReplacesWhatWaits() async {
        let read = LatestRead<String, String>()
        let started = Count()
        var answers: [String] = []
        for key in ["a", "b", "c"] {
            read.ask(
                key, after: 0.05,
                read: { _ in
                    started.add(key)
                    return key
                }, answered: { answers.append($0) })
        }
        #expect(await waitUntil { answers == ["c"] })
        #expect(started.items == ["c"])
        #expect(!read.isAsking)
    }

    // A read already running when another is asked is told to stop, and its answer is never given.
    @Test func aLateAnswerIsDropped() async {
        let read = LatestRead<String, String>()
        let gate = DispatchSemaphore(value: 0)
        let seen = Count()
        var answers: [String] = []
        read.ask(
            "slow", after: 0,
            read: { cancel in
                gate.wait()
                seen.add(cancel.isCancelled ? "cancelled" : "running")
                return "slow"
            }, answered: { answers.append($0) })
        #expect(await waitUntil { !read.isWaiting })
        read.ask("fast", after: 0, read: { _ in "fast" }, answered: { answers.append($0) })
        #expect(await waitUntil { answers == ["fast"] })
        gate.signal()
        #expect(await waitUntil { seen.items == ["cancelled"] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answers == ["fast"])
    }

    @Test func stopMeansNothingComes() async {
        let read = LatestRead<String, String>()
        let started = Count()
        var answers: [String] = []
        read.ask(
            "a", after: 0.02,
            read: { _ in
                started.add("a")
                return "a"
            }, answered: { answers.append($0) })
        read.stop()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(answers.isEmpty && started.items.isEmpty && !read.isAsking)
    }
}
