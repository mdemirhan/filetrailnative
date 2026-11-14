import Foundation
import Testing
import os

@testable import FTOperations

/// A ticker the test ticks by hand, which knows whether it was cancelled.
final class ManualTicker: ProgressTicker, @unchecked Sendable {
    private let lock = NSLock()
    private var tick: (@Sendable () -> Void)?
    private(set) var started: [Duration] = []

    func start(every interval: Duration, _ tick: @escaping @Sendable () -> Void) -> any ProgressTicking {
        lock.withLock {
            started.append(interval)
            self.tick = tick
        }
        return Ticking(owner: self)
    }

    /// The timers still running.
    var running: Int { lock.withLock { tick == nil ? 0 : 1 } }

    /// One interval passes.
    func fire(times: Int = 1) {
        for _ in 0..<times {
            lock.withLock { tick }?()
        }
    }

    private struct Ticking: ProgressTicking {
        let owner: ManualTicker

        func cancel() {
            owner.lock.withLock { owner.tick = nil }
        }
    }
}

/// What the fake copy was given, for checking afterwards.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, String, CopyControl?)] = []

    func record(_ source: String, _ destination: String, _ control: CopyControl?) {
        lock.withLock { calls.append((source, destination, control)) }
    }

    var all: [(String, String, CopyControl?)] { lock.withLock { calls } }
}

struct StoppableCopyTests {
    @Test func copiesWithoutAStopFlagWhenNothingCanStopIt() throws {
        let calls = Calls()
        try StoppableCopy(copy: { calls.record($0, $1, $2) }).copyFile("/a", to: "/b")

        #expect(calls.all.count == 1)
        #expect(calls.all.first?.0 == "/a" && calls.all.first?.1 == "/b")
        #expect(calls.all.first?.2 == nil)
    }

    @Test func raisesTheStopFlagWhenStoppedAndRejectsWithTheStop() {
        let stop = StopSignal()
        let calls = Calls()
        let copy = StoppableCopy(copy: { source, destination, control in
            calls.record(source, destination, control)
            stop.stop()
            throw NativeError.errno(ECANCELED, syscall: "copyfile", path: source, dest: destination)
        })

        #expect(throws: StopError()) { try copy.copyFile("/a", to: "/b", stop: stop) }
        #expect(calls.all.first?.2?.isStopped == true)
    }

    // A disk error that comes as the copy is stopped is still that error, not "stopped".
    @Test func passesOnAnotherErrorEvenAfterAStop() {
        let stop = StopSignal()
        let copy = StoppableCopy(copy: { source, destination, _ in
            stop.stop()
            throw NativeError.errno(EIO, syscall: "copyfile", path: source, dest: destination)
        })

        let error = #expect(throws: NativeError.self) { try copy.copyFile("/a", to: "/b", stop: stop) }
        #expect(error?.code == .errno(EIO))
    }

    // The native copy counts the bytes copied so far as one 64-bit count beside the flag.
    @Test func reportsTheBytesCopiedSoFarWhileTheCopyRunsAndStopsReadingAfter() throws {
        let ticker = ManualTicker()
        let progress = OSAllocatedUnfairLock(initialState: [Int64]())
        let controls = Calls()
        let copy = StoppableCopy(
            copy: { source, destination, control in
                controls.record(source, destination, control)
                guard let control else { return }
                // Past what one 32-bit number holds, as a large video is.
                control.copiedBytes = 5_000_000_000
                ticker.fire()
                // Not told again while the count stands still.
                ticker.fire()
                control.copiedBytes = 20_000_000_000
                ticker.fire()
            }, ticker: ticker)

        try copy.copyFile("/a", to: "/b", onProgress: { bytes in progress.withLock { $0.append(bytes) } })
        controls.all.first?.2?.copiedBytes = 30_000_000_000
        ticker.fire(times: 4)

        #expect(progress.withLock { $0 } == [5_000_000_000, 20_000_000_000])
        #expect(ticker.running == 0)
        #expect(ticker.started == [.milliseconds(250)])
    }

    @Test func doesntStartACopyAlreadyStopped() {
        let stop = StopSignal()
        stop.stop()
        let calls = Calls()
        let copy = StoppableCopy(copy: { calls.record($0, $1, $2) })

        #expect(throws: StopError()) { try copy.copyFile("/a", to: "/b", stop: stop) }
        #expect(calls.all.isEmpty)
    }

    // A Stop that comes from another thread as the copy starts either keeps it from starting or stops it: never a
    // copy left running to its end after Stop.
    @Test func aStopAsTheCopyStartsIsNeverMissed() {
        let missed = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 4_000) { _ in
            let stop = StopSignal()
            let started = DispatchSemaphore(value: 0)
            let copy = StoppableCopy(copy: { _, _, control in
                // The other thread's Stop has come by the time it is looked at.
                started.wait()
                if control?.isStopped != true { missed.withLock { $0 += 1 } }
            })
            DispatchQueue.global().async {
                stop.stop()
                started.signal()
            }
            do {
                try copy.copyFile("/a", to: "/b", stop: stop)
            } catch {
                started.wait()
            }
        }
        #expect(missed.withLock { $0 } == 0)
    }

    // The real ticker tells the bytes copied so far while the copy runs.
    @Test func reportsProgressOnTheRealTicker() throws {
        let progress = OSAllocatedUnfairLock(initialState: [Int64]())
        let told = DispatchSemaphore(value: 0)
        let copy = StoppableCopy(copy: { _, _, control in
            control?.copiedBytes = 7
            _ = told.wait(timeout: .now() + 5)
        })

        try copy.copyFile(
            "/a", to: "/b",
            onProgress: { bytes in
                progress.withLock { $0.append(bytes) }
                told.signal()
            })

        #expect(progress.withLock { $0 } == [7])
    }

    // The real ticker, cancelled: a tick under way has finished when `cancel` returns, and none comes after.
    @Test func theDispatchTickerTicksNoMoreOnceCancelled() {
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        let running = OSAllocatedUnfairLock(initialState: false)
        let ticked = DispatchSemaphore(value: 0)
        let ticking = DispatchProgressTicker().start(every: .milliseconds(5)) {
            running.withLock { $0 = true }
            ticks.withLock { $0 += 1 }
            ticked.signal()
            Thread.sleep(forTimeInterval: 0.002)
            running.withLock { $0 = false }
        }
        // It ticks again and again.
        #expect(ticked.wait(timeout: .now() + 5) == .success)
        #expect(ticked.wait(timeout: .now() + 5) == .success)

        ticking.cancel()
        #expect(!running.withLock { $0 })
        let count = ticks.withLock { $0 }
        // Ten intervals.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(ticks.withLock { $0 } == count)
    }

    @Test func stopSignalRunsEachHandlerOnceAndNoneAfterRemoval() {
        let stop = StopSignal()
        let count = OSAllocatedUnfairLock(initialState: 0)
        stop.onStop { count.withLock { $0 += 1 } }
        let removed = stop.onStop { count.withLock { $0 += 100 } }
        stop.removeHandler(removed)
        stop.stop()
        stop.stop()

        #expect(count.withLock { $0 } == 1)
        #expect(stop.onStop {} == nil)
        #expect(StopError().message == "This operation was aborted")
        #expect(describeCopyPasteError(StopError()) == "This operation was aborted")
    }
}
