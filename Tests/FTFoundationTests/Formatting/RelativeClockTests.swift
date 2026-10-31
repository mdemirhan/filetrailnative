// Port of apps/desktop/src/renderer/lib/relativeClock.test.ts
import Foundation
import Testing

@testable import FTFoundation

@MainActor
struct RelativeClockTests {
    private let zone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt

    private func local(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(
            from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))
            ?? .distantPast
    }

    private final class Counter {
        var calls = 0
    }

    private final class Visibility {
        var visible = true
    }

    private func makeRig() -> (timers: VirtualTimers, clock: RelativeClock, visibility: Visibility) {
        // Thursday, 14:44:20.
        let timers = VirtualTimers(start: local(1, 14, 44, 20))
        let visibility = Visibility()
        let clock = RelativeClock(
            clock: { timers.now }, timeZone: zone, scheduler: timers,
            isWindowVisible: { visibility.visible })
        return (timers, clock, visibility)
    }

    // T-117d436c
    @Test func readsTheMinuteThatIsNow() {
        let rig = makeRig()
        #expect(rig.clock.relativeNow == local(1, 14, 44, 0))
    }

    // T-bcb122bb
    @Test func runsNoMinuteTimerForDatesThatDoNotReadInMinutes() {
        let rig = makeRig()
        let counter = Counter()
        let unsubscribe = rig.clock.subscribe { counter.calls += 1 }

        rig.timers.advance(by: 3 * 3600)

        #expect(counter.calls == 0)
        unsubscribe()
        #expect(rig.timers.count == 0)
    }

    // T-57e92028
    // T-d7679d79
    @Test func ticksOnTheMinuteWhileADateOnScreenReadsInMinutes() {
        let rig = makeRig()
        let counter = Counter()
        let unsubscribe = rig.clock.subscribe { counter.calls += 1 }
        let release = rig.clock.holdMinuteTicks()

        rig.timers.advance(by: 39)
        #expect(counter.calls == 0)
        rig.timers.advance(by: 2)
        #expect(counter.calls == 1)
        #expect(rig.clock.relativeNow == local(1, 14, 45, 0))
        rig.timers.advance(by: 60)
        #expect(counter.calls == 2)

        release()
        rig.timers.advance(by: 10 * 60)
        #expect(counter.calls == 2)
        unsubscribe()
        #expect(rig.timers.count == 0)
    }

    // T-ebe6fe52
    @Test func stopsTickingWhileTheWindowCanNotBeSeenAndCatchesUpWhenItCan() {
        let rig = makeRig()
        let counter = Counter()
        let unsubscribe = rig.clock.subscribe { counter.calls += 1 }
        let release = rig.clock.holdMinuteTicks()

        rig.visibility.visible = false
        rig.clock.windowStateDidChange()
        counter.calls = 0
        rig.timers.advance(by: 10 * 60)
        #expect(counter.calls == 0)

        rig.visibility.visible = true
        rig.clock.windowStateDidChange()
        #expect(counter.calls == 1)
        rig.timers.advance(by: 60)
        #expect(counter.calls == 2)

        release()
        unsubscribe()
    }

    // T-1a415366
    // T-0eafbeb8
    @Test func ticksAtMidnightWhenTodayBecomesYesterday() {
        let rig = makeRig()
        let counter = Counter()
        let unsubscribe = rig.clock.subscribe { counter.calls += 1 }

        rig.timers.advance(by: 9 * 3600 + 15 * 60)
        #expect(counter.calls == 0)
        rig.timers.advance(by: 60)
        #expect(counter.calls == 1)
        // And again the night after.
        rig.timers.advance(by: 24 * 3600)
        #expect(counter.calls == 2)

        unsubscribe()
        #expect(rig.timers.count == 0)
    }

    @Test func releasingTwiceDoesNothingTheSecondTime() {
        let rig = makeRig()
        let counter = Counter()
        let first = rig.clock.holdMinuteTicks()
        let second = rig.clock.holdMinuteTicks()
        let unsubscribe = rig.clock.subscribe { counter.calls += 1 }
        first()
        first()
        rig.timers.advance(by: 61)
        // The second hold is still there.
        #expect(counter.calls == 1)
        second()
        unsubscribe()
    }
}
