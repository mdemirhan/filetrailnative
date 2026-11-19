import Foundation

public enum DetailsSorting {
    /// What a click on a column header asks the folder to be ordered by; nil for a column the list cannot be ordered
    /// by. Date Created and Permissions come from metadata that loads only for the rows on screen, and Folder exists
    /// only in search results; Date Added comes with the folder read, and Date Last Opened is read for every item
    /// only while the list is sorted by it. Search results order by Name, Folder (their
    /// path) and Kind.
    public static func sortKey(for column: DetailColumn, search: Bool) -> String? {
        if search {
            switch column {
            case .name: return "name"
            case .folder: return "path"
            case .kind: return "kind"
            default: return nil
            }
        }
        switch column {
        case .name, .modified, .size, .kind, .added, .lastOpened: return column.rawValue
        case .created, .permissions, .folder: return nil
        }
    }

    /// The same key toggles the direction; a new key starts descending for the dates and Size (the newest and the
    /// largest first, as in Finder), ascending for Name and Kind.
    public static func next(
        current: SortByPreference, direction: SortDirectionPreference, requested: SortByPreference
    ) -> (sortBy: SortByPreference, direction: SortDirectionPreference) {
        if requested == current {
            return (requested, direction == .asc ? .desc : .asc)
        }
        return (requested, [.modified, .added, .lastOpened, .size].contains(requested) ? .desc : .asc)
    }
}
