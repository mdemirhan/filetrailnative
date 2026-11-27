// The values of a field read for every search result, while the results' order or groups need them
import FTFileSystem
import FTFoundation
import Foundation

/// The values search results are ordered or grouped by when they don't carry them (a date, the size, the tags): read
/// for every result in the background, in batches, only for the fields the order and the groups on screen need, and
/// only while they need them ("What the folder on screen needs is read for it" in docs/decisions.md: a field no
/// view shows is read only while something asks for it). A field no longer needed stops being read and its
/// values go; results that come later are read as they come, and a value read stays while its field is needed, so
/// a query narrowed or changed reads only the results that have none yet.
@MainActor
final class SearchValues {
    /// Reads the values of a field for paths, in their order.
    typealias Reader = @MainActor (_ paths: [String], _ field: ItemValueField) async -> [ItemValue]

    /// How many results a read takes at a time.
    static let batchSize = 2_000
    /// How long a read that is still going lets the list stand before it is ordered again with what came in: a long
    /// read shows it is getting on, and the rows don't move under the pointer at every batch.
    static let changeInterval: TimeInterval = 1

    private var read: Reader
    /// Told that values came in, for the order and the groups to be made again: once when a read ends, and while it
    /// goes on at most once every `changeInterval`.
    var changed: () -> Void = {}
    /// The time, in seconds; tests move it.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The values read, by the result's path as its row spells it.
    private var known: [ItemValueField: [DiskPath: ItemValue]] = [:]
    private var reading: [ItemValueField: Task<Void, Never>] = [:]
    /// What each field still has to read of the results there are now, in order.
    private var waiting: [ItemValueField: [String]] = [:]
    /// The batch each field's read is out for.
    private var inFlight: [ItemValueField: Set<DiskPath>] = [:]
    /// When each field's read started, or last told of its values.
    private var lastChange: [ItemValueField: TimeInterval] = [:]

    init(read: @escaping Reader) {
        self.read = read
    }

    /// The fields read now.
    var fields: Set<ItemValueField> { Set(known.keys) }

    /// A result's value of a field; nil while it isn't read (or the field isn't needed).
    func value(_ field: ItemValueField, of path: String) -> ItemValue? { known[field]?[DiskPath(path)] }

    /// The fields the results' order and groups need, for the results there are now: what isn't read yet of them is
    /// read, and what waited for results no longer there is not; a field not needed any more stops, and its values go.
    func need(_ fields: Set<ItemValueField>, paths: [String]) {
        for field in Set(known.keys).subtracting(fields) { stop(field) }
        for field in fields {
            let have = known[field] ?? [:]
            if known[field] == nil { known[field] = [:] }
            let out = inFlight[field] ?? []
            // What is read, or being read, is asked for once.
            let missing = paths.filter {
                let path = DiskPath($0)
                return have[path] == nil && !out.contains(path)
            }
            waiting[field] = missing.isEmpty ? nil : missing
            if !missing.isEmpty, reading[field] == nil { startReading(field) }
        }
    }

    /// Other results (a search of another folder, the results put away): everything goes.
    func reset() {
        for field in Array(known.keys) { stop(field) }
    }

    private func stop(_ field: ItemValueField) {
        reading[field]?.cancel()
        reading[field] = nil
        waiting[field] = nil
        inFlight[field] = nil
        lastChange[field] = nil
        known[field] = nil
    }

    private func startReading(_ field: ItemValueField) {
        lastChange[field] = now()
        reading[field] = Task { [weak self] in
            while let self, !Task.isCancelled, let batch = self.nextBatch(field) {
                self.inFlight[field] = Set(batch.lazy.map(DiskPath.init))
                let values = await self.read(batch, field)
                guard !Task.isCancelled, self.known[field] != nil else { return }
                self.inFlight[field] = nil
                for (path, value) in zip(batch, values) { self.known[field]?[DiskPath(path)] = value }
                self.batchArrived(field)
            }
            // A stopped read leaves the field to whatever started since.
            if !Task.isCancelled { self?.reading[field] = nil }
        }
    }

    /// A batch came in: the list hears of it when it was the last, or when it last heard long enough ago.
    private func batchArrived(_ field: ItemValueField) {
        let time = now()
        let ended = waiting[field] == nil
        guard ended || time - (lastChange[field] ?? time) >= Self.changeInterval else { return }
        lastChange[field] = time
        changed()
    }

    private func nextBatch(_ field: ItemValueField) -> [String]? {
        guard let left = waiting[field], !left.isEmpty else {
            waiting[field] = nil
            return nil
        }
        let batch = Array(left.prefix(Self.batchSize))
        waiting[field] = left.count > batch.count ? Array(left.dropFirst(batch.count)) : nil
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
        case .tags: .tags
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
