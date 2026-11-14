import Foundation

/// What is read for items one at a time and kept by path, such as the details or the tags of the rows on screen: what
/// each item has, which changed since and are read again, and which are being read. An item that changes while it is
/// being read is read once more after, since the answer may be from before. An item a read found nothing for (its
/// folder is gone or can't be read) isn't asked for again until it changes: drawing its row again would otherwise ask
/// at once, and again after that. Starting over (another folder, other search results) drops what was asked before:
/// an answer to it changes nothing, and leaves the reads since as they are.
public struct PathReadCache<Value> {
    public private(set) var values: [String: Value] = [:]
    /// Items that changed: they keep what they have until they are read again.
    public private(set) var stale: Set<String> = []
    public private(set) var reading: Set<String> = []
    /// Items a read found nothing for: not asked for again until they change or it starts over.
    public private(set) var unanswered: Set<String> = []
    private var changedDuringRead: Set<String> = []
    /// Goes up each time it starts over; a read is answered with the one it began at.
    public private(set) var generation = 0

    public init() {}

    public subscript(path: String) -> Value? { values[path] }

    public var isReading: Bool { !reading.isEmpty }

    /// Of `paths`, those to read now, which are then being read: those not known or changed, and not being read
    /// already or found nothing for.
    public mutating func begin(_ paths: [String]) -> [String] {
        var wanted: [String] = []
        for path in paths
        where (values[path] == nil || stale.contains(path)) && !reading.contains(path) && !unanswered.contains(path) {
            reading.insert(path)
            wanted.append(path)
        }
        return wanted
    }

    /// These items changed (nil: any may have): what they have is read again, and those being read once more after.
    public mutating func markChanged(_ paths: [String]?) {
        if let paths {
            stale.formUnion(paths.filter { values[$0] != nil })
            changedDuringRead.formUnion(paths.filter { reading.contains($0) })
            unanswered.subtract(paths)
        } else {
            stale = Set(values.keys)
            changedDuringRead = reading
            unanswered = []
        }
    }

    /// The read of `paths` begun at `generation` answered. `answers` are what it found, or nil when they no longer
    /// belong to what is shown, which only ends the read. Nil when the read is from before a start over; otherwise the
    /// items to read once more, which changed while it ran. An item of `paths` it found nothing for, and that didn't
    /// change meanwhile, is left as it is and not asked for again.
    public mutating func finish(_ paths: [String], from generation: Int, answers: [String: Value]?) -> [String]? {
        guard generation == self.generation else { return nil }
        reading.subtract(paths)
        let again = changedDuringRead.intersection(paths)
        changedDuringRead.subtract(paths)
        guard let answers else { return [] }
        values.merge(answers) { $1 }
        stale.subtract(answers.keys)
        unanswered.formUnion(paths.filter { answers[$0] == nil && !again.contains($0) })
        stale.formUnion(again.filter { values[$0] != nil })
        return Array(again)
    }

    /// Starts over with nothing known, or with what `kept` knew (a folder back from under search results).
    public mutating func startOver(keeping kept: PathReadCache? = nil) {
        values = kept?.values ?? [:]
        stale = kept?.stale ?? []
        reading = []
        unanswered = []
        changedDuringRead = []
        generation += 1
    }
}

extension PathReadCache: Sendable where Value: Sendable {}
