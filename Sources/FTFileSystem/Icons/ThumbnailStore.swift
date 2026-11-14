import Foundation

/// Previews of the content of files, for icon view and the Previews view.
///
/// Previews are asked for at `pixelSize(forIconSize:)` on their longest side: twice the icon, for a Retina display.
/// Previews are kept in memory only (Quick Look has its own cache on disk), most recently used last. 500 cover
/// several screens of icon view; older ones are asked for again. A store of large previews also keeps under a memory
/// limit, counting each preview as a square of the size it was asked for.
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
        /// The listing the preview was last checked against the file for.
        var checkedFor: AnyObject
    }

    /// The size of a preview `size` points wide in the Previews view on a Retina display: twice as many pixels, in
    /// whole steps of 64, at most 1280.
    public nonisolated static func pixelSize(forPreviewSize size: Double) -> Int {
        min(1280, Int((size * 2 / 64).rounded(.up)) * 64)
    }

    private let provider: any ThumbnailProviding
    private let queue: ThumbnailLoadQueue
    private var cache: LRUCache<String, Cached>
    /// The bytes the previews kept may take at most (nil: only the count is limited), and what they take now.
    private let memoryLimit: Int?
    public private(set) var memoryUsed = 0

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

    /// What a preview asked for at `size` pixels may take: four bytes a pixel of its square.
    private static func cost(_ cached: Cached) -> Int { cached.picture == nil ? 0 : cached.size * cached.size * 4 }

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

    /// Forgets every cached preview and queued request.
    public func reset() {
        cache.removeAll()
        memoryUsed = 0
        queue.removeAll()
    }

    /// Calls `completion` with the item's preview (nil while it is loading or when there is none). A cached
    /// preview is given at once and checked against the file once per `listing`, so a file that changed
    /// gets a new preview the next time its folder is read. One cached at a smaller `size` is given at once too, and
    /// asked for again at this size. `listing` stands for one reading of the
    /// folder: any object that changes when the list of items does.
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
        let queued = queue.enqueue { [weak self] in
            let response = await provider.response(
                path: path, size: wanted, knownVersion: knownVersion)
            guard let self else { return }
            var thumbnail =
                response.unchanged && cached != nil
                ? Cached(version: cached?.version, picture: cached?.picture, size: wanted, checkedFor: listing)
                : Cached(version: response.version, picture: response.picture, size: wanted, checkedFor: listing)
            // A load of a larger size, asked for since and ended first, made a sharper picture of the file as it is:
            // it stays, and serves this load too.
            if let current = self.cache.peek(path), current.size > wanted, current.checkedFor === listing,
                current.version == thumbnail.version
            {
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
