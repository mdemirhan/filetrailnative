// Port of the watchFolder wiring of apps/desktop/src/main/bootstrap.ts (Node's fs.watch on a folder, which on
// macOS is an FSEvents stream that reports the folder's direct children)
import CoreServices
import Darwin
import FTFoundation
import Foundation

/// An FSEvents stream on one folder. FSEvents is recursive, so, as libuv does for a watch that isn't, it
/// keeps the events of the folder itself (told of by its own name) and of its direct children.
public enum FSEventsFolderWatcher {
    /// How long FSEvents may collect events before handing them over: the watches settle on their own.
    static let latencySeconds = 0.25

    /// Starts watching `path` without blocking the caller: the path is resolved and the stream started off the
    /// main actor (either can stall on a network volume), and the callbacks run on the main actor. Returns at
    /// once a function that stops, also when the stream is not started yet. `onFail` is called as well when
    /// the stream can't be started (the folder isn't there, say).
    @MainActor
    public static func watchFolder(
        path: String, onChange: @escaping @MainActor (String?) -> Void, onFail: @escaping @MainActor () -> Void
    ) -> @Sendable () -> Void {
        let start = DeferredStart()
        Task.detached(priority: .utility) {
            if let stop = openStream(path: path, onChange: onChange, onFail: onFail) {
                start.attach(stop)
            } else if !start.isCancelled {
                DispatchQueue.main.async { MainActor.assumeIsolated { if !start.isCancelled { onFail() } } }
            }
        }
        return { start.cancel() }
    }

    /// The stop function of a stream being started elsewhere: stopping before it is there stops it on arrival.
    private final class DeferredStart: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var stop: (@Sendable () -> Void)?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func attach(_ stop: @escaping @Sendable () -> Void) {
            lock.lock()
            let late = cancelled
            if !late { self.stop = stop }
            lock.unlock()
            if late { stop() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let stop = stop
            self.stop = nil
            lock.unlock()
            stop?()
        }
    }

    /// Starts the stream on the calling thread; nil when the folder can't be watched.
    static func openStream(
        path: String, onChange: @escaping @MainActor (String?) -> Void, onFail: @escaping @MainActor () -> Void
    ) -> (@Sendable () -> Void)? {
        // The events carry real paths.
        guard let resolved = realpath(path, nil) else { return nil }
        let root = String(cString: resolved)
        free(resolved)

        let context = Context(root: root, onChange: onChange, onFail: onFail)
        var streamContext = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(context).toOpaque(), retain: nil,
            release: releaseContext, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, eventCallback, &streamContext, [root] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latencySeconds, flags)
        else {
            Unmanaged.passUnretained(context).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, context.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        let handle = StreamHandle(stream: stream, context: context)
        return { handle.stop() }
    }

    /// The stream, stopped once.
    private final class StreamHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var stream: FSEventStreamRef?
        private let context: Context

        init(stream: FSEventStreamRef, context: Context) {
            self.stream = stream
            self.context = context
        }

        func stop() {
            lock.lock()
            let stream = stream
            self.stream = nil
            lock.unlock()
            guard let stream else { return }
            context.stop()
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private final class Context: @unchecked Sendable {
        let root: String
        let queue = DispatchQueue(label: "filetrail.folder-watch")
        private let onChange: @MainActor (String?) -> Void
        private let onFail: @MainActor () -> Void
        private let lock = NSLock()
        private var stopped = false

        init(root: String, onChange: @escaping @MainActor (String?) -> Void, onFail: @escaping @MainActor () -> Void) {
            self.root = root
            self.onChange = onChange
            self.onFail = onFail
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        private var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        /// Hands what happened to the main actor, unless the watch was stopped meanwhile.
        func deliver(names: [String?], failed: Bool) {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    for name in names where !isStopped {
                        onChange(name)
                    }
                    if failed && !isStopped {
                        onFail()
                    }
                }
            }
        }
    }

    /// Not made inside `watchFolder`, which would make it main-actor isolated: FSEvents calls it on its queue.
    private static let releaseContext: @convention(c) (UnsafeRawPointer?) -> Void = { info in
        if let info { Unmanaged<Context>.fromOpaque(info).release() }
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self)
        var names: [String?] = []
        var failed = false
        for index in 0..<count {
            let flags = Int(eventFlags[index])
            // The folder itself was moved, renamed or removed, or its path changed: the watch is over.
            if flags & kFSEventStreamEventFlagRootChanged != 0 {
                failed = true
                continue
            }
            // Events were lost: anything may have changed.
            if flags
                & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped) != 0
            {
                names.append(nil)
                continue
            }
            guard let path = paths[index] as? String else { continue }
            if path == context.root {
                names.append(NodePath.basename(context.root))
            } else if NodePath.dirname(path) == context.root {
                names.append(NodePath.basename(path))
            }
        }
        if !names.isEmpty || failed {
            context.deliver(names: names, failed: failed)
        }
    }
}
