// What knows which window is asking
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

/// A preference change: the keys set that the whole app shares, and the window it came from.
public struct PreferencesChange: Equatable, Sendable {
    public var keys: Set<PreferenceKey>
    public var senderID: Int?

    public init(keys: Set<PreferenceKey>, senderID: Int?) {
        self.keys = keys
        self.senderID = senderID
    }
}

/// Preferences as a window sees them: an explorer window sees the app's with its own session on top, and what it
/// changes of its session stays its own. Other windows (Settings) see and change the app's only. Only the keys the
/// whole app shares are told to the other windows.
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

    /// A change made in the window `senderID` (`$0.theme = .dark`); every window is told of it, with the keys it set
    /// that the whole app shares.
    @discardableResult
    public func update(from senderID: Int?, _ change: (inout EditedPreferences) -> Void) -> AppPreferences {
        var written: [PreferenceKey] = []
        let preferences =
            if let windowID = explorerWindowID(senderID) {
                store.updateWindow(windowID) {
                    change(&$0)
                    written = $0.written
                }
            } else {
                store.update {
                    change(&$0)
                    written = $0.written
                }
            }
        // What belongs to one window (its tabs, panels) stays with it.
        let shared = Set(written.filter { !$0.isWindowSessionKey })
        onPreferencesChanged(store.preferences(), PreferencesChange(keys: shared, senderID: senderID))
        return preferences
    }

}

/// What Copy or Cut put on the clipboard, in whichever window: every window pastes it.
@MainActor
public final class SharedClipboard {
    public private(set) var contents: CopyPasteClipboard = .empty
    /// Tells every window but the one that changed it.
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

/// Every folder's view, as every window sees it (View ▸ Folder View): saved in the store, and told to every window when
/// it changes, so a pane on a folder whose view was saved elsewhere shows it.
@MainActor
public final class SharedFolderViews {
    private let store: AppStateStore?
    public private(set) var views: FolderViews
    /// Told of every change, with the window it came from.
    public var onChanged: (_ senderID: Int?) -> Void = { _ in }
    /// Posted after every change, for what isn't a window (Settings' list).
    public static let didChange = Notification.Name("FileTrailFolderViewsChanged")
    /// The disk, the file ID and whether a folder is there, read from the disk; tests put their own.
    var identity = Identity.disk

    struct Identity {
        var volume: (String) -> String?
        var fileID: (String) -> UInt64?
        var isFolder: (String) -> Bool

        static var disk: Identity {
            Identity(
                volume: FolderIdentity.volume(of:), fileID: FolderIdentity.fileID(of:),
                isFolder: FolderIdentity.isFolder)
        }
    }

    /// With no store, as in tests, the views are kept for the run only.
    public init(store: AppStateStore? = nil) {
        self.store = store
        views = store?.folderViews() ?? FolderViews()
    }

    /// Changes the views; every window is told, when something changed.
    @discardableResult
    public func update(from senderID: Int?, _ change: (inout FolderViews) -> Void) -> FolderViews {
        var changed = views
        change(&changed)
        guard changed != views else { return views }
        views = store?.updateFolderViews { $0 = changed } ?? changed
        onChanged(senderID)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return views
    }

    /// The view the folder at `path` (canonical) uses. A view kept with a disk is checked against the folder's disk; a
    /// folder with no view of its own takes over one whose folder is gone and that has its file ID (it was renamed or
    /// moved outside the app).
    public func use(for path: String) -> FolderViewUse? {
        guard !views.isEmpty, !path.isEmpty else { return nil }
        // Only where a view has this folder's file ID is its disk read and its folder looked for.
        if views.own(path) == nil, let fileID = identity.fileID(path),
            views.byPath.values.contains(where: { $0.fileID == fileID })
        {
            let volume = identity.volume(path)
            var adopted = views
            if adopted.adopt(path: path, volume: volume, fileID: fileID, exists: identity.isFolder) {
                update(from: nil) { $0 = adopted }
            }
        }
        guard let found = views.use(for: path) else { return nil }
        guard found.view.volume != nil else { return found }
        return views.use(for: path, volume: identity.volume(path))
    }

    /// Folders renamed or moved by the app (and by its Undo): their views, and the views inside them, go along.
    public func followMoves(_ moves: [PathMove]) {
        guard !moves.isEmpty else { return }
        update(from: nil) { views in
            // The deepest first, so a folder moved out of a folder renamed in the same operation goes where it went.
            for move in moves.sorted(by: { $0.from.utf16.count > $1.from.utf16.count }) {
                views.moved(from: move.from, to: move.to)
            }
        }
    }
}
