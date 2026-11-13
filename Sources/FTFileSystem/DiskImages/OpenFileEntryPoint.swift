import Foundation
import os

/// An item opened with File Trail from another app (Finder's Open With, a drop on the Dock icon,
/// `open -a "File Trail" <path>`), as the window in front is to open it.
public struct OpenRequest: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Opened as a disk image opened in File Trail is.
        case diskImage
        /// Shown in a new tab.
        case folder
        /// Selected in its folder in a new tab.
        case reveal
        /// Selected in the folder the window opened on: a window opened for it, when none was open.
        case select
    }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// macOS sends the items before the app is ready when it launches File Trail to open them: they wait for the windows.
///
/// The app delegate's `application(_:open:)` hands the paths to `open(_:)` and calls `startupWindowsOpened()`
/// once the first windows exist.
@MainActor
public final class OpenFileEntryPoint {
    /// How long the items given after one wait for its look at the disk, as other looks at a disk that may not answer
    /// do.
    public nonisolated static let waitForEarlierItems: Duration = .seconds(3)

    private let describe: @Sendable (String) -> OpenRequest?
    private let openRequest: (OpenRequest) -> Void
    /// Returns once the items given after others have waited long enough for them.
    private let waitedLongEnough: @Sendable () async -> Void
    private var windowsReady = false
    private var pending: [OpenRequest] = []
    /// The items given last, until they have been looked at and taken: the next ones wait for them, for a while.
    private var lastTaken: Task<[OpenRequest], Never>?

    /// `describe` says what to do with a path, nil for one that isn't there. It looks at the disk, so it is asked off
    /// the main thread. `waitedLongEnough` stands for `waitForEarlierItems` going by.
    public init(
        describe: @escaping @Sendable (String) -> OpenRequest?, open: @escaping (OpenRequest) -> Void,
        waitedLongEnough: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: OpenFileEntryPoint.waitForEarlierItems)
        }
    ) {
        self.describe = describe
        openRequest = open
        self.waitedLongEnough = waitedLongEnough
    }

    /// Takes `paths`. Each is looked at off the main thread, as an item on a disk that is slow to answer must not hold
    /// the app up, then opened or kept for the windows: in the order given, after the items given before, unless those
    /// are still being looked at after `waitForEarlierItems` (a disk that doesn't answer): then these go first, and
    /// those follow when their disk answers. An item that isn't there is left out. The task answers what was claimed,
    /// once it has been taken.
    @discardableResult
    public func open(_ paths: [String]) -> Task<[OpenRequest], Never> {
        let before = lastTaken
        let looked = Task.detached { [describe] in paths.compactMap(describe) }
        let taken = Task { [waitedLongEnough] in
            if let before {
                await Self.firstOf({ _ = await before.value }, waitedLongEnough)
            }
            let claimed = await looked.value
            take(claimed)
            return claimed
        }
        lastTaken = taken
        return taken
    }

    /// Returns as soon as either returns; the other is left to finish on its own.
    private nonisolated static func firstOf(
        _ one: @escaping @Sendable () async -> Void, _ other: @escaping @Sendable () async -> Void
    ) async {
        let done = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            for work in [one, other] {
                Task {
                    await work()
                    let first = done.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume() }
                }
            }
        }
    }

    private func take(_ claimed: [OpenRequest]) {
        for request in claimed {
            if windowsReady {
                openRequest(request)
            } else {
                pending.append(request)
            }
        }
    }

    /// The first windows are open: the items that came before them are opened now.
    public func startupWindowsOpened() {
        windowsReady = true
        let queued = pending
        pending = []
        for request in queued { openRequest(request) }
    }
}
