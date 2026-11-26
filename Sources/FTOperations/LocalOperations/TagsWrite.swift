// The tag colors' and the Tags popover's changes, written through the write slot and kept for Undo: a color chosen is
// one Undo, and so is everything changed while the popover is open
import FTFileSystem
import FTFoundation
import Foundation

/// A change of tags, as the color row and the Tags popover make it (`FinderTags`): a tag on every item comes off them
/// all, otherwise it goes on those without it.
public enum TagsChange: Equatable, Sendable {
    /// A color of the row, named as macOS names it.
    case color(FinderTagColor, name: String)
    /// A tag of the popover, by its name, in its color.
    case tag(FinderTag)
    /// The popover's Remove All Tags.
    case removeAll
}

/// What one change did: the items it changed, each as it was and is now, and those it couldn't.
public struct TagsWriteRun: Equatable, Sendable {
    public var items: [TagsUndoItem] = []
    public var failures: [FinderTagFailure] = []

    public init(items: [TagsUndoItem] = [], failures: [FinderTagFailure] = []) {
        self.items = items
        self.failures = failures
    }
}

/// One Undo's worth of tag changes: a color chosen, or one time the Tags popover is open. The first change records it
/// in the history; each change after it gives that same entry the items' newest tags, while it is still the one Undo
/// would take next. Once it isn't (an Undo took it, or another operation came after it), the next change records a
/// new one.
@MainActor
public final class TagsVisit {
    /// The history's entry for this visit, once one is recorded.
    public private(set) var entryId: Int?
    /// Each item changed, by path, with its tags before the visit's first change of it and its newest ones.
    private var items: [TagsUndoItem] = []
    private var places: [NameKeys.Exact: Int] = [:]

    public init() {}

    /// The items as the entry holds them, for the history: those back as they were taken out.
    func merge(_ changed: [TagsUndoItem], restarting: Bool) -> [TagsUndoItem] {
        if restarting {
            items = []
            places = [:]
        }
        for item in changed {
            let key = NameKeys.Exact(item.path)
            if let index = places[key] {
                items[index].after = item.after
                items[index].id = item.id
            } else {
                places[key] = items.count
                items.append(item)
            }
        }
        if items.contains(where: { $0.before == $0.after }) {
            items.removeAll { $0.before == $0.after }
            places = Dictionary(
                items.enumerated().map { (NameKeys.Exact($0.element.path), $0.offset) },
                uniquingKeysWith: { first, _ in first })
        }
        return items
    }

    fileprivate func recorded(_ id: Int?) { entryId = id }
}

public enum TagsWrite {
    static func undoTags(_ tags: [FinderTag]) -> [UndoTag] {
        tags.map { UndoTag(name: $0.name, color: $0.color?.rawValue ?? 0) }
    }

    static func finderTags(_ tags: [UndoTag]) -> [FinderTag] {
        tags.map { FinderTag(name: $0.name, color: FinderTagColor(rawValue: $0.color)) }
    }

    /// The id of the item whose tags are at `path`: a link is followed, as its tags are.
    static func itemId(_ fileSystem: some IdentityFileSystem, _ path: String) -> ItemId? {
        readItemId({ try fileSystem.stat($0) }, path)
    }

    /// `change` made to the items at `paths`. Reads and writes the disk: call it off the main actor.
    public static func change(_ change: TagsChange, paths: [String], fileSystem: some IdentityFileSystem)
        -> TagsWriteRun
    {
        let written =
            switch change {
            case .color(let color, let name): FinderTags.toggle(color, name: name, on: paths)
            case .tag(let tag): FinderTags.toggle(tag, on: paths)
            case .removeAll: FinderTags.removeAll(from: paths)
            }
        // A link and its original, both chosen, are one item with one set of tags: kept once, by the first path, or
        // Undo would find it changed once it put the tags back through the other.
        var seen = Set<ItemId>()
        var items: [TagsUndoItem] = []
        for changed in written.changed {
            let id = itemId(fileSystem, changed.path)
            if let id, !seen.insert(id).inserted { continue }
            items.append(
                TagsUndoItem(
                    path: changed.path, id: id, before: undoTags(changed.before), after: undoTags(changed.after)))
        }
        return TagsWriteRun(items: items, failures: written.failures)
    }
}

extension WriteCoordinator {
    /// A change of tags: written with the write slot held (refused while another operation runs, as every write is),
    /// and kept for Undo as part of `visit`'s one entry.
    public func changeTags(_ change: TagsChange, paths: [String], visit: TagsVisit) async throws -> TagsWriteRun {
        let fileSystem = self.fileSystem
        return try await prepareWithReservedSlot {
            options.caches.writeStarting()
            let run = await LocalOperations.onDisk { TagsWrite.change(change, paths: paths, fileSystem: fileSystem) }
            options.caches.writeEnded()
            if !run.items.isEmpty {
                options.caches.forget(run.items.map(\.path), [])
                recordTags(run.items, visit: visit)
            }
            return run
        } then: { run, _ in
            run
        }
    }

    /// The visit's entry given the newest tags while Undo would still take it next; otherwise a new entry.
    private func recordTags(_ changed: [TagsUndoItem], visit: TagsVisit) {
        let history = options.undoHistory
        let current = visit.entryId.flatMap { id in history?.top(.undo)?.id == id ? id : nil }
        var items = visit.merge(changed, restarting: current == nil)
        var units = items.isEmpty ? [] : [UndoUnit(steps: [.tags(items: items)])]
        if let history, let current {
            if history.replaceTop(current, units: units) {
                visit.recorded(units.isEmpty ? nil : current)
                return
            }
            // Not last in the list after all: this change starts an entry of its own.
            items = visit.merge(changed, restarting: true)
            units = items.isEmpty ? [] : [UndoUnit(steps: [.tags(items: items)])]
        }
        guard !units.isEmpty else { return }
        recordFinishedWrite(
            FinishedWrite(
                action: .write(.changeTags), log: .undoable(units: units),
                items: items.map {
                    WriteOperationItem(sourcePath: $0.path, destinationPath: $0.path, status: .completed)
                }))
        visit.recorded(history?.top(.undo)?.id)
    }
}
