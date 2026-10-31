// How the windowless suites run side by side: a few tests at a time, each with a menu presenter of its own, and the
// ones that replace an app global alone
import AppKit
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct WindowlessSlotsTests {
        @Test func theWindowlessSuitesRunSideBySideInSlots() throws {
            let traits = try #require(Test.current).traits
            #expect(!traits.contains { $0 is ParallelizationTrait })
            #expect(traits.contains { ($0 as? WindowlessSlots)?.alone == false })
            #expect(WindowlessSlots.slots.width > 1)
        }

        @Test func eachTestHasAMenuPresenterOfItsOwn() async throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.isReleasedWhenClosed = false
            let mine = AppMenuPresenter.shared
            let menu = AppMenu(
                items: [AppMenuItem(title: "One", checked: false, action: {})], identifier: "menu",
                rowIdentifier: "menu.item")
            mine.show(menu, in: window, at: NSPoint(x: 10, y: 10), owner: nil)
            // What another test closes is its own menu, not this one.
            let other = AppMenuPresenter()
            await AppMenuPresenter.withOwn(other) {
                #expect(AppMenuPresenter.shared === other)
                AppMenuPresenter.shared.close()
            }
            #expect(AppMenuPresenter.shared === mine)
            #expect(mine.isOpen)
            mine.close()
            #expect(!mine.isOpen)
        }

        @Suite(.windowlessAlone) struct Alone {
            @Test func aSuiteMarkedAloneRunsItsTestsAlone() throws {
                let traits = try #require(Test.current).traits
                #expect(traits.contains { ($0 as? WindowlessSlots)?.alone == true })
            }
        }
    }
}

@Suite struct TestSlotsTests {
    /// A test in a slot: it starts when it gets one, and ends when `release` lets it.
    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var startedFlag = false
        private var endedFlag = false

        var started: Bool { lock.withLock { startedFlag } }
        var ended: Bool { lock.withLock { endedFlag } }

        init(_ slots: TestSlots, alone: Bool) {
            Task { await slots.run(alone: alone) { await self.body() } }
        }

        private func body() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                startedFlag = true
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
            lock.withLock { endedFlag = true }
        }

        func release() {
            lock.lock()
            released = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    /// Whether `condition` holds within `seconds`.
    private func soon(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func runsUpToItsWidthAtOnceAndTheNextWhenOneEnds() async {
        let slots = TestSlots(width: 2)
        let first = Held(slots, alone: false)
        let second = Held(slots, alone: false)
        #expect(await soon { first.started && second.started })
        let third = Held(slots, alone: false)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!third.started)
        first.release()
        #expect(await soon { first.ended && third.started })
        second.release()
        third.release()
        #expect(await soon { second.ended && third.ended })
    }

    @Test func aTestThatRunsAloneWaitsForTheOthersAndTheyForIt() async {
        let slots = TestSlots(width: 3)
        let first = Held(slots, alone: false)
        #expect(await soon { first.started })
        let alone = Held(slots, alone: true)
        try? await Task.sleep(for: .milliseconds(100))
        // Asked for after the one alone: it waits behind it, though a slot is free.
        let later = Held(slots, alone: false)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!alone.started)
        #expect(!later.started)
        first.release()
        #expect(await soon { alone.started })
        #expect(!later.started)
        alone.release()
        #expect(await soon { later.started })
        later.release()
        #expect(await soon { later.ended })
    }
}
