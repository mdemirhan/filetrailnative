// Port of apps/desktop/src/renderer/hooks/usePreferencesSync.ts
import Foundation

/// A preference change as a window sends it: the keys that changed, with their new values.
public typealias PreferencesPatch = [String: JSONNode]

/// Keeps a window's preferences in step with the app's. Only the keys that changed since the last sync are written, so
/// two windows (explorer and Settings) never overwrite each other's edits with stale values; edits made elsewhere
/// arrive through `remote(_:)`. Bursts of changes become one write, 300 ms after the last (B-DLG-169 to 173).
@MainActor
public final class PreferencesSync {
    /// PREFERENCES_PERSIST_DEBOUNCE_MS.
    public static let debounceMilliseconds = 300.0

    /// Writes a patch; false when the write was refused.
    public typealias Write = (PreferencesPatch) -> Bool
    /// Runs the closure after the delay in milliseconds; the returned closure cancels it.
    public typealias Schedule = (Double, @escaping @MainActor () -> Void) -> () -> Void

    private let write: Write
    private let schedule: Schedule
    private var payload: PreferencesPatch = [:]
    private var synced: PreferencesPatch = [:]
    private var queued: PreferencesPatch?
    private var cancelTimer: (() -> Void)?

    public init(write: @escaping Write, schedule: @escaping Schedule) {
        self.write = write
        self.schedule = schedule
    }

    /// `diffPreferencesPatch`: the keys of `next` whose value differs from the synced one.
    public static func diff(_ synced: PreferencesPatch, _ next: PreferencesPatch) -> PreferencesPatch {
        next.filter { synced[$0.key] != $0.value }
    }

    /// Whether a write is waiting for its time.
    public var isPending: Bool { cancelTimer != nil }

    /// `markSynced`: the values loaded on start, so loading is never written back.
    public func markSynced(_ preferences: PreferencesPatch) {
        synced = preferences
    }

    /// The window's values now (each render of the original): a change starts the wait again, so a burst is one write
    /// with the latest values.
    public func changed(_ next: PreferencesPatch) {
        payload = next
        if let queued, Self.diff(queued, next).isEmpty { return }
        if queued == nil, Self.diff(synced, next).isEmpty { return }
        queued = next
        cancelTimer?()
        cancelTimer = schedule(Self.debounceMilliseconds) { [weak self] in self?.flush() }
    }

    /// Writes what differs from the last sync now.
    public func flush() {
        cancelTimer = nil
        queued = nil
        let patch = Self.diff(synced, payload)
        guard !patch.isEmpty else { return }
        let previous = synced
        synced.merge(patch) { _, new in new }
        guard !write(patch) else { return }
        // The write was refused, so nothing in it was saved. Each value that has not been sent again since goes back to
        // what was last saved, and is sent with the next change.
        for (key, value) in patch where synced[key] == value {
            synced[key] = previous[key]
        }
    }

    /// The window closes: a write that is waiting is made at once, so the latest values win.
    public func flushPending() {
        guard let cancel = cancelTimer else { return }
        cancel()
        flush()
    }

    /// A change made in another window: what belongs to one window (its tabs, its view, its panels) is never another
    /// window's to change, so those keys are dropped. The rest is taken as synced, and returned to be applied.
    @discardableResult
    public func remote(_ patch: PreferencesPatch) -> PreferencesPatch {
        let shared = patch.filter { !WindowSessionKeys.isSessionKey($0.key) }
        synced.merge(shared) { _, new in new }
        return shared
    }
}
