import AppKit
import FTFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Draws the icon macOS has for a path.
public protocol IconSource: Sendable {
    /// Reads the item, which may wait on its disk: the store calls it as `BlockingWork`.
    func icon(atPath path: String) -> NSImage?
    /// The icon of a folder as Finder draws it.
    func folderIcon(atPath path: String) async -> NSImage?
    /// The icon of the files with this extension, drawn from their type alone, without reading a file; nil when the
    /// source can't draw it at once.
    func typeIcon(forExtension fileExtension: String) -> NSImage?
}

extension IconSource {
    public func folderIcon(atPath path: String) async -> NSImage? {
        await BlockingWork.run { icon(atPath: path) }
    }

    public func typeIcon(forExtension fileExtension: String) -> NSImage? { nil }
}

public struct WorkspaceIconSource: IconSource {
    /// In points, drawn at twice that in pixels: enough for the largest icon a window shows.
    static let folderIconSide = 128.0

    public init() {}

    public func icon(atPath path: String) -> NSImage? {
        NSWorkspace.shared.icon(forFile: path)
    }

    public func typeIcon(forExtension fileExtension: String) -> NSImage? {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: fileExtension) ?? .data)
    }

    /// Quick Look's icon, as NSWorkspace's has neither the sheet of paper of a folder holding something nor the color
    /// of a tag. NSWorkspace's stands in if Quick Look has none.
    public func folderIcon(atPath path: String) async -> NSImage? {
        let side = Self.folderIconSide
        let request = QLThumbnailGenerator.Request(
            fileAt: DiskPath(path).url(isDirectory: true), size: CGSize(width: side, height: side), scale: 2,
            representationTypes: .icon)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return await BlockingWork.run { icon(atPath: path) } }
        return NSImage(cgImage: representation.cgImage, size: NSSize(width: side, height: side))
    }
}

/// The arrow on an alias: a white disc with a curved arrow at the icon's lower left, drawn as the system draws the one
/// on a symbolic link, at its size. The system's own alias badge (`AliasBadgeIcon.icns`) is a thin arrow, hard to see
/// at a list's row size, and the link's badge isn't a file to draw from.
enum AliasBadge {
    /// The disc's width, of the icon's.
    static let discShare = 0.36
    /// The arrow's size, of the disc's.
    static let arrowShare = 0.6

    static func badged(_ icon: NSImage) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            let side = rect.width * discShare
            let disc = NSRect(x: rect.minX, y: rect.minY, width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = side * 0.08
            shadow.shadowOffset = NSSize(width: 0, height: -side * 0.03)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: disc).fill()
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(ovalIn: disc.insetBy(dx: side * 0.02, dy: side * 0.02))
            edge.lineWidth = side * 0.04
            NSColor.black.withAlphaComponent(0.18).setStroke()
            edge.stroke()
            let configuration = NSImage.SymbolConfiguration(pointSize: side * arrowShare, weight: .black)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
            if let arrow = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            {
                let size = arrow.size
                arrow.draw(
                    in: NSRect(
                        x: disc.midX - size.width / 2, y: disc.midY - size.height / 2, width: size.width,
                        height: size.height))
            }
            return true
        }
    }
}

/// What the cache holds for an icon.
public enum IconLookup {
    /// Never asked for (or dropped from the cache).
    case missing
    /// Asked for, and macOS has none.
    case none
    case image(NSImage)
}

/// A request that can be taken back before it answers.
public struct LoadHandle {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void = {}) {
        self.action = action
    }

    @MainActor public func cancel() {
        action()
    }
}

/// The icons macOS draws, most recently used last. The cache is large enough for every row of a big folder
/// whose items each have their own icon (apps, files without an extension); a cache smaller than what is
/// on screen drops icons still in use, and they are then asked for again.
@MainActor
public final class FileIconStore {
    public nonisolated static let maxEntries = 2048
    /// The info panel's icon changes with the selection. Its request waits this long, so holding an arrow
    /// key does not ask for the icon of every item passed on the way.
    public nonisolated static let deferredLoadDelay: Duration = .milliseconds(80)
    /// The icons nearly every folder shows, asked for once when the app starts.
    public nonisolated static let preloadedKinds: [GenericIconKind] = [.folder, .emptyFolder, .file]

    private let source: any IconSource
    private let samples: IconSamples
    private let sleep: @Sendable (Duration) async throws -> Void
    /// An icon's cache key (`IconRequest.cacheKey`) compared byte for byte: the key of an item with an icon of its
    /// own holds its path, and two items whose names differ only in how an accent is spelled each have their icon.
    private typealias Key = FTFoundation.NameKeys.Exact
    private var cache = LRUCache<Key, NSImage?>(capacity: FileIconStore.maxEntries)
    /// The drawings under way, each with its number: only the latest for an icon fills the cache.
    private var pending: [Key: (id: Int, task: Task<NSImage?, Never>)] = [:]
    private var fetchCount = 0

    public init(
        source: any IconSource = WorkspaceIconSource(), samples: IconSamples = IconSamples(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.samples = samples
        self.sleep = sleep
    }

    public var cachedCount: Int { cache.count }

    public func lookup(_ request: IconRequest) -> IconLookup {
        let key = Key(request.cacheKey)
        if let slot = cache.read(key) {
            return slot.map(IconLookup.image) ?? .none
        }
        return drawnAtOnce(request, key).map(IconLookup.image) ?? .missing
    }

    /// Calls `completion` with the icon (nil when macOS has none): at once when it is cached, otherwise when
    /// it arrives, unless the handle is cancelled first. `deferLoad` waits a moment before asking for an icon
    /// that is not known yet. Requests for the same icon that overlap share one fetch.
    @discardableResult
    public func load(
        _ request: IconRequest, deferLoad: Bool = false, completion: @escaping @MainActor (NSImage?) -> Void
    ) -> LoadHandle {
        // The icon's key, made once for the request.
        let key = Key(request.cacheKey)
        if let slot = cache.read(key) {
            completion(slot)
            return LoadHandle()
        }
        if let image = drawnAtOnce(request, key) {
            completion(image)
            return LoadHandle()
        }
        let sleep = self.sleep
        // Without the delay the icon is asked for now, and taking the request back only stops the answer.
        let started = deferLoad ? nil : fetch(request, key)
        let task = Task { [weak self] in
            if deferLoad {
                try? await sleep(Self.deferredLoadDelay)
            }
            guard !Task.isCancelled, let self else { return }
            let image = await (started ?? self.fetch(request, key)).value
            guard !Task.isCancelled else { return }
            completion(image)
        }
        return LoadHandle { task.cancel() }
    }

    /// The icon may have changed: the next request draws it again, rather than waiting for a drawing from before.
    public func forget(_ request: IconRequest) {
        let key = Key(request.cacheKey)
        cache.remove(key)
        pending[key] = nil
    }

    /// Asks for the plain folder icons, those of each tag color and the document icon, so the first folder already
    /// draws them: Quick Look takes a moment to draw a folder.
    public func preloadGenericIcons() {
        let tinted = FinderTagColor.allCases.flatMap { color in
            [false, true].map { IconRequest.tintedFolder(color, isEmpty: $0) }
        }
        for request in Self.preloadedKinds.map(IconRequest.generic) + tinted {
            let key = Key(request.cacheKey)
            if !cache.contains(key) { _ = fetch(request, key) }
        }
    }

    /// The icon files share by their extension depends on their type alone, which macOS draws at once: it is drawn
    /// now and kept, so the first item of a kind shows it in its first frame, not an empty space.
    private func drawnAtOnce(_ request: IconRequest, _ key: Key) -> NSImage? {
        guard let fileExtension = IconCacheKey.fileExtension(ofKey: request.cacheKey),
            let image = source.typeIcon(forExtension: fileExtension)
        else { return nil }
        cache.write(image, for: key)
        return image
    }

    private func fetch(_ request: IconRequest, _ key: Key) -> Task<NSImage?, Never> {
        if let running = pending[key] {
            return running.task
        }
        let source = self.source
        let samples = self.samples
        fetchCount += 1
        let id = fetchCount
        let task = Task { [weak self] () -> NSImage? in
            let image = await Self.draw(request, source: source, samples: samples)
            self?.finish(key, image, id: id)
            return image
        }
        pending[key] = (id, task)
        return task
    }

    /// A drawing forgotten since it began answers its own requests but leaves the cache to the next one.
    private func finish(_ cacheKey: Key, _ image: NSImage?, id: Int) {
        guard pending[cacheKey]?.id == id else { return }
        pending[cacheKey] = nil
        cache.write(image, for: cacheKey)
    }

    /// The generic kinds are drawn from sample items; a sample that can't be made gives no icon. A folder's is asked of
    /// Quick Look, which answers in its own time; the rest read the disk, as `BlockingWork`, so an item whose disk
    /// stopped answering holds up no task but its own.
    private nonisolated static func draw(_ request: IconRequest, source: any IconSource, samples: IconSamples) async
        -> NSImage?
    {
        enum Drawing: Sendable {
            case drawn(NSImage?)
            case folder(String)
            /// An alias's original: a folder's icon or a file's, then the arrow on it.
            case alias(original: String, isFolder: Bool)
        }
        let drawing = await BlockingWork.run { () -> Drawing in
            // macOS draws an alias file as a plain document: Finder draws its original's icon with the arrow. One
            // whose original can't be found keeps the plain one.
            if request.isAlias, let original = Links.originalItem(of: request.path) {
                return .alias(original: original.path, isFolder: original.isFolder)
            }
            if let tint = request.tint {
                let plain: GenericIconKind = request.isEmptyFolder ? .emptyFolder : .folder
                guard
                    let sample = (try? samples.path(forTint: tint, isEmpty: request.isEmptyFolder))
                        ?? (try? samples.path(for: plain))
                else { return .drawn(nil) }
                return .folder(sample)
            }
            guard let kind = request.generic else {
                return request.isFolder ? .folder(request.path) : .drawn(source.icon(atPath: request.path))
            }
            guard let path = try? samples.path(for: kind) else { return .drawn(nil) }
            switch kind {
            case .folder, .emptyFolder: return .folder(path)
            case .file, .executable: return .drawn(source.icon(atPath: path))
            }
        }
        switch drawing {
        case .drawn(let image): return image
        case .folder(let path): return await source.folderIcon(atPath: path)
        case .alias(let original, let isFolder):
            let icon =
                isFolder
                ? await source.folderIcon(atPath: original) : await BlockingWork.run { source.icon(atPath: original) }
            return icon.map(AliasBadge.badged)
        }
    }
}
