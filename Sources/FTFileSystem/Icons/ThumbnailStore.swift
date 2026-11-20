import FTFoundation
import Foundation

/// Previews of the content of files, for icon view and the Previews view. A file is told from another by its path
/// byte for byte: two files whose names differ only in how an accent is spelled each have their preview and their
/// load.
///
/// Previews are asked for at `pixelSize(forIconSize:)` on their longest side: twice the icon, for a Retina display.
/// Previews are kept in memory only (Quick Look has its own cache on disk), most recently used last. 500 cover
/// several screens of icon view; older ones are asked for again. A store of large previews also keeps under a memory
/// limit, counting each preview by the bytes of its picture.
@MainActor
public final class ThumbnailStore {
    /// Previews for icons up to 64 points.
    public nonisolated static let pixelSize = 128
    /// Previews for larger icons.
    public nonisolated static let largePixelSize = 256

    /// The preview size that stays sharp for icons `iconSize` points square on a Retina display.
    public nonisolated static func pixelSize(forIconSize iconSize: Double) -> Int {
        iconSize <= Double(pixelSize) / 2 ? pixelSize : largePixelSize
    }

    public nonisolated static let maxEntries = 500

    private struct Cached {
        /// The file's state the preview was made from; nil when the file could not be read.
        var version: String?
        /// Nil when Quick Look has no preview for the file.
        var picture: ThumbnailPicture?
        /// The size it was asked for at.
        var size: Int
        /// Whether it answers a request at `size`: a picture serves any size up to its own; none at one size says
        /// nothing of a smaller size, where there may be one (Quick Look refuses pictures too large).
        func covers(_ size: Int) -> Bool {
            picture != nil ? self.size >= size : self.size <= size
        }
        /// The listing the preview was last checked against the file for; nil once the file may have changed since,
        /// so that it is checked again the next time it is asked for.
        var checkedFor: AnyObject?
        /// The number of the load that made it: of two loads, the one begun later read the file later.
        var loadNumber: Int
    }

    /// A load under way, told when its file may have changed after it was read. Another request for the file at no
    /// larger size and for the same listing waits for it rather than asking again.
    @MainActor
    private final class PendingLoad {
        var fileChanged = false
        /// The size it asks for, and the listing it checks the file for.
        let size: Int
        let listing: AnyObject
        /// Its job's number in the queue; whether it was taken back: out of the queue, or told to stop.
        var job = 0
        var isRemoved = false
        /// Whether it is wanted only ahead of need: the next page of the Previews view.
        var isAhead: Bool
        /// Those waiting for it, each with its own handle.
        var waiters: [Waiter] = []

        init(size: Int, listing: AnyObject, isAhead: Bool) {
            self.size = size
            self.listing = listing
            self.isAhead = isAhead
        }

        /// Whether a request at `size` for `listing` is answered by this load.
        func serves(size: Int, listing: AnyObject) -> Bool {
            !isRemoved && !fileChanged && self.size >= size && self.listing === listing
        }

        /// Whether its picture can be shown meanwhile to a request at `size` for another listing: the same file, read
        /// a moment before that listing was. The file is then checked for that listing (`Waiter.recheck`).
        func showsMeanwhile(size: Int) -> Bool {
            !isRemoved && !fileChanged && self.size >= size
        }
    }

    /// One request waiting for a load.
    @MainActor
    private final class Waiter {
        let completion: @MainActor (ThumbnailPicture?) -> Void
        var cancelled = false
        /// The request it made, when the load it waits for is another listing's: once that load answers, the file is
        /// checked for this one.
        var recheck: (kind: IconEntryKind, size: Int, listing: AnyObject, ahead: Bool)?
        /// That check, once asked for.
        var followUp: LoadHandle?

        init(_ completion: @escaping @MainActor (ThumbnailPicture?) -> Void) {
            self.completion = completion
        }
    }

    private struct WeakLoad {
        weak var load: PendingLoad?
    }

    /// The pixels a preview `size` points across is asked for at on a screen of `scale`: in whole steps of 256, at
    /// most `limit` (the screen's longer side). The previews follow the pane's size, so the steps keep a window being
    /// resized from asking for each one again every few points.
    public nonisolated static func pixelSize(forPreviewSize size: Double, scale: Double = 2, limit: Int) -> Int {
        let stepped = max(1, Int((size * scale / 256).rounded(.up))) * 256
        return max(256, min(limit, stepped))
    }

    private let provider: any ThumbnailProviding
    private let queue: ThumbnailLoadQueue
    private var cache: LRUCache<DiskPath, Cached>
    /// The bytes the previews kept may take at most (nil: only the count is limited), and what they take now.
    private let memoryLimit: Int?
    public private(set) var memoryUsed = 0
    /// How many loads were asked for: each load's number.
    private var loadCount = 0
    /// The loads under way of each file. One dropped from the queue before it started goes with its work, and the
    /// emptied lists are swept now and then.
    private var pending: [DiskPath: [WeakLoad]] = [:]

    public init(
        provider: any ThumbnailProviding = FileThumbnailService(),
        queue: ThumbnailLoadQueue = ThumbnailLoadQueue(), maxEntries: Int = ThumbnailStore.maxEntries,
        memoryLimit: Int? = nil
    ) {
        self.provider = provider
        self.queue = queue
        self.cache = LRUCache(capacity: maxEntries)
        self.memoryLimit = memoryLimit
    }

    /// How many previews are kept.
    public var count: Int { cache.count }

    /// The memory the Previews view's previews may take on a Mac with `physicalMemory` bytes: 1 GB, or a sixteenth of
    /// the Mac's memory when that is less.
    public nonisolated static func previewMemoryLimit(physicalMemory: UInt64) -> Int {
        let gigabyte = 1 << 30
        return Int(min(UInt64(gigabyte), physicalMemory / 16))
    }

    /// What a preview takes: the bytes of its picture's pixels, at most four a pixel
    /// (`QuickLookThumbnailRenderer.eightBitImage`).
    private static func cost(_ cached: Cached) -> Int {
        cached.picture?.bytes ?? 0
    }

    private func keep(_ cached: Cached, for path: DiskPath) {
        if let old = cache.peek(path) { memoryUsed -= Self.cost(old) }
        if let dropped = cache.write(cached, for: path) { memoryUsed -= Self.cost(dropped) }
        memoryUsed += Self.cost(cached)
        guard let memoryLimit else { return }
        while memoryUsed > memoryLimit, cache.count > 1, let dropped = cache.removeOldest() {
            memoryUsed -= Self.cost(dropped)
        }
    }

    /// Only files have previews of their content; folders, apps and other bundles keep the icons macOS
    /// draws for them.
    public static func canHaveThumbnail(_ kind: IconEntryKind) -> Bool {
        kind == .file || kind == .symlinkFile
    }

    /// The preview already loaded for the file, if any; a drag shows it instead of the icon.
    public func loadedPicture(forPath path: String) -> ThumbnailPicture? {
        cache.peek(DiskPath(path))?.picture
    }

    /// Lets go of every preview kept (macOS is short of memory); loads under way still answer, and the pictures on
    /// screen stay where they are drawn.
    public func dropCached() {
        cache.removeAll()
        memoryUsed = 0
    }

    /// The files at `paths` (nil: any file) may have changed on disk, though the listing may not show it (an edit
    /// changes nothing a listing shows): the previews kept of them are checked against the files again the next time
    /// they are asked for, whatever the listing. A load under way of one is kept and given, and checked again too, as
    /// the file may have changed after it was read.
    public func markChanged(_ paths: Set<DiskPath>?) {
        if let paths {
            for path in paths {
                cache.modify(path) { $0.checkedFor = nil }
                for entry in pending[path] ?? [] { entry.load?.fileChanged = true }
            }
        } else {
            cache.modifyAll { $0.checkedFor = nil }
            for loads in pending.values {
                for entry in loads { entry.load?.fileChanged = true }
            }
        }
    }

    private func started(_ load: PendingLoad, path: DiskPath) {
        if pending.count > Self.maxEntries {
            pending = pending.filter { $0.value.contains { $0.load != nil } }
        }
        pending[path, default: []].append(WeakLoad(load: load))
    }

    private func finished(_ load: PendingLoad, path: DiskPath) {
        let left = (pending[path] ?? []).filter { $0.load != nil && $0.load !== load }
        pending[path] = left.isEmpty ? nil : left
    }

    /// Forgets every cached preview and queued request.
    public func reset() {
        cache.removeAll()
        memoryUsed = 0
        queue.removeAll()
    }

    /// Calls `completion` with the item's preview (nil while it is loading or when there is none). A cached
    /// preview is given at once and checked against the file once per `listing`, so a file that changed
    /// gets a new preview the next time its folder is read, or once `markChanged` names it. One cached at a smaller
    /// `size` is given at once too, and asked for again at this size; a file with no preview at a larger size is asked
    /// for again at this one. `listing` stands for one reading of the folder:
    /// any object that changes when the list of items does. A load of the file under way that serves the request is
    /// waited for rather than asked again, and moves up the queue if it was asked for ahead of need.
    @discardableResult
    public func load(
        path: String, kind: IconEntryKind, size: Int = ThumbnailStore.pixelSize, listing: AnyObject,
        completion: @escaping @MainActor (ThumbnailPicture?) -> Void
    ) -> LoadHandle {
        load(path: path, kind: kind, size: size, listing: listing, ahead: false, completion: completion)
    }

    /// Asks for the file's preview ahead of need, as `load` would, so that it is cached once it is wanted: it waits
    /// behind every preview wanted now. The handle takes it back if it has not started.
    @discardableResult
    public func prefetch(path: String, kind: IconEntryKind, size: Int, listing: AnyObject) -> LoadHandle {
        load(path: path, kind: kind, size: size, listing: listing, ahead: true) { _ in }
    }

    /// Whether a preview of the file, or the answer that it has none, is kept: one not kept yet is being loaded or
    /// will be.
    public func isKept(path: String) -> Bool {
        cache.peek(DiskPath(path)) != nil
    }

    private func load(
        path: String, kind: IconEntryKind, size: Int, listing: AnyObject, ahead: Bool,
        completion: @escaping @MainActor (ThumbnailPicture?) -> Void
    ) -> LoadHandle {
        guard Self.canHaveThumbnail(kind) else {
            completion(nil)
            return LoadHandle()
        }
        // The file's key, made once for the request: what is kept and what is under way are both looked up by it.
        let key = DiskPath(path)
        let cached = cache.read(key)
        completion(cached?.picture)
        if let cached, cached.checkedFor === listing, cached.covers(size) {
            return LoadHandle()
        }
        // A preview too small is made again even when the file is as it was, and so is one there was none of at a
        // larger size.
        let knownVersion = cached.flatMap { $0.covers(size) ? $0.version : nil }
        let wanted = cached?.picture != nil ? max(size, cached?.size ?? 0) : size
        let waiter = Waiter(completion)
        let loads = pending[key]?.lazy.compactMap(\.load)
        if let running = loads?.first(where: { $0.serves(size: wanted, listing: listing) }) {
            running.waiters.append(waiter)
            if !ahead, running.isAhead {
                running.isAhead = false
                queue.wantNow(running.job)
            }
            return handle(waiter, of: running)
        }
        // The folder was read again while the file's preview was being made (a download adding files to it, a step
        // of a window being resized): that load goes on and answers this request too, rather than being taken back
        // and begun again, which a folder that keeps changing would do to it over and over.
        if let other = loads?.first(where: { $0.showsMeanwhile(size: wanted) }) {
            waiter.recheck = (kind, size, listing, ahead)
            other.waiters.append(waiter)
            if !ahead, other.isAhead {
                other.isAhead = false
                queue.wantNow(other.job)
            }
            return handle(waiter, of: other)
        }
        let provider = self.provider
        loadCount += 1
        let number = loadCount
        let load = PendingLoad(size: wanted, listing: listing, isAhead: ahead)
        load.waiters = [waiter]
        started(load, path: key)
        load.job = queue.add(ahead: ahead) { [weak self] in
            let response = await provider.response(
                path: path, size: wanted, knownVersion: knownVersion)
            guard let self else { return }
            self.finished(load, path: key)
            // Stopped part way, scrolled past: no picture says nothing of the file, and nothing is kept.
            if Task.isCancelled, response.picture == nil, !response.unchanged { return }
            // Told of a change while it was being read: given all the same, and checked again the next time.
            let checkedFor: AnyObject? = load.fileChanged ? nil : listing
            var thumbnail =
                response.unchanged && cached != nil
                ? Cached(
                    version: cached?.version, picture: cached?.picture, size: wanted, checkedFor: checkedFor,
                    loadNumber: number)
                : Cached(
                    version: response.version, picture: response.picture, size: wanted, checkedFor: checkedFor,
                    loadNumber: number)
            if thumbnail.picture == nil, let cached, cached.picture != nil, cached.version == thumbnail.version {
                // No picture at the larger size of a file that is as it was: the smaller one stays.
                thumbnail.picture = cached.picture
            }
            if let current = self.cache.peek(key), current.picture != nil, current.size > wanted,
                current.checkedFor === listing, current.version == thumbnail.version
            {
                // A load of a larger size, asked for since and ended first, made a sharper picture of the file as it
                // is: it stays, and serves this load too.
                thumbnail = current
            } else if let current = self.cache.peek(key), current.loadNumber > number,
                current.version != thumbnail.version
                    || (current.size >= wanted && (current.picture != nil || thumbnail.picture == nil))
            {
                // A load begun later ended first, having read the file later: its picture stays, and serves this load
                // too, unless this one is a sharper picture of the file as that one found it, or a picture where that
                // one, at a larger size, found none.
                thumbnail = current
            } else {
                self.keep(thumbnail, for: key)
            }
            for waiter in load.waiters where !waiter.cancelled {
                waiter.completion(thumbnail.picture)
                // One of a later listing: the file is checked for it now, which costs a look at the file unless it
                // changed.
                if let recheck = waiter.recheck, !waiter.cancelled {
                    waiter.recheck = nil
                    waiter.followUp = self.load(
                        path: path, kind: recheck.kind, size: recheck.size, listing: recheck.listing,
                        ahead: recheck.ahead, completion: waiter.completion)
                }
            }
        }
        return handle(waiter, of: load)
    }

    /// Takes the waiter's request back, and the load once no one waits for it: out of the queue, or told to stop if it
    /// started (a picture it makes all the same is kept). One that started is told only once the main loop turns:
    /// a pane that shows its items again (the folder read again, the pane resized) takes every request back and
    /// makes it again at once, and the load under way then goes on for the new one.
    private func handle(_ waiter: Waiter, of load: PendingLoad) -> LoadHandle {
        LoadHandle { [weak self, weak load] in
            waiter.cancelled = true
            waiter.followUp?.cancel()
            waiter.followUp = nil
            guard let self, let load, !load.isRemoved, load.waiters.allSatisfy(\.cancelled) else { return }
            if self.queue.remove(load.job) {
                load.isRemoved = true
                return
            }
            DispatchQueue.main.async { [weak self, weak load] in
                MainActor.assumeIsolated {
                    guard let self, let load, !load.isRemoved, load.waiters.allSatisfy(\.cancelled) else { return }
                    self.queue.stop(load.job)
                    load.isRemoved = true
                }
            }
        }
    }
}
