/// A cache that drops its least recently used entry when it is full. Reading an entry makes it the most
/// recently used.
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

    /// Writes `value` for `key`; returns the least recently used entry dropped to make room, if one was.
    @discardableResult
    mutating func write(_ value: Value, for key: Key) -> Value? {
        entries[key] = nil
        var dropped: Value?
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            dropped = entries[oldest]?.value
            entries[oldest] = nil
        }
        clock += 1
        entries[key] = (value, clock)
        return dropped
    }

    /// Changes the value for `key`, if there is one, without changing the order.
    mutating func modify(_ key: Key, _ change: (inout Value) -> Void) {
        guard var entry = entries[key] else { return }
        change(&entry.value)
        entries[key] = entry
    }

    /// Changes every value, without changing the order.
    mutating func modifyAll(_ change: (inout Value) -> Void) {
        for key in Array(entries.keys) { modify(key, change) }
    }

    /// Drops the least recently used entry and returns it.
    mutating func removeOldest() -> Value? {
        guard let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key else { return nil }
        return entries.removeValue(forKey: oldest)?.value
    }

    mutating func remove(_ key: Key) {
        entries[key] = nil
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
