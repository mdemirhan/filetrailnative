// Port of what App.tsx and AppDialogs.tsx keep of the copy and paste dialogs (copyPasteModalOpen, the dialogs'
// part in explorerFocusSuppressed) and of the shapes copyPasteReview.ts, CopyPasteRuntimeConflictDialog.tsx and
// CopyPasteResultDialog.tsx read from the contract
import AppKit
import FTFoundation
import FTOperations

/// The copy and paste dialogs drawn in the explorer windows: the review sheet, the single-conflict alert, the runtime
/// conflict alert and the result sheet. While one is up in a tab's window the explorer waits: its folder's changes are
/// held (B-CLIP-114) and its commands, keys and drags wait as under any dialog (B-CLIP-123).
@MainActor
enum CopyPasteDialogs {
    private final class Shown {
        weak var scrim: DialogScrim?
        weak var tab: MainWindowController?

        init(scrim: DialogScrim, tab: MainWindowController) {
            self.scrim = scrim
            self.tab = tab
        }
    }

    private static var shown: [Shown] = []

    /// Whether one of these dialogs is up in `window` (`copyPasteModalOpen`, for `ShortcutContext`).
    static func isOpen(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return scrims.contains { $0.window === window }
    }

    /// The dialogs up, oldest first.
    static var scrims: [DialogScrim] {
        shown.compactMap { $0.scrim }.filter { !$0.isDismissed }
    }

    /// Shows `panel` over `tab`'s window, the tab's folder changes held until the last of these dialogs there goes.
    @discardableResult
    static func present(
        _ panel: any DialogPanel, placement: DialogScrim.Placement, on tab: MainWindowController, in window: NSWindow,
        onWindowClose: (() -> Void)? = nil
    ) -> DialogScrim {
        let scrim = DialogScrim(panel: panel, placement: placement)
        scrim.onWindowClose = onWindowClose
        track(scrim, on: tab)
        scrim.present(in: window)
        return scrim
    }

    /// Holds `tab`'s folder changes while `scrim` is up.
    static func track(_ scrim: DialogScrim, on tab: MainWindowController) {
        shown.removeAll { $0.scrim == nil || $0.scrim?.isDismissed == true }
        shown.append(Shown(scrim: scrim, tab: tab))
        tab.folderChangesHeld = true
        let previous = scrim.onDismiss
        scrim.onDismiss = { [weak tab, weak scrim] in
            previous()
            shown.removeAll { $0.scrim == nil || $0.scrim === scrim || $0.scrim?.isDismissed == true }
            guard let tab, !shown.contains(where: { $0.tab === tab }) else { return }
            tab.folderChangesHeld = false
        }
    }
}

extension ReviewReport {
    /// The analysis report as the review reads it.
    init(_ report: CopyPasteAnalysisReport) {
        self.init(
            analysisId: report.analysisId, mode: report.mode == .cut ? .cut : .copy,
            destinationDirectoryPath: report.destinationDirectoryPath, nodes: report.nodes.map(ReviewNode.init),
            summary: Summary(
                totalNodeCount: report.summary.totalNodeCount,
                directoryConflictCount: report.summary.directoryConflictCount))
    }
}

extension ReviewNode {
    init(_ node: CopyPasteAnalysisNode) {
        self.init(
            id: node.id, sourcePath: node.sourcePath, destinationPath: node.destinationPath,
            sourceKind: ReviewNodeKind(node.sourceKind), destinationKind: ReviewNodeKind(node.destinationKind),
            conflictClass: node.conflictClass, sourceFingerprint: ReviewFingerprint(node.sourceFingerprint),
            destinationFingerprint: ReviewFingerprint(node.destinationFingerprint),
            children: node.children.map(ReviewNode.init), totalNodeCount: node.totalNodeCount,
            conflictNodeCount: node.conflictNodeCount, destinationTotalNodeCount: node.destinationTotalNodeCount,
            keepBothDestinationPath: node.keepBothDestinationPath,
            destinationOnly: node.destinationOnly.map {
                ReviewDestinationOnly(count: $0.count, samplePaths: $0.samplePaths)
            }, replaceBlockedReason: node.replaceBlockedReason, renameOnly: node.renameOnly)
    }
}

extension ReviewNodeKind {
    init(_ kind: CopyPasteNodeKind) {
        switch kind {
        case .missing: self = .missing
        case .file: self = .file
        case .directory: self = .directory
        case .symlink: self = .symlink
        }
    }
}

extension ReviewFingerprint {
    init(_ fingerprint: NodeFingerprint) {
        self.init(
            exists: fingerprint.exists, kind: ReviewNodeKind(fingerprint.kind), size: fingerprint.size,
            mtimeMs: fingerprint.mtimeMs)
    }
}

extension RuntimeConflictInput {
    init(_ conflict: CopyPasteRuntimeConflict) {
        self.init(
            reason: conflict.reason, conflictClass: conflict.conflictClass, sourcePath: conflict.sourcePath,
            destinationPath: conflict.destinationPath,
            currentSourceFingerprint: ReviewFingerprint(conflict.currentSourceFingerprint),
            currentDestinationFingerprint: ReviewFingerprint(conflict.currentDestinationFingerprint))
    }
}

extension ResultItem {
    init(_ item: WriteOperationItem) {
        let status: ResultItem.Status =
            switch item.status {
            case .completed: .completed
            case .skipped: .skipped
            case .failed: .failed
            case .cancelled: .cancelled
            }
        self.init(
            sourcePath: item.sourcePath, destinationPath: item.destinationPath, status: status, error: item.error,
            skippedAfterChange: item.skipReason == .runtimeConflictResolution,
            childFailureCount: item.childFailureCount, note: item.note)
    }
}
