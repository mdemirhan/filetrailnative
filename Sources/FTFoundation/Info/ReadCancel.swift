import Foundation

/// Tells a read in the background that its answer is no longer wanted: it checks between its steps and stops early.
/// The steps themselves aren't interrupted.
public final class ReadCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() { lock.withLock { cancelled = true } }
}
