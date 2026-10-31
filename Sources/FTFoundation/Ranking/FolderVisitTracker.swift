// Port of apps/desktop/src/renderer/lib/folderVisitTracker.ts
import Foundation

/// Decides how much opening a folder counts for the Go To box. Picked in Go To, it counts at once and
/// most. Opened another way, it counts once it has stayed on screen a few seconds or been used; left
/// before that, it was only passed through.
@MainActor
public final class FolderVisitTracker {
    /// How long a folder must stay on screen for opening it to count as a visit. Clicking or arrowing
    /// through folders on the way to another takes less.
    public static let stayDelay: TimeInterval = 5

    private let record: (String, FolderVisitKind) -> Void
    private let scheduler: any TimerScheduling
    private var pending: (path: String, timer: TimerToken)?

    public init(
        scheduler: any TimerScheduling = TaskTimerScheduler(), record: @escaping (String, FolderVisitKind) -> Void
    ) {
        self.record = record
        self.scheduler = scheduler
    }

    /// A folder was gone to; `viaGoTo` when it was picked in the Go To box.
    public func arrive(_ path: String, viaGoTo: Bool) {
        settle(.passThrough)
        if viaGoTo {
            record(path, .goTo)
            return
        }
        let timer = scheduler.schedule(after: Self.stayDelay) { [weak self] in
            self?.settle(.stay)
        }
        pending = (path, timer)
    }

    /// The folder on screen is now `path` (Back, another tab…): a different one was left.
    public func showing(_ path: String) {
        if let pending, !JSString.equals(pending.path, path) {
            settle(.passThrough)
        }
    }

    /// Something was done in the folder on screen (a file opened, a paste): it was wanted.
    public func use() {
        settle(.stay)
    }

    /// The window goes away: a folder still being decided on was only passed through.
    public func dispose() {
        settle(.passThrough)
    }

    private func settle(_ kind: FolderVisitKind) {
        guard let pending else { return }
        pending.timer.cancel()
        self.pending = nil
        record(pending.path, kind)
    }
}
