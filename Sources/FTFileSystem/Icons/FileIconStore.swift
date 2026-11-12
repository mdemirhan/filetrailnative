import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Draws the icon macOS has for a path.
public protocol IconSource: Sendable {
    func icon(atPath path: String) -> NSImage?
    /// The icon of a folder as Finder draws it.
    func folderIcon(atPath path: String) async -> NSImage?
    /// The icon of the files with this extension, drawn from their type alone, without reading a file; nil when the
    /// source can't draw it at once.
    func typeIcon(forExtension fileExtension: String) -> NSImage?
}

extension IconSource {
    public func folderIcon(atPath path: String) async -> NSImage? {
        icon(atPath: path)
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
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side), scale: 2,
            representationTypes: .icon)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return icon(atPath: path) }
        return NSImage(cgImage: representation.cgImage, size: NSSize(width: side, height: side))
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
    /// The icons nearly every folder shows, asked for once when the window opens.
    public nonisolated static let preloadedKinds: [GenericIconKind] = [.folder, .emptyFolder, .file]

    private let source: any IconSource
    private let samples: IconSamples
    private let sleep: @Sendable (Duration) async throws -> Void
    private var cache = LRUCache<String, NSImage?>(capacity: FileIconStore.maxEntries)
    /// The drawings under way, each with its number: only the latest for an icon fills the cache.
    private var pending: [String: (id: Int, task: Task<NSImage?, Never>)] = [:]
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
        if let slot = cache.read(request.cacheKey) {
            return slot.map(IconLookup.image) ?? .none
        }
        return drawnAtOnce(request).map(IconLookup.image) ?? .missing
    }

    /// Calls `completion` with the icon (nil when macOS has none): at once when it is cached, otherwise when
    /// it arrives, unless the handle is cancelled first. `deferLoad` waits a moment before asking for an icon
    /// that is not known yet. Requests for the same icon that overlap share one fetch.
    @discardableResult
    public func load(
        _ request: IconRequest, deferLoad: Bool = false, completion: @escaping @MainActor (NSImage?) -> Void
    ) -> LoadHandle {
        if let slot = cache.read(request.cacheKey) {
            completion(slot)
            return LoadHandle()
        }
        if let image = drawnAtOnce(request) {
            completion(image)
            return LoadHandle()
        }
        let sleep = self.sleep
        // Without the delay the icon is asked for now, and taking the request back only stops the answer.
        let started = deferLoad ? nil : fetch(request)
        let task = Task { [weak self] in
            if deferLoad {
                try? await sleep(Self.deferredLoadDelay)
            }
            guard !Task.isCancelled, let self else { return }
            let image = await (started ?? self.fetch(request)).value
            guard !Task.isCancelled else { return }
            completion(image)
        }
        return LoadHandle { task.cancel() }
    }

    /// The icon may have changed: the next request draws it again, rather than waiting for a drawing from before.
    public func forget(_ request: IconRequest) {
        cache.remove(request.cacheKey)
        pending[request.cacheKey] = nil
    }

    /// Asks for the plain folder icons and the document icon, so the first folder already draws them.
    public func preloadGenericIcons() {
        for kind in Self.preloadedKinds {
            let request = IconRequest.generic(kind)
            if !cache.contains(request.cacheKey) {
                _ = fetch(request)
            }
        }
    }

    /// The icon files share by their extension depends on their type alone, which macOS draws at once: it is drawn
    /// now and kept, so the first item of a kind shows it in its first frame, not an empty space.
    private func drawnAtOnce(_ request: IconRequest) -> NSImage? {
        guard let fileExtension = IconCacheKey.fileExtension(ofKey: request.cacheKey),
            let image = source.typeIcon(forExtension: fileExtension)
        else { return nil }
        cache.write(image, for: request.cacheKey)
        return image
    }

    private func fetch(_ request: IconRequest) -> Task<NSImage?, Never> {
        if let running = pending[request.cacheKey] {
            return running.task
        }
        let source = self.source
        let samples = self.samples
        fetchCount += 1
        let id = fetchCount
        let task = Task { [weak self] () -> NSImage? in
            let image = await Task.detached(priority: .userInitiated) {
                await Self.draw(request, source: source, samples: samples)
            }.value
            self?.finish(request.cacheKey, image, id: id)
            return image
        }
        pending[request.cacheKey] = (id, task)
        return task
    }

    /// A drawing forgotten since it began answers its own requests but leaves the cache to the next one.
    private func finish(_ cacheKey: String, _ image: NSImage?, id: Int) {
        guard pending[cacheKey]?.id == id else { return }
        pending[cacheKey] = nil
        cache.write(image, for: cacheKey)
    }

    /// The generic kinds are drawn from sample items; a sample that can't be made gives no icon.
    private nonisolated static func draw(_ request: IconRequest, source: any IconSource, samples: IconSamples) async
        -> NSImage?
    {
        if let tint = request.tint {
            let plain: GenericIconKind = request.isEmptyFolder ? .emptyFolder : .folder
            guard
                let sample = (try? samples.path(forTint: tint, isEmpty: request.isEmptyFolder))
                    ?? (try? samples.path(for: plain))
            else { return nil }
            return await source.folderIcon(atPath: sample)
        }
        guard let kind = request.generic else {
            return request.isFolder ? await source.folderIcon(atPath: request.path) : source.icon(atPath: request.path)
        }
        guard let path = try? samples.path(for: kind) else { return nil }
        switch kind {
        case .folder, .emptyFolder: return await source.folderIcon(atPath: path)
        case .file, .executable: return source.icon(atPath: path)
        }
    }
}
