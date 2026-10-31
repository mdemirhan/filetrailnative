// Port of the bounds recording of apps/desktop/src/main/explorerWindowController.ts (no test of its own in the original)
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct WindowBoundsRecorderTests {
    final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, StoredWindowState)] = []
        func add(_ id: String, _ state: StoredWindowState) {
            lock.lock()
            items.append((id, state))
            lock.unlock()
        }
        var all: [(String, StoredWindowState)] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    @Test func aBurstOfChangesIsOneRecord160MillisecondsLater() {
        let timer = ManualTimer()
        let recorded = Recorded()
        let recorder = WindowBoundsRecorder(
            windowID: "window-a", timer: timer,
            snapshot: {
                WindowBoundsSnapshot(
                    normalX: 5, normalY: 6, normalWidth: 700, normalHeight: 500, isZoomed: true, isFullScreen: false)
            },
            record: { recorded.add($0, $1) })
        recorder.windowBoundsDidChange()
        recorder.windowBoundsDidChange()
        recorder.windowBoundsDidChange()
        #expect(timer.pendingDelays == [160])
        timer.run()
        #expect(recorded.all.count == 1)
        #expect(recorded.all.first?.0 == "window-a")
        #expect(
            recorded.all.first?.1 == StoredWindowState(x: 5, y: 6, width: 700, height: 500, maximized: true))
    }

    @Test func aFullScreenWindowIsNotRecordedAsMaximized() {
        let snapshot = WindowBoundsSnapshot(
            normalX: 0, normalY: 0, normalWidth: 900, normalHeight: 600, isZoomed: true, isFullScreen: true)
        #expect(snapshot.stored.maximized == false)
        #expect(snapshot.stored.width == 900)
    }

    @Test func closingRecordsAtOnceAndACancelledRecordNeverRuns() {
        let timer = ManualTimer()
        let recorded = Recorded()
        let recorder = WindowBoundsRecorder(
            windowID: "window-a", timer: timer,
            snapshot: {
                WindowBoundsSnapshot(
                    normalX: 1, normalY: 2, normalWidth: 800, normalHeight: 600, isZoomed: false, isFullScreen: false)
            },
            record: { recorded.add($0, $1) })
        recorder.windowBoundsDidChange()
        recorder.recordNow()
        #expect(recorded.all.count == 1)
        recorder.cancel()
        timer.run()
        #expect(recorded.all.count == 1)
    }

    @Test func aWindowThatIsGoneRecordsNothing() {
        let recorded = Recorded()
        let recorder = WindowBoundsRecorder(windowID: "window-a", snapshot: { nil }, record: { recorded.add($0, $1) })
        recorder.recordNow()
        #expect(recorded.all.isEmpty)
    }
}
