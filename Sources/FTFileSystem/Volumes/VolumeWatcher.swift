// Port of createVolumeWatcher in apps/desktop/src/main/volumes.ts
import Dispatch
import Foundation

/// The disks mounted besides the startup disk, and word of each change to them. macOS mounts every disk at
/// /Volumes/<name>, so a change to that folder is a disk mounted or unmounted; the list itself comes from the
/// mount table (see `VolumeListing`).
@MainActor
public final class VolumeWatcher {
    /// Mounting a disk can change /Volumes several times in a row (its folder made, then the disk put on
    /// it): the list is read once they settle.
    public static let settleMilliseconds = 250

    public struct Dependencies {
        public var listVolumes: () throws -> [Volume]
        /// Calls `onChange` whenever the folder changes; returns a function that stops watching.
        public var watchVolumesFolder: (_ onChange: @escaping @MainActor () -> Void) -> () -> Void
        public var onVolumesChanged: ([Volume]) -> Void
        public var schedule: (_ milliseconds: Int, _ callback: @escaping @MainActor () -> Void) -> Int
        public var cancel: (Int) -> Void

        public init(
            listVolumes: @escaping () throws -> [Volume] = { VolumeListing.listVolumes() },
            watchVolumesFolder: @escaping (_ onChange: @escaping @MainActor () -> Void) -> () -> Void =
                VolumeWatcher.watchVolumesDirectory,
            onVolumesChanged: @escaping ([Volume]) -> Void,
            schedule: @escaping (_ milliseconds: Int, _ callback: @escaping @MainActor () -> Void) -> Int =
                VolumeWatcher.dispatchSchedule,
            cancel: @escaping (Int) -> Void = VolumeWatcher.dispatchCancel
        ) {
            self.listVolumes = listVolumes
            self.watchVolumesFolder = watchVolumesFolder
            self.onVolumesChanged = onVolumesChanged
            self.schedule = schedule
            self.cancel = cancel
        }
    }

    private let dependencies: Dependencies
    private var volumes: [Volume] = []
    private var pending: Int?
    private var stopWatching: (() -> Void)?

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        volumes = read()
        stopWatching = dependencies.watchVolumesFolder { [weak self] in
            self?.folderChanged()
        }
    }

    public func getVolumes() -> [Volume] { volumes }

    /// Reads the list again now, telling of a change: for a mount the folder watch missed, a window coming to
    /// the front, an eject or a mounted disk image.
    public func refresh() {
        let next = read()
        if next == volumes { return }
        volumes = next
        dependencies.onVolumesChanged(volumes)
    }

    public func stop() {
        if let pending {
            dependencies.cancel(pending)
            self.pending = nil
        }
        stopWatching?()
        stopWatching = nil
    }

    private func read() -> [Volume] {
        do {
            return Volume.sorted(try dependencies.listVolumes())
        } catch {
            return []
        }
    }

    private func folderChanged() {
        if let pending { dependencies.cancel(pending) }
        pending = dependencies.schedule(Self.settleMilliseconds) { [weak self] in
            self?.pending = nil
            self?.refresh()
        }
    }

    // MARK: Real timers and folder watch

    private final class Timers: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int: DispatchWorkItem] = [:]
        private var last = 0

        func add(_ item: DispatchWorkItem) -> Int {
            lock.lock()
            defer { lock.unlock() }
            last += 1
            items[last] = item
            return last
        }

        func remove(_ handle: Int) -> DispatchWorkItem? {
            lock.lock()
            defer { lock.unlock() }
            return items.removeValue(forKey: handle)
        }
    }

    nonisolated private static let timers = Timers()

    public nonisolated static func dispatchSchedule(
        _ milliseconds: Int, _ callback: @escaping @MainActor () -> Void
    ) -> Int {
        let item = DispatchWorkItem { MainActor.assumeIsolated { callback() } }
        let handle = timers.add(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
        return handle
    }

    public nonisolated static func dispatchCancel(_ handle: Int) {
        timers.remove(handle)?.cancel()
    }

    /// `fs.watch("/Volumes")`: a write to the folder is a disk mounted or unmounted.
    public nonisolated static func watchVolumesDirectory(
        _ onChange: @escaping @MainActor () -> Void
    ) -> () -> Void {
        let descriptor = open("/Volumes", O_EVTONLY)
        guard descriptor >= 0 else { return {} }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return { source.cancel() }
    }
}
