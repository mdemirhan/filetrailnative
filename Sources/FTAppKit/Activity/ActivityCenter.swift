// What runs in the background in the whole app: the file operation and the folder sizes
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation

/// What runs in the background, for every window's activity ring and list: the file operation running (one at a
/// time in the whole app) and the folder sizes measured or waiting. It hears of them as they move, and tells the
/// windows at most every `interval`, as a walk moves on many times a second.
@MainActor
final class ActivityCenter {
    static let shared = ActivityCenter()
    /// Posted when `items` changed.
    static let changed = Notification.Name("FileTrailActivityChanged")
    static let interval = 0.25

    private(set) var items: [ActivityItem] = []
    /// The list has just emptied with a file operation in it that completed: the ring ends with a check. A size, or an
    /// operation stopped or failed, ends without one: the size shows where it was asked for, and a failure says so in
    /// its window.
    private(set) var endedWell = false

    /// The operation running, and the window it belongs to, for Stop.
    private var operation: (id: String, card: WriteOperationCardState)?
    private weak var operationOwner: (any WriteOperationWindow)?
    /// How the last file operation ended.
    private var operationCompleted = false
    private var lastOperationEnd: (id: String, status: WriteOperationStatus)?
    /// Stops a file operation as its window's Stop does; the app's write operations set it.
    var stopOperation: ((String, any WriteOperationWindow) -> Void)?
    /// The folder size jobs; a test hands its own.
    var jobs: () -> FolderSizeJobs? = { FolderSizeService.shared.jobs }
    /// The runs of several folders under way, what stops one and how one ended; a test hands its own.
    var runs: () -> [FolderSizeRunActivity] = { FolderSizeService.shared.activeRuns }
    var stopRun: (String) -> Void = { FolderSizeService.shared.stopRun($0) }
    var runCompleted: (String) -> Bool? = { FolderSizeService.shared.runCompleted($0) }
    private var refreshQueued = false

    // MARK: What it hears

    /// A file operation moved on, started or ended.
    func writeProgress(_ event: WriteOperationEvent, owner: any WriteOperationWindow) {
        if event.status.isTerminal {
            guard operation?.id == event.operationId else { return }
            operationCompleted = event.status == .completed
            lastOperationEnd = (event.operationId, event.status)
            operation = nil
            operationOwner = nil
        } else {
            let stage: WriteOperationStage =
                switch event.status {
                case .queued: .queued
                case .awaitingResolution: .awaitingResolution
                default: .running
                }
            operation = (
                event.operationId,
                WriteOperationCardState(
                    action: event.action, stage: stage, targetPath: event.result?.targetPath,
                    completedItemCount: event.completedItemCount, totalItemCount: event.totalItemCount,
                    completedByteCount: event.completedByteCount, totalBytes: event.totalBytes,
                    currentSourcePath: event.currentSourcePath)
            )
            operationOwner = owner
        }
        queueRefresh()
    }

    /// A folder size started, moved on, waits or ended.
    func sizesChanged() {
        queueRefresh()
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    /// Works the list out again now, telling the windows when it changed.
    func refresh() {
        let next = ActivityList.items(operation: operation, sizes: jobs()?.activity ?? [], runs: runs())
        guard next != items else { return }
        endedWell = next.isEmpty && operationCompleted && items.contains { $0.kind == .fileOperation }
        items = next
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// How what `item` listed ended, for its row in a list still open; nil when that isn't known.
    func outcome(of item: ActivityItem) -> ActivityOutcome? {
        switch item.kind {
        case .fileOperation:
            guard let end = lastOperationEnd, end.id == item.id else { return nil }
            switch end.status {
            case .completed: return .completed
            case .cancelled: return .stopped
            case .partial: return .partly
            default: return .failed
            }
        case .folderSize:
            guard let status = jobs()?.getStatus(jobId: item.id).status else { return nil }
            switch status {
            case .ready: return .completed
            case .cancelled: return .stopped
            case .error: return .failed
            default: return nil
            }
        case .folderSizeRun:
            return runCompleted(item.id).map { $0 ? .completed : .stopped }
        }
    }

    // MARK: Stop

    /// Stops what a row lists: the file operation as its card's Stop does, a folder size for every window that asked,
    /// a Calculate Size on several folders with the one being measured for it and those still to come.
    func stop(_ item: ActivityItem) {
        switch item.kind {
        case .fileOperation:
            guard item.id == operation?.id, let owner = operationOwner else { return }
            stopOperation?(item.id, owner)
        case .folderSize:
            jobs()?.cancel(jobId: item.id)
        case .folderSizeRun:
            stopRun(item.id)
        }
        refresh()
    }
}
