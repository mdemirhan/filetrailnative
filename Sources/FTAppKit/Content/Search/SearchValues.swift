// The values of a field read for every search result, while the results' order or groups need them
import FTFileSystem
import FTFoundation
import Foundation

/// The values search results are ordered or grouped by when they don't carry them (a date, the size, the tags): read
/// for every result in the background, in batches, only for the fields the order and the groups on screen need, and
/// only while they need them ("Nothing is read before it is needed"). A field no longer needed stops being read and its
/// values go; results that come later are read as they come.
@MainActor
final class SearchValues {
    /// Reads the values of a field for paths, in their order.
    typealias Reader = @MainActor (_ paths: [String], _ field: ItemValueField) async -> [ItemValue]

    /// How many results a read takes at a time: the order and groups are made again after each.
    static let batchSize = 2_000

    private var read: Reader
    /// Told after each batch that came in.
    var changed: () -> Void = {}
    private var known: [ItemValueField: [String: ItemValue]] = [:]
    /// The results each field has asked about, read or waiting.
    private var asked: [ItemValueField: Set<String>] = [:]
    private var reading: [ItemValueField: Task<Void, Never>] = [:]
    /// What each field still has to read, in order.
    private var waiting: [ItemValueField: [String]] = [:]

    init(read: @escaping Reader) {
        self.read = read
    }

    /// The fields read now.
    var fields: Set<ItemValueField> { Set(asked.keys) }

    /// A result's value of a field; nil while it isn't read (or the field isn't needed).
    func value(_ field: ItemValueField, of path: String) -> ItemValue? { known[field]?[path] }

    /// The fields the results' order and groups need, for the results there are now: what isn't read yet of them is
    /// read; a field not needed any more stops, and its values go.
    func need(_ fields: Set<ItemValueField>, paths: [String]) {
        for field in Set(asked.keys).subtracting(fields) { stop(field) }
        for field in fields {
            var seen = asked[field] ?? []
            // What is being read is asked for once.
            let missing = paths.filter { seen.insert($0).inserted }
            asked[field] = seen
            if known[field] == nil { known[field] = [:] }
            guard !missing.isEmpty else { continue }
            waiting[field, default: []] += missing
            if reading[field] == nil { startReading(field) }
        }
    }

    /// Other results (another search, the results put away): everything goes.
    func reset() {
        for field in Array(asked.keys) { stop(field) }
    }

    private func stop(_ field: ItemValueField) {
        reading[field]?.cancel()
        reading[field] = nil
        waiting[field] = nil
        known[field] = nil
        asked[field] = nil
    }

    private func startReading(_ field: ItemValueField) {
        reading[field] = Task { [weak self] in
            while let self, !Task.isCancelled, let batch = self.nextBatch(field) {
                let values = await self.read(batch, field)
                guard !Task.isCancelled, self.known[field] != nil else { return }
                for (path, value) in zip(batch, values) { self.known[field]?[path] = value }
                self.changed()
            }
            // A stopped read leaves the field to whatever started since.
            if !Task.isCancelled { self?.reading[field] = nil }
        }
    }

    private func nextBatch(_ field: ItemValueField) -> [String]? {
        guard var left = waiting[field], !left.isEmpty else {
            waiting[field] = nil
            return nil
        }
        let batch = Array(left.prefix(Self.batchSize))
        left.removeFirst(batch.count)
        waiting[field] = left
        return batch
    }
}

extension SearchResultsSortByPreference {
    /// The field an order by it reads for every result; nil for one from what each result carries.
    var valueField: ItemValueField? {
        switch self {
        case .modified: .modified
        case .created: .created
        case .lastOpened: .lastOpened
        case .added: .added
        case .size: .size
        case .name, .path, .kind: nil
        }
    }
}

extension GroupByPreference {
    /// The field groups of search results by it read for every result; nil for those from what each result carries.
    var valueField: ItemValueField? {
        switch self {
        case .modified: .modified
        case .created: .created
        case .lastOpened: .lastOpened
        case .added: .added
        case .size: .size
        case .tags: .tags
        case .none, .name, .folder, .kind: nil
        }
    }
}
