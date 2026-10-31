// Port of the timers of apps/desktop/src/renderer/components/ToastViewport.test.tsx and "go by themselves" of
// App.notifications.test.tsx: the window's ToastCenter on a clock the test moves
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// The timers a ToastCenter asked for, run by hand.
@MainActor
private final class ToastTimers {
    final class Timer {
        let delay: TimeInterval
        let work: @MainActor () -> Void
        var isCancelled = false

        init(delay: TimeInterval, work: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.work = work
        }
    }

    private(set) var timers: [Timer] = []

    func install(on center: ToastCenter) {
        center.now = { 1_000 }
        center.schedule = { [weak self] delay, work in
            let timer = Timer(delay: delay, work: work)
            self?.timers.append(timer)
            return ToastCenter.Cancel { timer.isCancelled = true }
        }
    }

    /// Runs a timer as the main queue would: one cancelled doesn't run.
    func fire(_ index: Int) {
        guard !timers[index].isCancelled else { return }
        timers[index].work()
    }
}

@MainActor
@Suite struct ToastTimersTests {
    private func center() -> (ToastCenter, ToastTimers) {
        let center = ToastCenter()
        let timers = ToastTimers()
        timers.install(on: center)
        return (center, timers)
    }

    // T-129550df T-f6990b56 B-VIEW-198: a notification stays until its four seconds are up, then goes by itself.
    @Test func eachGoesByItselfWhenItsFourSecondsAreUp() {
        let (center, timers) = center()
        let id = center.push(.info, title: "One")
        #expect(timers.timers.map(\.delay) == [4])
        #expect(center.entries.map(\.id) == [id])
        timers.fire(0)
        #expect(center.entries.isEmpty)
    }

    // B-VIEW-198: dismissing one cancels its timer and leaves the others'.
    @Test func dismissingOneCancelsItsTimerOnly() throws {
        let (center, timers) = center()
        let first = try #require(center.push(.info, title: "One"))
        center.push(.info, title: "Two")
        center.dismiss(first)
        #expect(timers.timers.map(\.isCancelled) == [true, false])
        #expect(center.entries.map(\.title) == ["Two"])
        timers.fire(1)
        #expect(center.entries.isEmpty)
    }

    // B-VIEW-198: a fourth drops the oldest with its timer; they stay in order, oldest first.
    @Test func aFourthDropsTheOldestAndItsTimer() {
        let (center, timers) = center()
        for title in ["One", "Two", "Three", "Four"] { center.push(.info, title: title) }
        #expect(center.entries.map(\.title) == ["Two", "Three", "Four"])
        #expect(timers.timers.map(\.isCancelled) == [true, false, false, false])
    }

    // B-VIEW-198: those turned off go with their timers.
    @Test func clearingCancelsEveryTimer() {
        let (center, timers) = center()
        center.push(.info, title: "One")
        center.push(.info, title: "Two")
        center.clear()
        #expect(center.entries.isEmpty)
        #expect(timers.timers.map(\.isCancelled) == [true, true])
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ToastCardTimerTests {
        // T-f6990b56: the card in the window goes with its notification.
        @Test func theCardGoesWhenItsTimeIsUp() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let overlay = try #require(tab.notifications)
            let timers = ToastTimers()
            timers.install(on: overlay.toasts)
            func cards() -> [ToastCardView] { overlay.subviews.compactMap { $0 as? ToastCardView } }
            overlay.toasts.push(.info, title: "One")
            #expect(cards().map(\.entry.title) == ["One"])
            timers.fire(0)
            #expect(await waitUntil { cards().isEmpty })
            await harness.close()
        }
    }
}
