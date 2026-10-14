// Port of packages/native-fs/index.js (the single-flight wrapper) over the walker of native_foldersize.c
import CFileTrail
import Foundation

/// What the folder size jobs need of a walker: the original's `getFolderSize` and `cancelFolderSize`.
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

/// The folder size walker. Calls are served one at a time, in the order they came: the first starts at once
/// (so an immediate cancel stops it), later ones wait for it to settle. The walk itself is the C walker, on
/// four threads; the folders it finishes reach `onFinished` as they do, not by polling.
@MainActor
public final class NativeFolderSize: FolderSizeNative {
    @MainActor private final class Deferred {
        private var outcome: Result<FolderSizeResult, any Error>?
        private var continuation: CheckedContinuation<FolderSizeResult, any Error>?

        func resolve(_ outcome: Result<FolderSizeResult, any Error>) {
            if let continuation {
                self.continuation = nil
                continuation.resume(with: outcome)
            } else {
                self.outcome = outcome
            }
        }

        func value() async throws -> FolderSizeResult {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    private struct Waiting {
        var path: String
        var background: Bool
        var onFinished: @MainActor (FinishedFolders) -> Void
        var deferred: Deferred
    }

    private var active: FolderWalk?
    private var waiting: [Waiting] = []

    public init() {}

    public func getFolderSize(
        _ path: String, background: Bool, onFinished: @escaping @MainActor (FinishedFolders) -> Void
    ) -> Task<FolderSizeResult, any Error> {
        if active == nil {
            return start(path, background: background, onFinished: onFinished)
        }
        let deferred = Deferred()
        waiting.append(Waiting(path: path, background: background, onFinished: onFinished, deferred: deferred))
        return Task { try await deferred.value() }
    }

    public func cancelFolderSize() {
        active?.cancel()
    }

    private func start(
        _ path: String, background: Bool, onFinished: @escaping @MainActor (FinishedFolders) -> Void
    ) -> Task<FolderSizeResult, any Error> {
        guard let walk = FolderWalk(path: path, background: background) else {
            return Task { throw Self.error(ENOMEM, "folder size", path) }
        }
        active = walk
        return Task { @MainActor in
            let outcome: Result<FolderSizeResult, any Error>
            do {
                outcome = .success(try await walk.run(onFinished: onFinished))
            } catch {
                outcome = .failure(error)
            }
            if active === walk {
                active = nil
            }
            if !waiting.isEmpty {
                let next = waiting.removeFirst()
                let task = start(next.path, background: next.background, onFinished: next.onFinished)
                Task { @MainActor in next.deferred.resolve(await task.result) }
            }
            return try outcome.get()
        }
    }

    nonisolated static func error(_ errnum: Int32, _ syscall: String, _ path: String) -> FolderSizeError {
        let code = String(cString: ft_errno_code(errnum))
        let description = String(cString: strerror(errnum))
        return FolderSizeError(code: code, message: "\(code): \(description), \(syscall) '\(path)'")
    }

    /// One item as measuring its folder counts it (`nativeItemSize`), so what a delete took off the folders
    /// that held it is what they counted of it.
    public nonisolated static func itemSize(_ path: String) async throws -> ItemSize {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var item = ft_item_size()
                let errnum = ft_item_size_of(path, &item)
                if errnum != 0 {
                    continuation.resume(throwing: error(errnum, "item size", path))
                    return
                }
                let kind: ItemSize.Kind =
                    switch item.kind {
                    case FT_ITEM_FILE: .file
                    case FT_ITEM_FOLDER: .folder
                    default: .other
                    }
                continuation.resume(
                    returning: ItemSize(kind: kind, sizeBytes: item.size_bytes, diskBytes: item.disk_bytes, dev: item.dev))
            }
        }
    }
}

/// Tells the consumer the finished list stopped being empty. Called from a worker thread.
private final class FolderWalkNotifier: @unchecked Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

private func notifyFolderWalk(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<FolderWalkNotifier>.fromOpaque(context).takeUnretainedValue().continuation.yield()
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
