// Port of apps/desktop/src/renderer/lib/relativeClock.ts
import Foundation

/// The time relative dates ("24 min ago", "Today, 9:12 AM") are measured from: the minute that is
/// now, so every date on screen agrees. Nothing runs to keep it current unless a date on screen needs
/// it: once a minute while one is under an hour old and the window can be seen, and at midnight for
/// the rest (Today becomes Yesterday).
@MainActor
public final class RelativeClock {
    private static let minute = 60.0
    // Timers are asked for a little after the boundary so they never land just before it.
    private static let boundarySlack = 0.05

    /// Called when dates on screen should be read again.
    public typealias Listener = @MainActor () -> Void

    /// What `subscribe` and `holdMinuteTicks` hand back; calling it more than once does nothing.
    @MainActor
    public final class Release {
        private var action: (@MainActor () -> Void)?

        fileprivate init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        public func callAsFunction() {
            let run = action
            action = nil
            run?()
        }
    }

    private let clock: () -> Date
    private let calendar: Calendar
    private let scheduler: any TimerScheduling
    /// Whether a window can be seen; the app says, as this module knows no windows.
    public var isWindowVisible: () -> Bool

    private var listeners: [(id: Int, listener: Listener)] = []
    private var nextListenerID = 0
    private var minuteHolds = 0
    private var minuteTimer: TimerToken?
    private var midnightTimer: TimerToken?

    public static let shared = RelativeClock()

    /// - Parameters:
    ///   - clock: the time; the app's clock unless a test says otherwise.
    ///   - isWindowVisible: whether a window can be seen (the minute timer is not wanted otherwise).
    public init(
        clock: @escaping () -> Date = { AppClock.now },
        timeZone: TimeZone = .autoupdatingCurrent,
        scheduler: any TimerScheduling = TaskTimerScheduler(),
        isWindowVisible: @escaping () -> Bool = { true }
    ) {
        self.clock = clock
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.scheduler = scheduler
        self.isWindowVisible = isWindowVisible
    }

    /// The minute that is now.
    public var relativeNow: Date {
        let ms = clock().epochMilliseconds
        return Date(epochMilliseconds: (ms / 60_000).rounded(.down) * 60_000)
    }

    public func subscribe(_ listener: @escaping Listener) -> Release {
        let id = nextListenerID
        nextListenerID += 1
        listeners.append((id, listener))
        syncTimers()
        return Release { [self] in
            listeners.removeAll { $0.id == id }
            syncTimers()
        }
    }

    /// Held by each date on screen that reads in minutes; the minute timer runs while any is held.
    public func holdMinuteTicks() -> Release {
        minuteHolds += 1
        syncTimers()
        return Release { [self] in
            minuteHolds -= 1
            syncTimers()
        }
    }

    /// Coming back to the window (it became visible or key): time has passed with no timer running,
    /// so the dates are read again, and the minute timer starts again if it is wanted. Also to be
    /// called when the window is hidden, as the original's visibility handler is.
    public func windowStateDidChange() {
        notify()
        syncTimers()
    }

    private func notify() {
        for entry in listeners {
            entry.listener()
        }
    }

    private func syncTimers() {
        let watched = !listeners.isEmpty
        let wantsMinutes = watched && minuteHolds > 0 && isWindowVisible()
        if wantsMinutes, minuteTimer == nil {
            let nowMs = clock().epochMilliseconds
            let untilBoundary = 60_000 - nowMs.truncatingRemainder(dividingBy: 60_000)
            minuteTimer = scheduler.schedule(after: untilBoundary / 1000 + Self.boundarySlack) { [self] in
                minuteTimer = nil
                notify()
                syncTimers()
            }
        } else if !wantsMinutes, let timer = minuteTimer {
            timer.cancel()
            minuteTimer = nil
        }

        if watched, midnightTimer == nil {
            let now = clock()
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            midnightTimer = scheduler.schedule(after: nextMidnight.timeIntervalSince(now) + Self.boundarySlack) {
                [self] in
                midnightTimer = nil
                notify()
                syncTimers()
            }
        } else if !watched, let timer = midnightTimer {
            timer.cancel()
            midnightTimer = nil
        }
    }
}
