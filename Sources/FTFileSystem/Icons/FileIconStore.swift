// Port of apps/desktop/src/renderer/lib/fileIcons.tsx (cache, requests, preloads) and getFileIconHandler (apps/desktop/src/main/bootstrap/systemHandlers.ts)
import AppKit

/// Draws the icon macOS has for a path (`nativeGetFileIcon` of the original, minus the PNG round trip).
public protocol IconSource: Sendable {
    func icon(atPath path: String) -> NSImage?
}

public struct WorkspaceIconSource: IconSource {
    public init() {}

    public func icon(atPath path: String) -> NSImage? {
        NSWorkspace.shared.icon(forFile: path)
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
    public nonisolated static let preloadedKinds: [GenericIconKind] = [.folder, .file]

    private let source: any IconSource
    private let samples: IconSamples
    private let sleep: @Sendable (Duration) async throws -> Void
    private var cache = LRUCache<String, NSImage?>(capacity: FileIconStore.maxEntries)
    private var pending: [String: Task<NSImage?, Never>] = [:]

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
        guard let slot = cache.read(request.cacheKey) else { return .missing }
        return slot.map(IconLookup.image) ?? .none
    }

    public func lookup(_ entry: IconEntry) -> IconLookup {
        lookup(IconRequest(entry: entry))
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

    /// Asks for the plain folder and document icons, so the first folder already draws them.
    public func preloadGenericIcons() {
        for kind in Self.preloadedKinds {
            let request = IconRequest.generic(kind)
            if !cache.contains(request.cacheKey) {
                _ = fetch(request)
            }
        }
    }

    private func fetch(_ request: IconRequest) -> Task<NSImage?, Never> {
        if let running = pending[request.cacheKey] {
            return running
        }
        let source = self.source
        let samples = self.samples
        let task = Task { [weak self] () -> NSImage? in
            let image = await Task.detached(priority: .userInitiated) {
                Self.draw(request, source: source, samples: samples)
            }.value
            self?.finish(request.cacheKey, image)
            return image
        }
        pending[request.cacheKey] = task
        return task
    }

    private func finish(_ cacheKey: String, _ image: NSImage?) {
        pending[cacheKey] = nil
        cache.write(image, for: cacheKey)
    }

    /// The generic kinds are drawn from sample items; a sample that can't be made gives no icon.
    private nonisolated static func draw(_ request: IconRequest, source: any IconSource, samples: IconSamples)
        -> NSImage?
    {
        guard let kind = request.generic else {
            return source.icon(atPath: request.path)
        }
        guard let path = try? samples.path(for: kind) else { return nil }
        return source.icon(atPath: path)
    }
}
