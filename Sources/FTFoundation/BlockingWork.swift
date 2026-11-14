import Foundation

/// Work that can block for long, run off the caller: reading a file on a disk that stopped answering (a network share,
/// a USB drive), or the system's clipboard while the app that copied makes what it promised. It runs on a global
/// dispatch queue, which starts more threads while some are blocked, rather than in Swift's shared pool, whose few
/// threads every task waits on: a blocked one stays blocked until the disk gives up, even once its result is no longer
/// wanted.
public enum BlockingWork {
    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
