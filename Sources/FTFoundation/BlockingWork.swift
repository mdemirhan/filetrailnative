import Foundation

/// Work that can block for long, run off the caller: reading a file on a disk that stopped answering (a network share,
/// a USB drive), or the system's clipboard while the app that copied makes what it promised. It runs on a global
/// dispatch queue, which starts more threads while some are blocked, rather than in Swift's shared pool, whose few
/// threads every task waits on: a blocked one stays blocked until the disk gives up, even once its result is no longer
/// wanted.
///
/// The queue's threads are many but not endless (about 64 in all): a disk that never answers still keeps one per read
/// waiting on it, just not one of the pool's. The work is handed over once, whole, so a long walk pays one hop.
public enum BlockingWork {
    /// `qos` is the priority the work runs at: `.utility` for what may wait behind the rest.
    public static func run<T: Sendable, Failure: Error>(
        qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () throws(Failure) -> T
    ) async throws(Failure) -> T {
        let result: Result<T, Failure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: Result { () throws(Failure) -> T in try work() })
            }
        }
        return try result.get()
    }
}
