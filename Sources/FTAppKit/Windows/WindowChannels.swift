// Port of apps/desktop/src/main/windowIpcHandlers.ts: what knows which window is asking
import FTFileSystem
import FTFoundation
import Foundation

/// What a window says when Merge All Windows asks for its tabs.
public struct WindowTabsAnswer: Equatable, Sendable {
    public var tabs: [OpenTabPreference]
    /// Something is open in it that closing would lose (a sheet, a dialog, a name being edited).
    public var busy: Bool

    public init(tabs: [OpenTabPreference], busy: Bool) {
        self.tabs = tabs
        self.busy = busy
    }
}

/// Asks windows for their tabs as they are now, rather than as last saved, and hands over each answer from the window
/// asked (`WindowTabsRequests`).
@MainActor
public final class WindowTabsRequests {
    /// TABS_REQUEST_TIMEOUT_MS: a window that doesn't answer in this time stays open.
    public static let timeoutMilliseconds: Double = 2_000

    private struct Pending {
        let windowID: Int
        let resolve: (WindowTabsAnswer?) -> Void
    }

    private let scheduler: any FolderWatchScheduler
    private var nextRequestID = 1
    private var pending: [String: Pending] = [:]

    public init(scheduler: any FolderWatchScheduler = DispatchFolderWatchScheduler()) {
        self.scheduler = scheduler
    }

    /// Asks the window `windowID`, through `send` (which is given the request's id and throws when the window is
    /// gone). Nil when it doesn't answer in time, or can't be asked.
    public func ask(
        windowID: Int, timeoutMilliseconds: Double = timeoutMilliseconds, send: (String) throws -> Void
    ) async -> WindowTabsAnswer? {
        await withCheckedContinuation { continuation in
            let requestID = "merge-\(nextRequestID)"
            nextRequestID += 1
            let cancelTimer = scheduler.schedule(afterMilliseconds: timeoutMilliseconds) { [weak self] in
                self?.settle(requestID, nil)
            }
            pending[requestID] = Pending(windowID: windowID) { answer in
                cancelTimer()
                continuation.resume(returning: answer)
            }
            do {
                try send(requestID)
            } catch {
                // The window went away as it was asked.
                settle(requestID, nil)
            }
        }
    }

    /// The answer of the window `windowID`; one from any other window than the one asked is not heard.
    public func answer(from windowID: Int?, requestID: String, _ answer: WindowTabsAnswer) {
        if let request = pending[requestID], request.windowID == windowID {
            settle(requestID, answer)
        }
    }

    private func settle(_ requestID: String, _ answer: WindowTabsAnswer?) {
        let request = pending.removeValue(forKey: requestID)
        request?.resolve(answer)
    }
}

/// A preference change, with only the keys the whole app shares, and the window it came from.
public struct PreferencesChange: Equatable, Sendable {
    public var patch: [String: JSONNode]
    public var senderID: Int?
}

/// Preferences as a window sees them: an explorer window sees the app's with its own session on top, and what it
/// changes of its session stays its own. Other windows (Settings) see and change the app's only. Only the keys the
/// whole app shares are told to the other windows (`app:getPreferences`, `app:updatePreferences`).
@MainActor
public final class WindowPreferenceChannel {
    private let store: AppStateStore
    /// The id of the explorer window a window belongs to; nil for other windows.
    private let explorerWindowID: (Int?) -> String?
    /// Told of every change, with only the keys the whole app shares.
    public var onPreferencesChanged: (AppPreferences, PreferencesChange) -> Void

    public init(
        store: AppStateStore, explorerWindowID: @escaping (Int?) -> String?,
        onPreferencesChanged: @escaping (AppPreferences, PreferencesChange) -> Void = { _, _ in }
    ) {
        self.store = store
        self.explorerWindowID = explorerWindowID
        self.onPreferencesChanged = onPreferencesChanged
    }

    public func preferences(for senderID: Int?) -> AppPreferences {
        explorerWindowID(senderID).map(store.windowPreferences) ?? store.preferences()
    }

    @discardableResult
    public func update(_ patch: [String: JSONNode], from senderID: Int?) -> AppPreferences {
        let windowID = explorerWindowID(senderID)
        let preferences =
            windowID.map { store.updateWindowPreferences($0, patch) } ?? store.updatePreferences(patch)
        // What belongs to one window (its tabs, panels, column widths) stays with it.
        let shared = patch.filter { !WindowSessionKeys.isSessionKey($0.key) }
        onPreferencesChanged(store.preferences(), PreferencesChange(patch: shared, senderID: senderID))
        return preferences
    }
}

/// Copy or Cut, as the app's clipboard holds it (`CopyPasteClipboard`).
public enum CopyPasteMode: String, Sendable, Equatable {
    case copy, cut
}

public struct ClipboardSourceEntry: Equatable, Sendable {
    public var kind: FTFoundation.EntryKind
    public var isSymlink: Bool
    public var isExecutable: Bool?

    public init(kind: FTFoundation.EntryKind, isSymlink: Bool, isExecutable: Bool? = nil) {
        self.kind = kind
        self.isSymlink = isSymlink
        self.isExecutable = isExecutable
    }
}

public enum CopyPasteClipboard: Equatable, Sendable {
    case empty
    case ready(
        mode: CopyPasteMode, sourcePaths: [String], sourceEntries: [String: ClipboardSourceEntry], capturedAt: String)

    public var capturedAt: String? {
        if case .ready(_, _, _, let capturedAt) = self { return capturedAt }
        return nil
    }
}

/// What Copy or Cut put on the clipboard, in whichever window: every window pastes it (`app:getClipboard`,
/// `app:setClipboard`).
@MainActor
public final class SharedClipboard {
    public private(set) var contents: CopyPasteClipboard = .empty
    /// Tells every window but the one that changed it (`filetrail:clipboardChanged`).
    public var sendToOtherWindows: (_ senderID: Int?, CopyPasteClipboard) -> Void

    public init(sendToOtherWindows: @escaping (Int?, CopyPasteClipboard) -> Void = { _, _ in }) {
        self.sendToOtherWindows = sendToOtherWindows
    }

    /// Puts `clipboard` on it. With `follows`, only while it still holds what was captured then: the window that moved
    /// an item follows it on the clipboard, but not after another window copied something else. False when it
    /// didn't take it.
    @discardableResult
    public func set(_ clipboard: CopyPasteClipboard, follows: String? = nil, from senderID: Int?) -> Bool {
        if let follows {
            guard let current = contents.capturedAt, current.utf16.elementsEqual(follows.utf16) else { return false }
        }
        contents = clipboard
        sendToOtherWindows(senderID, clipboard)
        return true
    }
}
