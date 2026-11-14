import Foundation

/// Previews of the content of files, for icon view and the Previews view.
///
/// Previews are asked for at `pixelSize(forIconSize:)` on their longest side: twice the icon, for a Retina display.
/// Previews are kept in memory only (Quick Look has its own cache on disk), most recently used last. 500 cover
/// several screens of icon view; older ones are asked for again. A store of large previews also keeps under a memory
/// limit, counting each preview by the pixels of its picture.
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
        /// The listing the preview was last checked against the file for; nil once the file may have changed since,
        /// so that it is checked again the next time it is asked for.
        var checkedFor: AnyObject?
        /// The number of the load that made it: of two loads, the one begun later read the file later.
        var loadNumber: Int
    }

    /// A load under way, told when its file may have changed after it was read.
    @MainActor
    private final class PendingLoad {
        var fileChanged = false
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
    private var cache: LRUCache<String, Cached>
    /// The bytes the previews kept may take at most (nil: only the count is limited), and what they take now.
    private let memoryLimit: Int?
    public private(set) var memoryUsed = 0
    /// How many loads were asked for: each load's number.
    private var loadCount = 0
    /// The loads under way of each file. One dropped from the queue before it started goes with its work, and the
    /// emptied lists are swept now and then.
    private var pending: [String: [WeakLoad]] = [:]

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

    /// What a preview takes: four bytes a pixel of the picture Quick Look made.
    private static func cost(_ cached: Cached) -> Int {
        guard let image = cached.picture?.image else { return 0 }
        return Int(image.size.width * image.size.height) * 4
    }

    private func keep(_ cached: Cached, for path: String) {
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
        cache.peek(path)?.picture
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
    public func markChanged(_ paths: Set<String>?) {
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

    private func started(_ load: PendingLoad, path: String) {
        if pending.count > Self.maxEntries {
            pending = pending.filter { $0.value.contains { $0.load != nil } }
        }
        pending[path, default: []].append(WeakLoad(load: load))
    }

    private func finished(_ load: PendingLoad, path: String) {
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
    /// `size` is given at once too, and asked for again at this size. `listing` stands for one reading of the folder:
    /// any object that changes when the list of items does.
    @discardableResult
    public func load(
        path: String, kind: IconEntryKind, size: Int = ThumbnailStore.pixelSize, listing: AnyObject,
        completion: @escaping @MainActor (ThumbnailPicture?) -> Void
    ) -> LoadHandle {
        guard Self.canHaveThumbnail(kind) else {
            completion(nil)
            return LoadHandle()
        }
        let cached = cache.read(path)
        completion(cached?.picture)
        if let cached, cached.checkedFor === listing, cached.size >= size {
            return LoadHandle()
        }
        // A preview too small is made again even when the file is as it was.
        let knownVersion = cached.flatMap { $0.size >= size ? $0.version : nil }
        let wanted = max(size, cached?.size ?? 0)
        let cancelled = CancelFlag()
        let provider = self.provider
        loadCount += 1
        let number = loadCount
        let load = PendingLoad()
        started(load, path: path)
        let queued = queue.enqueue { [weak self] in
            let response = await provider.response(
                path: path, size: wanted, knownVersion: knownVersion)
            guard let self else { return }
            self.finished(load, path: path)
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
            if let current = self.cache.peek(path), current.size > wanted, current.checkedFor === listing,
                current.version == thumbnail.version
            {
                // A load of a larger size, asked for since and ended first, made a sharper picture of the file as it
                // is: it stays, and serves this load too.
                thumbnail = current
            } else if let current = self.cache.peek(path), current.loadNumber > number,
                current.size >= wanted || current.version != thumbnail.version
            {
                // A load begun later ended first, having read the file later: its picture stays, and serves this load
                // too, unless this one is a sharper picture of the file as that one found it.
                thumbnail = current
            } else {
                self.keep(thumbnail, for: path)
            }
            if !cancelled.value {
                completion(thumbnail.picture)
            }
        }
        return LoadHandle {
            cancelled.value = true
            queued.cancel()
        }
    }
}

@MainActor
private final class CancelFlag {
    var value = false
}
