import Foundation

public enum DetailsSorting {
    /// What a click on a column header asks the folder to be ordered by; nil for a column the list cannot be ordered
    /// by. Permissions comes from metadata that loads only for the rows on screen, and Folder exists only in search
    /// results; Date Created and Date Added come with the folder read, and Date Last Opened and the tags are read for
    /// every item only while the list is sorted by them. Search results order by Name, Folder (their path) and Kind
    /// from what each carries, and by a date, Size or Tags from a value read for every result while they are sorted
    /// by it.
    public static func sortKey(for column: DetailColumn, search: Bool) -> String? {
        if search {
            switch column {
            case .name: return "name"
            case .folder: return "path"
            case .kind: return "kind"
            case .modified, .created, .added, .lastOpened, .size, .tags: return column.rawValue
            case .permissions: return nil
            }
        }
        switch column {
        case .name, .modified, .size, .kind, .created, .added, .lastOpened, .tags: return column.rawValue
        case .permissions, .folder: return nil
        }
    }

    /// The same key toggles the direction; a new key starts descending for the dates and Size (the newest and the
    /// largest first, as in Finder), ascending for Name, Kind and Tags.
    public static func next(
        current: SortByPreference, direction: SortDirectionPreference, requested: SortByPreference
    ) -> (sortBy: SortByPreference, direction: SortDirectionPreference) {
        if requested == current {
            return (requested, direction == .asc ? .desc : .asc)
        }
        return (requested, [.modified, .created, .added, .lastOpened, .size].contains(requested) ? .desc : .asc)
    }
}
