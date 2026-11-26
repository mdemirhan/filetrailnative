import FTFoundation
import Foundation

/// One read in the background of what the Info panel and the Info Row show: the item's properties, its tags, its
/// details and signing, its disk's space, the apps it opens with. Every read of theirs goes through one of these, so
/// they all behave alike:
/// - it starts after a short wait (`InfoMetrics.fetchDelay` unless told otherwise), so moving through items quickly
///   reads only where the selection stops;
/// - asking again replaces what is waiting, and tells a read already running that its answer is no longer wanted
///   (`ReadCancel`), which it checks between its steps;
/// - only the answer to the latest ask is given, so an older read finishing late can't show what was before.
@MainActor
final class LatestRead<Key: Equatable & Sendable, Value: Sendable> {
    /// What is asked for, waiting or being read; nil once answered or stopped.
    private(set) var asked: Key?
    private var request = 0
    private var timer: DispatchWorkItem?
    private var running: ReadCancel?

    /// Whether an ask waits for its read to start.
    var isWaiting: Bool { timer != nil }
    /// Whether something is asked for and not answered.
    var isAsking: Bool { asked != nil }

    /// Asks for `key`, read by `read` (blocking work, run off the main thread at `qos`); `answered` gets the answer
    /// if no other ask came after it.
    func ask(
        _ key: Key, after delay: Double = InfoMetrics.fetchDelay, qos: DispatchQoS.QoSClass = .userInitiated,
        read: @escaping @Sendable (ReadCancel) -> Value, answered: @escaping @MainActor (Value) -> Void
    ) {
        askAsync(
            key, after: delay, read: { cancel in await BlockingWork.run(qos: qos) { read(cancel) } }, answered: answered
        )
    }

    /// `ask` for a read that is already asynchronous (macOS's answer of the apps a file opens with).
    func askAsync(
        _ key: Key, after delay: Double = InfoMetrics.fetchDelay,
        read: @escaping @Sendable (ReadCancel) async -> Value, answered: @escaping @MainActor (Value) -> Void
    ) {
        stop()
        asked = key
        request += 1
        let current = request
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.request == current else { return }
                self.timer = nil
                let cancel = ReadCancel()
                self.running = cancel
                Task { @MainActor [weak self] in
                    let value = await read(cancel)
                    guard let self, self.request == current, !cancel.isCancelled else { return }
                    self.running = nil
                    self.asked = nil
                    answered(value)
                }
            }
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Nothing is wanted any more: what waits doesn't start, and what runs is told so its answer is dropped.
    func stop() {
        request += 1
        timer?.cancel()
        timer = nil
        running?.cancel()
        running = nil
        asked = nil
    }

    isolated deinit {
        timer?.cancel()
        running?.cancel()
    }
}
