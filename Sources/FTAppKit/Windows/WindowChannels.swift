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

/// What Copy, Cut and the Adds put on the clipboard, in whichever window: every window pastes it. A clipboard built
/// up with Add that a Copy or Cut replaced is kept too, once, to be put back.
@MainActor
public final class SharedClipboard {
    public private(set) var contents: CopyPasteClipboard = .empty
    /// The clipboard built with Add that the last Copy or Cut replaced: Put Back brings it back. Gone at the next
    /// Copy or Cut, a Clear Clipboard, or a quit.
    public private(set) var previous: CopyPasteClipboard?
    /// Tells every window but the one that changed it.
    public var sendToOtherWindows: (_ senderID: Int?, CopyPasteClipboard) -> Void

    public init(sendToOtherWindows: @escaping (Int?, CopyPasteClipboard) -> Void = { _, _ in }) {
        self.sendToOtherWindows = sendToOtherWindows
    }

    /// Puts `clipboard` on it. With `follows`, only while it still holds what was captured then: the window that moved
    /// an item follows it on the clipboard, but not after another window copied something else. False when it
    /// didn't take it. An emptied clipboard has nothing to put back.
    @discardableResult
    public func set(_ clipboard: CopyPasteClipboard, follows: String? = nil, from senderID: Int?) -> Bool {
        if let follows {
            guard let current = contents.capturedAt, current.utf16.elementsEqual(follows.utf16) else { return false }
        }
        if !clipboard.hasItems && follows == nil { previous = nil }
        contents = clipboard
        sendToOtherWindows(senderID, clipboard)
        return true
    }

    /// A Copy or Cut: `clipboard` takes the place of what is there, which is kept to be put back when it was built
    /// with Add. Answers what was kept, if anything.
    @discardableResult
    public func replace(with clipboard: CopyPasteClipboard, from senderID: Int?) -> CopyPasteClipboard? {
        previous = contents.isGrown ? contents : nil
        contents = clipboard
        sendToOtherWindows(senderID, clipboard)
        return previous
    }

    /// Put Back: the clipboard kept takes the place of the one there now, which is kept in turn, so a second Put
    /// Back swaps them again. False with nothing kept.
    @discardableResult
    public func putBack(from senderID: Int?) -> Bool {
        guard let kept = previous else { return false }
        previous = contents.hasItems ? contents : nil
        contents = kept
        sendToOtherWindows(senderID, kept)
        return true
    }

    /// What a write or another app did to the items follows on the clipboard kept as well (`ClipboardRules`), so it
    /// is put back where its items are now.
    public func followKept(_ follow: (CopyPasteClipboard) -> CopyPasteClipboard) {
        guard let kept = previous else { return }
        let followed = follow(kept)
        previous = followed.hasItems ? followed : nil
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
    /// Where a folder that took a view along really is, its links resolved (`followMoves`); a test gives its own.
    private let realPath: (String) -> String

    /// With no store, as in tests, the views are kept for the run only.
    public init(store: AppStateStore? = nil, realPath: @escaping (String) -> String = FolderIdentity.realPath) {
        self.store = store
        self.realPath = realPath
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

    /// The view the folder at `path` uses, found by the path alone: a look in memory, with no call to the disk, so
    /// opening a folder costs nothing more however many views are saved.
    public func use(for path: String) -> FolderViewUse? {
        guard !views.isEmpty, !path.isEmpty else { return nil }
        return views.use(for: path)
    }

    /// Folders renamed or moved by the app (and by its Undo): their views, and the views inside them, go along, to
    /// another disk too, as nothing ties a view to a disk. A view is found by its folder's real path, and a move may
    /// name where it went through a link (a folder dropped on a link to a folder): where a view goes along, the disk
    /// is asked once where that is. A move that carries no view asks nothing.
    public func followMoves(_ moves: [PathMove]) {
        guard !moves.isEmpty else { return }
        update(from: nil) { views in
            views.moved(moves.map { (from: $0.from, to: $0.to) }, destination: realPath)
        }
    }
}
