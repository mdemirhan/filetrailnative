// Port of the injectable file system and timer of apps/desktop/src/main/appStateStore.ts (AppStateStoreFileSystem, AppStateStoreTimer)
import Darwin
import Foundation
import os

/// The file operations the store needs, so a test can make one fail or count the writes.
public protocol StateFileSystem: Sendable {
    func exists(_ path: String) -> Bool
    func createDirectory(_ path: String) throws
    func read(_ path: String) throws -> Data
    func write(_ path: String, _ contents: String) throws
    func rename(_ from: String, _ to: String) throws
}

/// The real file system.
public struct DiskFileSystem: StateFileSystem {
    public init() {}

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func write(_ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// POSIX `rename`: replaces the target in one step.
    public func rename(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// Runs a closure once after a delay; the result cancels it.
public protocol StateTimer: Sendable {
    func schedule(afterMilliseconds delay: Int, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// The real timer: a one-shot on a background queue.
public struct DispatchStateTimer: StateTimer {
    private let queue = DispatchQueue(label: "filetrail.state-timer", qos: .utility)

    public init() {}

    public func schedule(afterMilliseconds delay: Int, _ action: @escaping @Sendable () -> Void)
        -> @Sendable () -> Void
    {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) {
            if !cancelled.withLock({ $0 }) { action() }
        }
        return { cancelled.withLock { $0 = true } }
    }
}
