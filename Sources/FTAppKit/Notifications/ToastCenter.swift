// Port of the toast state of apps/desktop/src/renderer/hooks/useDialogStore.ts and hooks/useExplorerActions.ts
// (pushToast, dismissToast) and the timers of components/ToastViewport.tsx
import FTFoundation
import Foundation

/// The notifications of one window: at most three at once, each gone after four seconds. Nothing is kept while
/// "Show notifications" is off.
@MainActor
final class ToastCenter {
    private(set) var entries: [ToastEntry] = []
    /// Told when the list changed: `arrived` is the id of a notification that has just been added, if one was.
    var onChange: (_ arrived: String?) -> Void = { _ in }
    /// Whether notifications are on (`notificationsEnabled`).
    var isEnabled: () -> Bool = { true }
    /// The clock in milliseconds, and how a timer is made (tests give their own).
    var now: () -> Double = { Date().timeIntervalSinceReferenceDate * 1000 }
    var schedule: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel = { delay, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return Cancel { item.cancel() }
    }

    struct Cancel {
        let cancel: () -> Void
        init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    }

    private var timers: [String: (expiresAt: Double, cancel: Cancel)] = [:]
    private var counter = 0

    /// `pushToast`.
    @discardableResult
    func push(_ kind: ToastKind, title: String, message: String? = nil) -> String? {
        guard isEnabled() else { return nil }
        counter += 1
        let id = "toast-\(counter)"
        let entry = Toasts.entry(id: id, kind: kind, title: title, message: message, now: now())
        entries = Toasts.enqueue(entries, entry)
        syncTimers()
        onChange(id)
        return id
    }

    /// `dismissToast`.
    func dismiss(_ id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        syncTimers()
        onChange(nil)
    }

    /// Notifications were turned off: those showing go.
    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        syncTimers()
        onChange(nil)
    }

    /// One timer for each notification showing, each set for the time it expires; those that left have none.
    private func syncTimers() {
        let showing = Set(entries.map(\.id))
        for (id, timer) in timers where !showing.contains(id) {
            timer.cancel.cancel()
            timers[id] = nil
        }
        for entry in entries where timers[entry.id]?.expiresAt != entry.expiresAt {
            timers[entry.id]?.cancel.cancel()
            let delay = max(0, entry.expiresAt - now()) / 1000
            let id = entry.id
            timers[id] = (entry.expiresAt, schedule(delay) { [weak self] in
                self?.timers[id] = nil
                self?.dismiss(id)
            })
        }
    }
}
