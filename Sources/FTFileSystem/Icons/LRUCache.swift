// Port of the Map-based caches of apps/desktop/src/renderer/lib/fileIcons.tsx and fileThumbnails.tsx
/// A cache that drops its least recently used entry when it is full. Reading an entry makes it the most
/// recently used, as the original does by deleting and re-inserting the key.
struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var entries: [Key: (value: Value, stamp: Int)] = [:]
    private var clock = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// The value for `key`, now the most recently used.
    mutating func read(_ key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    /// The value for `key`, without changing the order.
    func peek(_ key: Key) -> Value? { entries[key]?.value }

    mutating func write(_ value: Value, for key: Key) {
        entries[key] = nil
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            entries[oldest] = nil
        }
        clock += 1
        entries[key] = (value, clock)
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
