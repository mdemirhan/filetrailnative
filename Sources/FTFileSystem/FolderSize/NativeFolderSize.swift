import CFileTrail
import Foundation
import os

/// What the folder size jobs need of a walker: `getFolderSize` and `cancelFolderSize`.
@MainActor
public protocol FolderSizeNative: AnyObject {
    /// Starts measuring `path` now, and returns what the measurement ends with. `onFinished` is handed the
    /// folders inside it measured so far, as they finish (and, when the walk is stopped or fails, those it
    /// finished before, ahead of the error). A `background` walk runs at a lower priority.
    func getFolderSize(
        _ path: String, background: Bool, onFinished: @escaping @MainActor (FinishedFolders) -> Void
    ) -> Task<FolderSizeResult, any Error>

    /// Stops the walk under way.
    func cancelFolderSize()
}

/// The folder size walker: one walk at a time. The folder size jobs start the next walk only once the last has
/// settled. The walk itself is the C walker, on four threads; the folders it finishes reach `onFinished` as they do,
/// not by polling.
@MainActor
public final class NativeFolderSize: FolderSizeNative {
    private var active: FolderWalk?

    public init() {}

    public func getFolderSize(
        _ path: String, background: Bool, onFinished: @escaping @MainActor (FinishedFolders) -> Void
    ) -> Task<FolderSizeResult, any Error> {
        assert(active == nil, "a folder size walk started while another was under way")
        guard let walk = FolderWalk(path: path, background: background) else {
            return Task { throw Self.error(ENOMEM, "folder size", path) }
        }
        active = walk
        return Task { @MainActor in
            defer {
                if active === walk {
                    active = nil
                }
            }
            return try await walk.run(onFinished: onFinished)
        }
    }

    public func cancelFolderSize() {
        active?.cancel()
    }

    nonisolated static func error(_ errnum: Int32, _ syscall: String, _ path: String) -> FolderSizeError {
        let code = Errno.nameOrUnknown(of: errnum)
        let description = Errno.description(of: errnum)
        return FolderSizeError(errnum: errnum, message: "\(code): \(description), \(syscall) '\(path)'")
    }
}

/// Tells the consumer the finished list stopped being empty. Called from a worker thread, as often as folders finish:
/// the consumer is woken at most once per `interval`, so it takes folders in batches (but only
/// when there are some) and the workers pay almost nothing for being watched.
private final class FolderWalkNotifier: @unchecked Sendable {
    static let interval: DispatchTimeInterval = .milliseconds(20)

    let continuation: AsyncStream<Void>.Continuation
    private let scheduled = OSAllocatedUnfairLock(initialState: false)

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func notify() {
        let schedule = scheduled.withLock { scheduled in
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.interval) { [self] in
            scheduled.withLock { $0 = false }
            continuation.yield()
        }
    }
}

private func notifyFolderWalk(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<FolderWalkNotifier>.fromOpaque(context).takeUnretainedValue().notify()
}

/// One walk of the C walker.
@MainActor
private final class FolderWalk {

    private nonisolated(unsafe) let walk: OpaquePointer
    private let path: String
    private let background: Bool
    private let signals: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private let notifier: Unmanaged<FolderWalkNotifier>

    init?(path: String, background: Bool) {
        self.path = path
        self.background = background
        let (signals, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.signals = signals
        signalContinuation = continuation
        let notifier = Unmanaged.passRetained(FolderWalkNotifier(continuation))
        let created = ft_folder_walk_create(path, background ? 1 : 0, notifyFolderWalk, notifier.toOpaque())
        guard let created else {
            notifier.release()
            return nil
        }
        walk = created
        self.notifier = notifier
    }

    deinit {
        ft_folder_walk_destroy(walk)
        notifier.release()
    }

    /// Safe from any thread, before or during the run.
    func cancel() {
        ft_folder_walk_cancel(walk)
    }

    private func takeFinished() -> [FinishedFolders.Folder] {
        guard let head = ft_folder_walk_take_finished(walk) else { return [] }
        defer { ft_finished_folders_free(head) }
        var folders: [FinishedFolders.Folder] = []
        var entry: UnsafeMutablePointer<ft_finished_folder>? = head
        while let current = entry {
            let stats = current.pointee.stats
            folders.append(
                FinishedFolders.Folder(
                    path: String(cString: current.pointee.path),
                    totals: FolderTotals(
                        sizeBytes: stats.size_bytes, diskBytes: stats.disk_bytes, fileCount: Int(stats.file_count),
                        folderCount: Int(stats.folder_count))))
            entry = current.pointee.next
        }
        return folders
    }

    func run(onFinished: @MainActor (FinishedFolders) -> Void) async throws -> FolderSizeResult {
        let walk = walk
        let finish = signalContinuation
        nonisolated(unsafe) let pointer = walk
        DispatchQueue.global(qos: background ? .utility : .userInitiated).async {
            ft_folder_walk_run(pointer)
            finish.finish()
        }
        for await _ in signals {
            let dirs = takeFinished()
            if !dirs.isEmpty {
                onFinished(FinishedFolders(dev: ft_folder_walk_dev(walk), dirs: dirs))
            }
        }
        let result = ft_folder_walk_get_result(walk)
        let dev = result.dev
        // Folders finished and not taken yet: every one was finished before the walk stopped, so each is whole
        // even when the walk was cancelled or failed.
        let leftover = takeFinished()
        func handOver() {
            if !leftover.isEmpty {
                onFinished(FinishedFolders(dev: dev, dirs: leftover))
            }
        }
        if result.cancelled != 0 {
            if result.errnum == 0 {
                handOver()
            }
            throw FolderSizeError.cancelled
        }
        if result.errnum != 0 {
            if result.errnum != ENOMEM {
                handOver()
            }
            throw NativeFolderSize.error(result.errnum, "folder size", path)
        }
        return FolderSizeResult(
            total: result.size_bytes, diskTotal: result.disk_bytes, fileCount: Int(result.file_count),
            folderCount: Int(result.folder_count), dev: dev, dirs: leftover)
    }
}
