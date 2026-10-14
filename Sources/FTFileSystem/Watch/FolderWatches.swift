// Port of apps/desktop/src/main/folderWatch.ts
import FTFoundation
import Foundation

// The folder each window has on screen, watched so a change made outside the app (another app, Terminal, a
// download finishing) shows without a refresh. Only the folder in front is watched: a tab in the background
// reads its folder again when it comes back.
//
// On macOS a folder watch is an FSEvents stream: cheap to start and stop, so it simply follows the window
// from folder to folder.

/// Time for the watches: what the clock says, and a timer. Tests stand in for it with a manual one.
@MainActor
public protocol FolderWatchScheduler {
    /// Milliseconds on any steady clock.
    func now() -> Double
    /// Runs `work` after `milliseconds`; the returned function cancels it.
    func schedule(afterMilliseconds milliseconds: Double, _ work: @escaping @MainActor () -> Void) -> () -> Void
}

/// The timer of the app: the main queue.
@MainActor
public struct DispatchFolderWatchScheduler: FolderWatchScheduler {
    public init() {}

    public func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    public func schedule(afterMilliseconds milliseconds: Double, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + milliseconds / 1000, execute: item)
        return { item.cancel() }
    }
}

@MainActor
public final class FolderWatches {
    // A burst of changes (an unzip, a build, a big copy) is told of once, when it settles…
    public static let settleMilliseconds = 250.0
    // …or once a second while it goes on, so a folder that keeps changing still updates.
    public static let maxWaitMilliseconds = 1_000.0
    // More changed items than this are told of as "anything may have changed".
    public static let maxChangedPaths = 1_000

    @MainActor
    public struct Dependencies {
        /// Calls `onChange` with the name of the item that changed, or nil when that isn't known, and
        /// `onFail` when the watch stops by itself. Returns a function that stops watching, or nil when the
        /// watch can't start.
        public var watchFolder:
            @MainActor (
                _ path: String, _ onChange: @escaping @MainActor (String?) -> Void,
                _ onFail: @escaping @MainActor () -> Void
            ) -> (@Sendable () -> Void)?
        /// The folder's modification time (milliseconds), or nil when it can't be read.
        public var readModifiedTime: @Sendable (String) async -> Double?
        public var onFolderChanged: @MainActor (_ windowID: Int, _ change: FolderChange) -> Void
        /// Lets go of the listings of `path` the window might otherwise be handed again, and of the details
        /// of `changedPaths` in it (nil: anything in it, or the folder itself, may have changed), before it
        /// is told.
        public var forgetCachedListings: @MainActor (_ path: String, _ changedPaths: [String]?) -> Void
        public var scheduler: any FolderWatchScheduler

        public init(
            watchFolder: @escaping @MainActor (String, @escaping @MainActor (String?) -> Void, @escaping @MainActor () -> Void) -> (@Sendable () -> Void)?,
            readModifiedTime: @escaping @Sendable (String) async -> Double?,
            onFolderChanged: @escaping @MainActor (Int, FolderChange) -> Void,
            forgetCachedListings: @escaping @MainActor (String, [String]?) -> Void,
            scheduler: any FolderWatchScheduler = DispatchFolderWatchScheduler()
        ) {
            self.watchFolder = watchFolder
            self.readModifiedTime = readModifiedTime
            self.onFolderChanged = onFolderChanged
            self.forgetCachedListings = forgetCachedListings
            self.scheduler = scheduler
        }
    }

    private final class Watch {
        let path: String
        // Nil while not watching: the watch failed, or could not start.
        var stop: (@Sendable () -> Void)?
        var cancelTimer: (() -> Void)?
        var burstStartedAt: Double?
        // Nil once more changed than is worth naming.
        var changedNames: [String]? = []
        var changedNameSet = Set<String>()
        var modifiedTime: Double?
        // The modification time being read after the window was told of a change.
        var modifiedTimeRead: Task<Void, Never>?
        var readCount = 0

        init(path: String) { self.path = path }

        var hasTimer: Bool { cancelTimer != nil }
    }

    private let dependencies: Dependencies
    private var watches: [Int: Watch] = [:]

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Watches `path` for the window, in place of what it watched before; nil stops.
    public func watch(windowID: Int, path: String?) {
        if let path, let current = watches[windowID], current.path == path {
            if current.stop == nil {
                start(windowID, current)
            }
            return
        }
        stop(windowID)
        guard let path else { return }
        let watch = Watch(path: path)
        watches[windowID] = watch
        start(windowID, watch)
        recordModifiedTime(windowID, watch)
    }

    /// The window came back to the front: a change the watch could not see (on a network share, say) is
    /// caught by the folder's modification time, and a watch that failed is started again.
    public func checkForMissedChanges(windowID: Int) {
        guard let watch = watches[windowID] else { return }
        if watch.stop == nil {
            start(windowID, watch)
        }
        Task { await compareModifiedTime(windowID, watch) }
    }

    public func stopAll() {
        for windowID in Array(watches.keys) {
            stop(windowID)
        }
    }

    /// The paths being watched, for tests and logs.
    public var watchedPaths: [Int: String] { watches.mapValues(\.path) }

    // MARK: Inside

    private func recordModifiedTime(_ windowID: Int, _ watch: Watch) {
        watch.readCount += 1
        let number = watch.readCount
        let read = dependencies.readModifiedTime
        let path = watch.path
        // `read` is awaited off the main actor; the answer is applied here.
        watch.modifiedTimeRead = Task { @MainActor [weak self, weak watch] in
            let modifiedTime = await read(path)
            guard let self, let watch else { return }
            if self.watches[windowID] === watch {
                watch.modifiedTime = modifiedTime
            }
            if watch.readCount == number {
                watch.modifiedTimeRead = nil
            }
        }
    }

    private func tell(_ windowID: Int, _ watch: Watch) {
        watch.cancelTimer?()
        watch.cancelTimer = nil
        watch.burstStartedAt = nil
        let names = watch.changedNames
        watch.changedNames = []
        watch.changedNameSet = []
        recordModifiedTime(windowID, watch)
        let changedPaths = names.map { $0.map { NodePath.join(watch.path, $0) } }
        dependencies.forgetCachedListings(watch.path, changedPaths)
        dependencies.onFolderChanged(windowID, FolderChange(path: watch.path, changedPaths: changedPaths))
    }

    private func noteChange(_ windowID: Int, _ watch: Watch, name: String?) {
        guard watches[windowID] === watch else { return }
        if watch.changedNames != nil {
            if let name, !name.isEmpty,
                // The folder itself renamed or removed is told of by its own name. An item inside it with
                // the same name can't be told apart, and is read again with everything else.
                name != NodePath.basename(watch.path),
                watch.changedNames?.count ?? 0 < Self.maxChangedPaths
            {
                if watch.changedNameSet.insert(name).inserted {
                    watch.changedNames?.append(name)
                }
            } else {
                watch.changedNames = nil
                watch.changedNameSet = []
            }
        }
        let scheduler = dependencies.scheduler
        let time = scheduler.now()
        let burstStartedAt = watch.burstStartedAt ?? time
        watch.burstStartedAt = burstStartedAt
        watch.cancelTimer?()
        let wait = max(0, min(Self.settleMilliseconds, burstStartedAt + Self.maxWaitMilliseconds - time))
        watch.cancelTimer = scheduler.schedule(afterMilliseconds: wait) { [weak self, weak watch] in
            guard let self, let watch else { return }
            self.tell(windowID, watch)
        }
    }

    private func start(_ windowID: Int, _ watch: Watch) {
        watch.stop = dependencies.watchFolder(
            watch.path,
            { [weak self, weak watch] name in
                guard let self, let watch else { return }
                self.noteChange(windowID, watch, name: name)
            },
            { [weak self, weak watch] in
                guard let self, let watch else { return }
                // Started again when the window next asks for the folder or comes to the front; meanwhile
                // it reads the folder again, which may be gone.
                watch.stop = nil
                self.noteChange(windowID, watch, name: nil)
            })
    }

    private func compareModifiedTime(_ windowID: Int, _ watch: Watch) async {
        // The time read after the latest change was told of is the one compared to: compared to the one
        // before, that change would be told of twice.
        await watch.modifiedTimeRead?.value
        let known = watch.modifiedTime
        let modifiedTime = await dependencies.readModifiedTime(watch.path)
        // A change already on its way is told of anyway.
        guard watches[windowID] === watch, !watch.hasTimer else { return }
        // Not read yet when the watch started (or unreadable then): nothing to compare to.
        guard let known else {
            watch.modifiedTime = modifiedTime
            return
        }
        if modifiedTime == known { return }
        watch.changedNames = nil
        watch.changedNameSet = []
        tell(windowID, watch)
    }

    private func stop(_ windowID: Int) {
        guard let watch = watches.removeValue(forKey: windowID) else { return }
        watch.cancelTimer?()
        watch.cancelTimer = nil
        watch.stop?()
    }
}
