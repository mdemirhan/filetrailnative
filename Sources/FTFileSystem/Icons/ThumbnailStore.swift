// Port of the cache and useFileThumbnail of apps/desktop/src/renderer/lib/fileThumbnails.tsx
import Foundation

/// Previews of the content of files, for icon view.
///
/// Longest side previews are asked for in: the 64-point icon of icon view on a Retina display. Compact icon
/// view draws the same picture smaller, so both share one cache. Previews are kept in memory only (Quick
/// Look has its own cache on disk), most recently used last. 500 cover several screens of icon view; older
/// ones are asked for again.
@MainActor
public final class ThumbnailStore {
    public nonisolated static let pixelSize = 128
    public nonisolated static let maxEntries = 500

    private struct Cached {
        /// The file's state the preview was made from; nil when the file could not be read.
        var version: String?
        /// Nil when Quick Look has no preview for the file.
        var picture: ThumbnailPicture?
        /// The listing the preview was last checked against the file for.
        var checkedFor: AnyObject
    }

    private let provider: any ThumbnailProviding
    private let queue: ThumbnailLoadQueue
    private var cache = LRUCache<String, Cached>(capacity: ThumbnailStore.maxEntries)

    public init(
        provider: any ThumbnailProviding = FileThumbnailService(),
        queue: ThumbnailLoadQueue = ThumbnailLoadQueue()
    ) {
        self.provider = provider
        self.queue = queue
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
        queue.removeAll()
    }

    /// Calls `completion` with the item's preview (nil while it is loading or when there is none). A cached
    /// preview is given at once and checked against the file once per `listing`, so a file that changed
    /// gets a new preview the next time its folder is read. `listing` stands for one reading of the
    /// folder: any object that changes when the list of items does.
    @discardableResult
    public func load(
        path: String, kind: IconEntryKind, listing: AnyObject,
        completion: @escaping @MainActor (ThumbnailPicture?) -> Void
    ) -> LoadHandle {
        guard Self.canHaveThumbnail(kind) else {
            completion(nil)
            return LoadHandle()
        }
        let cached = cache.read(path)
        completion(cached?.picture)
        if let cached, cached.checkedFor === listing {
            return LoadHandle()
        }
        let cancelled = CancelFlag()
        let provider = self.provider
        let queued = queue.enqueue { [weak self] in
            let response = await provider.response(
                path: path, size: Self.pixelSize, knownVersion: cached?.version)
            guard let self else { return }
            let thumbnail =
                response.unchanged && cached != nil
                ? Cached(version: cached?.version, picture: cached?.picture, checkedFor: listing)
                : Cached(version: response.version, picture: response.picture, checkedFor: listing)
            self.cache.write(thumbnail, for: path)
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
