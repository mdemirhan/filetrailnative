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

/// A preference change, with only the keys the whole app shares, and the window it came from.
public struct PreferencesChange: Equatable, Sendable {
    public var patch: [String: JSONNode]
    public var senderID: Int?
}

/// A window that follows the app's preferences while it is open: told each change, with only the keys the whole app
/// shares (`filetrail:preferencesChanged`). An explorer window conforms to redraw with a new theme or accent and to
/// follow the other settings.
@MainActor
public protocol PreferenceChangeReceiver: AnyObject {
    func preferencesChanged(_ preferences: AppPreferences, _ change: PreferencesChange)
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

/// Copy or Cut, as the app's clipboard holds it (`CopyPasteClipboard`, FTFoundation's `ClipboardMode`).
public typealias CopyPasteMode = ClipboardMode

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
