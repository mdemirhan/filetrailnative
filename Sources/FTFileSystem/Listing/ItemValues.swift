// One field of items read for each of them, for search results ordered or grouped by it
import FTFoundation
import Foundation

/// A field of an item that its listing or search result doesn't carry: what an order or groups by it read.
public enum ItemValueField: String, Sendable, Hashable, CaseIterable {
    case modified, created, added, lastOpened, size, tags
}

/// An item's value of a field: a time in milliseconds since 1970 or a size in bytes; or its tags' names, one line a
/// name (`TagNameList`). Nil where the item has none (never opened, a folder's size, no tags) or can't be read.
public enum ItemValue: Sendable, Hashable {
    case number(Int64?)
    case text(String?)

    public var number: Int64? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

extension ExplorerListing {
    /// The value of `field` for each of `paths`, in their order. Only what the field needs is read: one look at each
    /// item for its times or size (a link's are what it leads to, as its columns show; its own when it leads nowhere),
    /// Date Added and Date Last Opened from their own attributes, the tags from theirs. A folder has no size of its
    /// own: its size is measured.
    static func values(_ paths: [String], field: ItemValueField, _ fileSystem: any ExplorerFileSystem) -> [ItemValue] {
        switch field {
        case .modified, .created, .size:
            return paths.map { path in
                let stats = (try? fileSystem.stat(path)) ?? (try? fileSystem.lstat(path))
                switch field {
                case .modified: return .number(stats?.mtimeMs)
                case .created: return .number(stats?.birthtimeMs)
                default:
                    guard let stats else { return .number(nil) }
                    guard stats.type == .directory else { return .number(stats.size) }
                    // A link to a folder has the link's own size, as its Size column shows; a folder has none.
                    let own = try? fileSystem.lstat(path)
                    return .number(own?.isSymbolicLink == true ? own?.size : nil)
                }
            }
        case .added:
            return paths.map { .number(fileSystem.addedMs($0)) }
        case .lastOpened:
            let reader = fileSystem.lastOpenedReader()
            return paths.map { .number(reader($0)) }
        case .tags:
            return paths.map { .text(TagNameList.joined(fileSystem.tagNames($0))) }
        }
    }
}
