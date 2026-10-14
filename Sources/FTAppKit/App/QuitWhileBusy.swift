// Port of apps/desktop/src/main/quitWhileBusy.ts
import Foundation

/// What kind of change the running operation is making, in the words a person would use (`WriteOperationKind`). The
/// write coordinator (P3-05) reports its own kind through the `QuitCoordinator`'s `activeOperation` hook.
public enum BusyOperationKind: String, Sendable, CaseIterable {
    case copy
    case move
    case trash
    case delete
    case rename
    case batchRename = "batch_rename"
    case newFolder = "new_folder"
    case undo
    case emptyTrash = "empty_trash"
}

/// What stops a running operation: quitting, or closing the last explorer window (the one it shows in; the app stays
/// open).
public enum StopTrigger: Sendable {
    case quit
    case close
}

/// The question asked before an operation is stopped.
public struct StopQuestion: Equatable, Sendable {
    public var message: String
    public var detail: String
    /// In order: the first is the default and what Escape picks.
    public var buttons: [String]
}

public enum QuitWhileBusy {
    /// KEEP_WORKING_BUTTON_INDEX and STOP_BUTTON_INDEX.
    public static let keepWorkingButtonIndex = 0
    public static let stopButtonIndex = 1

    /// `stopQuestionButtons`.
    public static func buttons(_ trigger: StopTrigger, kind: BusyOperationKind? = nil) -> [String] {
        // Finder empties the Trash: quitting doesn't stop it.
        if kind == .emptyTrash {
            return ["Keep Working", trigger == .quit ? "Quit" : "Close"]
        }
        return ["Keep Working", trigger == .quit ? "Stop and Quit" : "Stop and Close"]
    }

    /// `shouldOpenWindowOnActivate`: clicking the Dock icon with no explorer window open opens one, as Finder does,
    /// even while Settings or Help is open; but not while quitting waits for an operation to stop: that window would
    /// be closed again moments later.
    public static func shouldOpenWindowOnActivate(shutdownInProgress: Bool, explorerWindowCount: Int) -> Bool {
        !shutdownInProgress && explorerWindowCount == 0
    }

    /// `describeQuitWhileBusy`: what to ask before quitting or closing the window stops a running operation. A rename
    /// of one item or a new folder is over in a moment, so it is simply waited for: there is nothing to ask. A rename
    /// of several can take a while (thousands of items on a network disk).
    public static func describe(_ kind: BusyOperationKind, trigger: StopTrigger = .quit) -> (
        message: String, detail: String
    )? {
        let stops =
            trigger == .quit
            ? "If you quit now, it stops after the current item."
            : "If you close the window now, it stops after the current item."
        switch kind {
        case .copy:
            return (
                "A copy is still in progress.",
                "\(stops) Items already copied stay where they are; a folder still being copied isn't left half copied."
            )
        case .move:
            // A folder moved to another disk is copied whole, then its original removed: stopped during the
            // removal, the copy is in place and part of the original is still there.
            return (
                "A move is still in progress.",
                "\(stops) Items already moved stay in their new place, and the rest stay where they were. A folder being moved to another disk may already be there in full, with some of its items still in the old place too."
            )
        case .trash:
            return (
                "Items are still being moved to the Trash.",
                "\(stops) Items already in the Trash stay there."
            )
        case .delete:
            return ("Items are still being deleted.", "\(stops) Items already deleted can't be recovered.")
        case .undo:
            return ("An Undo is still in progress.", "\(stops) What was already undone stays undone.")
        case .batchRename:
            return (
                "Items are still being renamed.",
                "\(stops) Items already renamed keep their new names; the rest keep their old ones."
            )
        case .emptyTrash:
            // Finder empties the Trash and goes on after File Trail quits; closing a window has nothing to do with it.
            return trigger == .quit
                ? (
                    "The Trash is still being emptied.",
                    "Finder goes on emptying it after File Trail quits."
                ) : nil
        case .rename, .newFolder:
            return nil
        }
    }

    /// The whole question for an operation, or nil when there is nothing worth asking.
    public static func question(_ kind: BusyOperationKind, trigger: StopTrigger) -> StopQuestion? {
        describe(kind, trigger: trigger).map {
            StopQuestion(message: $0.message, detail: $0.detail, buttons: buttons(trigger, kind: kind))
        }
    }
}
