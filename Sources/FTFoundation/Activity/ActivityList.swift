// What runs in the background, as the title's activity ring and its list show it
import Foundation

/// A folder size being measured or waiting, as the jobs report it for the Activity list.
public struct FolderSizeActivity: Equatable, Sendable {
    public var jobId: String
    public var path: String
    /// Measured now; false while it waits its turn.
    public var isRunning: Bool
    /// Started by the app itself (the Info panel's or the Info Row's), not asked for.
    public var isAutomatic: Bool
    /// The folders inside it measured so far.
    public var measuredFolderCount: Int

    public init(jobId: String, path: String, isRunning: Bool, isAutomatic: Bool, measuredFolderCount: Int) {
        self.jobId = jobId
        self.path = path
        self.isRunning = isRunning
        self.isAutomatic = isAutomatic
        self.measuredFolderCount = measuredFolderCount
    }
}

/// The folders of a Calculate Size on several that wait their turn behind the one being measured: one request, so one
/// row of the Activity list.
public struct FolderSizeRunActivity: Equatable, Sendable {
    /// The run's id, for Stop.
    public var id: String
    /// How many of its folders wait.
    public var waitingCount: Int

    public init(id: String, waitingCount: Int) {
        self.id = id
        self.waitingCount = waitingCount
    }
}

/// What the ring at the end of the toolbar's title shows while something runs in the background.
public struct ActivityIndicator: Equatable, Sendable {
    /// How far round the ring is filled, 0...1; nil while how far along is unknown, where it spins.
    public var progress: Double?
    /// Nothing listed runs yet: the ring spins dimmed.
    public var isWaiting: Bool
    /// The others listed, which the ring's pill counts ("+2"); 0 shows the ring alone.
    public var moreCount: Int

    public init(progress: Double?, isWaiting: Bool, moreCount: Int) {
        self.progress = progress
        self.isWaiting = isWaiting
        self.moreCount = moreCount
    }

    /// The pill's text.
    public var countLabel: String? { moreCount > 0 ? "+\(moreCount)" : nil }
}

/// One row of the Activity list.
public struct ActivityItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case fileOperation
        case folderSize
        /// The folders of a Calculate Size on several still waiting their turn.
        case folderSizeRun
    }

    /// The operation's id, the folder size job's, or the run's.
    public var id: String
    public var kind: Kind
    /// "Copying…", or the folder's name.
    public var title: String
    /// How far along it is, or that it waits.
    public var detail: String
    /// 0...1 when how far along is known.
    public var progress: Double?
    public var isWaiting: Bool

    public init(id: String, kind: Kind, title: String, detail: String, progress: Double?, isWaiting: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.progress = progress
        self.isWaiting = isWaiting
    }
}

/// How something the Activity list showed ended, for its row, which stays while the list is open.
public enum ActivityOutcome: Equatable, Sendable {
    case completed
    case stopped
    case failed
    /// A file operation that did part of its work.
    case partly
    /// Still running, but no longer listed: a walk the app started by itself that holds up nothing asked for now.
    case goesOn
}

public enum ActivityList {
    /// What the row of something no longer listed says in place of how far along it was; `outcome` nil when how it
    /// ended isn't known.
    public static func endedDetail(_ kind: ActivityItem.Kind, _ outcome: ActivityOutcome?) -> String {
        switch (kind, outcome) {
        case (_, .completed): "Done"
        case (_, .stopped): "Stopped"
        case (.fileOperation, .failed): "Didn't finish"
        case (_, .failed): "Couldn't calculate"
        case (_, .partly): "Finished in part"
        case (_, .goesOn): "Calculating size"
        case (.folderSizeRun, nil): "No longer waiting"
        case (_, nil): "Ended"
        }
    }

    /// The rows: the file operation running (one at a time in the whole app), then the folder sizes, the one measured
    /// first and the rest in the order they wait. A walk the app started by itself is listed only while it runs with a
    /// size asked for waiting behind it, so the list says what holds that size up; otherwise it is quiet, as it is
    /// meant to be. Last, a row for each Calculate Size on several folders with folders still waiting their turn.
    public static func items(
        operation: (id: String, card: WriteOperationCardState)?, sizes: [FolderSizeActivity],
        runs: [FolderSizeRunActivity] = []
    ) -> [ActivityItem] {
        var items: [ActivityItem] = []
        if let operation {
            let text = ProgressCardText(operation.card, currentPath: operation.card.targetPath ?? "")
            let waiting = operation.card.stage == .queued
            var detail = waiting ? "Waiting" : text.percentLabel
            if !waiting, !text.metaStart.isEmpty { detail += " · \(text.metaStart)" }
            items.append(
                ActivityItem(
                    id: operation.id, kind: .fileOperation, title: text.title, detail: detail,
                    progress: waiting ? nil : min(1, max(0, text.percent / 100)), isWaiting: waiting))
        }
        let askedWaiting = sizes.contains { !$0.isAutomatic && !$0.isRunning }
        for size in sizes.sorted(by: { $0.isRunning && !$1.isRunning }) {
            if size.isAutomatic && !(size.isRunning && askedWaiting) { continue }
            items.append(folderSizeItem(size))
        }
        for run in runs where run.waitingCount > 0 {
            let one = run.waitingCount == 1
            items.append(
                ActivityItem(
                    id: run.id, kind: .folderSizeRun,
                    title: "\(ContextMenuRules.groupedCount(run.waitingCount)) more \(one ? "folder" : "folders")",
                    detail: one ? "Waiting to calculate its size" : "Waiting to calculate their sizes",
                    progress: nil, isWaiting: true))
        }
        return items
    }

    private static func folderSizeItem(_ size: FolderSizeActivity) -> ActivityItem {
        let detail: String
        if !size.isRunning {
            detail = "Waiting to calculate its size"
        } else if size.measuredFolderCount > 0 {
            let count = ContextMenuRules.groupedCount(size.measuredFolderCount)
            detail = "Calculating size · \(count) \(size.measuredFolderCount == 1 ? "folder" : "folders") so far"
        } else {
            detail = "Calculating size"
        }
        return ActivityItem(
            id: size.jobId, kind: .folderSize, title: ProgressCardText.leafName(size.path), detail: detail,
            progress: nil, isWaiting: !size.isRunning)
    }

    /// What the title's ring shows for `items`; nil when nothing is listed. The ring follows the first listed that runs
    /// (the first listed when they all wait), and counts the others.
    public static func indicator(_ items: [ActivityItem]) -> ActivityIndicator? {
        guard let first = items.first else { return nil }
        let lead = items.first { !$0.isWaiting } ?? first
        return ActivityIndicator(
            progress: lead.isWaiting ? nil : lead.progress, isWaiting: lead.isWaiting, moreCount: items.count - 1)
    }

    /// The ring's tooltip: what runs, and how many more are listed.
    public static func summary(_ items: [ActivityItem]) -> String {
        guard let first = items.first else { return "Activity" }
        let rest = items.count - 1
        return rest == 0 ? "\(first.title): \(first.detail)" : "\(first.title) and \(rest) more"
    }
}
