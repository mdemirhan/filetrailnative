// Port of the bounds recording of apps/desktop/src/main/explorerWindowController.ts (WINDOW_BOUNDS_SAVE_DELAY_MS, recordBounds, scheduleBoundsSave)
import FTFoundation
import Foundation

/// What the window reports when its bounds are recorded.
public struct WindowBoundsSnapshot: Sendable, Equatable {
    /// Where the window goes back to out of full screen or zoomed, not the size of the screen.
    public var normalX: Double
    public var normalY: Double
    public var normalWidth: Double
    public var normalHeight: Double
    public var isZoomed: Bool
    public var isFullScreen: Bool

    public init(
        normalX: Double, normalY: Double, normalWidth: Double, normalHeight: Double, isZoomed: Bool,
        isFullScreen: Bool
    ) {
        self.normalX = normalX
        self.normalY = normalY
        self.normalWidth = normalWidth
        self.normalHeight = normalHeight
        self.isZoomed = isZoomed
        self.isFullScreen = isFullScreen
    }

    /// The stored bounds: a full-screen window comes back out of full screen, at its normal place, so it is not
    /// recorded as maximized.
    public var stored: StoredWindowState {
        StoredWindowState(
            x: normalX, y: normalY, width: normalWidth, height: normalHeight, maximized: isZoomed && !isFullScreen)
    }
}

/// Records one window's bounds into the store: a move, a resize, zoom and unzoom, and leaving full screen are recorded
/// 160 ms after the last of them (a drag is one record); closing records at once.
public final class WindowBoundsRecorder: @unchecked Sendable {
    /// WINDOW_BOUNDS_SAVE_DELAY_MS.
    public static let saveDelayMilliseconds = 160

    private let windowID: String
    private let timer: any StateTimer
    private let snapshot: @Sendable () -> WindowBoundsSnapshot?
    private let record: @Sendable (String, StoredWindowState) -> Void
    private let lock = NSLock()
    private var cancelPending: (@Sendable () -> Void)?

    /// `snapshot` returns nil once the window is gone; `record` is the store's `setExplorerWindowBounds`.
    public init(
        windowID: String, timer: any StateTimer = DispatchStateTimer(),
        snapshot: @escaping @Sendable () -> WindowBoundsSnapshot?,
        record: @escaping @Sendable (String, StoredWindowState) -> Void
    ) {
        self.windowID = windowID
        self.timer = timer
        self.snapshot = snapshot
        self.record = record
    }

    /// `scheduleBoundsSave`: the window moved, resized, zoomed, unzoomed or left full screen.
    public func windowBoundsDidChange() {
        lock.lock()
        defer { lock.unlock() }
        cancelPending?()
        cancelPending = timer.schedule(afterMilliseconds: Self.saveDelayMilliseconds) { [weak self] in
            self?.fire()
        }
    }

    /// `recordBounds`: the window is closing, or the app is quitting.
    public func recordNow() {
        guard let current = snapshot() else { return }
        record(windowID, current.stored)
    }

    /// The window closed: a pending record is dropped.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelPending?()
        cancelPending = nil
    }

    private func fire() {
        lock.lock()
        cancelPending = nil
        lock.unlock()
        recordNow()
    }
}
