// Port of the listing, tree and metadata parts of apps/desktop/src/main/bootstrap/responseCache.ts
// (the folder-size parts are P2-02's)
import FTFoundation
import Foundation

/// What a cached directory snapshot answers: the request, which names the folder.
public struct ListingKey: Sendable, Hashable {
    public var path: String
    public var includeHidden: Bool
    public var sortBy: DirectorySortKey
    public var sortDirection: SortDirection
    public var foldersFirst: Bool

    public init(
        path: String, includeHidden: Bool = false, sortBy: DirectorySortKey = .name,
        sortDirection: SortDirection = .ascending, foldersFirst: Bool = true
    ) {
        self.path = path
        self.includeHidden = includeHidden
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.foldersFirst = foldersFirst
    }
}

public struct TreeKey: Sendable, Hashable {
    public var path: String
    public var includeHidden: Bool

    public init(path: String, includeHidden: Bool = false) {
        self.path = path
        self.includeHidden = includeHidden
    }
}

/// A cache whose entries all live as long, oldest first: inserting sweeps the expired ones and any beyond
/// the cap. Re-inserting a key moves it to the newest position.
struct TTLCache<Key: Hashable, Value> {
    private struct Slot {
        var expiresAt: Double
        var value: Value
        var sequence: Int
    }

    private var slots: [Key: Slot] = [:]
    // Keys in the order they were stored; one whose slot has a newer sequence was stored again since.
    private var order: [(sequence: Int, key: Key)] = []
    private var head = 0
    private var nextSequence = 0
    let maxEntries: Int
    let ttl: Double

    init(maxEntries: Int, ttl: Double) {
        self.maxEntries = maxEntries
        self.ttl = ttl
    }

    var count: Int { slots.count }

    func value(for key: Key, now: Double) -> Value? {
        guard let slot = slots[key], slot.expiresAt > now else { return nil }
        return slot.value
    }

    /// Stores the entries, read at `readAt`, then sweeps once at `now`: from the oldest, those expired go,
    /// and any while there are too many. The sweep stops at the first one kept.
    mutating func store(_ entries: some Sequence<(Key, Value)>, readAt: Double, now: Double) {
        for (key, value) in entries {
            nextSequence += 1
            slots[key] = Slot(expiresAt: readAt + ttl, value: value, sequence: nextSequence)
            order.append((nextSequence, key))
        }
        while head < order.count {
            let (sequence, key) = order[head]
            guard let slot = slots[key], slot.sequence == sequence else {
                head += 1
                continue
            }
            if slot.expiresAt > now && slots.count <= maxEntries { break }
            slots[key] = nil
            head += 1
        }
        if head > 1024 && head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }

    mutating func removeAll() {
        slots.removeAll()
        order.removeAll()
        head = 0
    }

    mutating func remove(_ key: Key) {
        slots[key] = nil
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in slots.keys where shouldRemove(key) {
            slots[key] = nil
        }
    }
}

/// Answers kept for a few seconds so a window asking again, or two windows asking for the same folder, read
/// the disk once. A load that started before a clear is still returned to whoever asked, but only kept if no
/// clear happened while it was loading.
public final class ResponseCache: @unchecked Sendable {
    public static let ttlMilliseconds: Double = 3_000
    public static let maxDirectorySnapshots = 64
    public static let maxTreeChildren = 256
    public static let maxDirectoryMetadata = 5_000

    private struct State {
        // Counts the clears.
        var generation = 0
        var directory: TTLCache<ListingKey, DirectorySnapshot>
        var tree: TTLCache<TreeKey, TreeChildren>
        var metadata: TTLCache<String, EntryMetadata>
    }

    private let lock = NSLock()
    private var state: State
    private let clock: @Sendable () -> Double

    /// `clock` tells the time in milliseconds.
    public init(clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.clock = clock
        state = State(
            directory: TTLCache(maxEntries: Self.maxDirectorySnapshots, ttl: Self.ttlMilliseconds),
            tree: TTLCache(maxEntries: Self.maxTreeChildren, ttl: Self.ttlMilliseconds),
            metadata: TTLCache(maxEntries: Self.maxDirectoryMetadata, ttl: Self.ttlMilliseconds))
    }

    private func withState<R>(_ body: (inout State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    public func directorySnapshot(
        _ key: ListingKey, load: () async throws -> DirectorySnapshot
    ) async rethrows -> DirectorySnapshot {
        let now = clock()
        let (cached, generation) = withState { ($0.directory.value(for: key, now: now), $0.generation) }
        if let cached { return cached }
        let value = try await load()
        withState { state in
            if state.generation == generation {
                state.directory.store([(key, value)], readAt: now, now: clock())
            }
        }
        return value
    }

    public func treeChildren(
        _ key: TreeKey, load: () async throws -> TreeChildren
    ) async rethrows -> TreeChildren {
        let now = clock()
        let (cached, generation) = withState { ($0.tree.value(for: key, now: now), $0.generation) }
        if let cached { return cached }
        let value = try await load()
        withState { state in
            if state.generation == generation {
                state.tree.store([(key, value)], readAt: now, now: clock())
            }
        }
        return value
    }

    /// Item details are cached per path instead of per request because the renderer asks for overlapping
    /// visible ranges as the user scrolls and changes layouts. `load` is handed the paths not kept.
    public func metadata(
        for paths: [String], load: ([String]) async throws -> [EntryMetadata]
    ) async rethrows -> [EntryMetadata] {
        let now = clock()
        var found: [String: EntryMetadata] = [:]
        var missing: [String] = []
        let generation = withState { state in
            for path in paths {
                if let cached = state.metadata.value(for: path, now: now) {
                    found[path] = cached
                } else {
                    missing.append(path)
                }
            }
            return state.generation
        }
        if !missing.isEmpty {
            let items = try await load(missing)
            for item in items {
                found[item.path] = item
            }
            // Swept once for the whole batch: scrolling a large folder asks for one after another.
            withState { state in
                if state.generation == generation {
                    state.metadata.store(items.map { ($0.path, $0) }, readAt: now, now: clock())
                }
            }
        }
        return paths.compactMap { found[$0] }
    }

    /// After a write: listings are read again.
    public func clear() {
        withState { state in
            state.generation += 1
            state.directory.removeAll()
            state.tree.removeAll()
            state.metadata.removeAll()
        }
    }

    /// After a change made outside the app to the folder at `folderPath`: its listings are read again, and
    /// the details of `changedPaths` in it. Nil says anything in it may have changed, or the folder itself
    /// (renamed or removed): the details of all in it are read again, and the listing of the folder holding
    /// it too. The listings of other folders, which other windows may be showing, are kept: a file growing
    /// in one folder doesn't slow every window.
    public func forgetFolderListings(_ folderPath: String, changedPaths: [String]?) {
        withState { state in
            state.generation += 1
            let parentPath = NodePath.dirname(folderPath)
            var listed: Set<String> = [folderPath]
            if changedPaths == nil && parentPath != folderPath {
                listed.insert(parentPath)
            }
            state.directory.removeAll { listed.contains($0.path) }
            state.tree.removeAll { listed.contains($0.path) }
            if let changedPaths {
                for path in changedPaths {
                    state.metadata.remove(path)
                }
            } else {
                state.metadata.removeAll { $0 == folderPath || NodePath.dirname($0) == folderPath }
            }
        }
    }

    public struct Sizes: Sendable, Equatable {
        public var directorySnapshots: Int
        public var directoryMetadata: Int
        public var treeChildren: Int
    }

    public var sizes: Sizes {
        withState {
            Sizes(
                directorySnapshots: $0.directory.count, directoryMetadata: $0.metadata.count,
                treeChildren: $0.tree.count)
        }
    }
}
