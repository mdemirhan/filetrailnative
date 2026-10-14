// Port of the header sort rules of apps/desktop/src/renderer/components/ContentPane.tsx (:343-359, folderListColumns) and
// handleSortChange in hooks/useExplorerNavigationController.ts (:2002-2025)
import Foundation

public enum DetailsSorting {
    /// What a click on a column header asks the folder to be ordered by; nil for a column the list cannot be ordered
    /// by. Date Created and Permissions come from metadata that loads only for the rows on screen, and Folder exists
    /// only in search results. Search results order by Name, Folder (their path) and Kind.
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
        case .name, .modified, .size, .kind: return column.rawValue
        case .created, .permissions, .folder: return nil
        }
    }

    /// `handleSortChange`: the same key toggles the direction; a new key starts descending for Date Modified and
    /// Size, ascending for Name and Kind.
    public static func next(
        current: SortByPreference, direction: SortDirectionPreference, requested: SortByPreference
    ) -> (sortBy: SortByPreference, direction: SortDirectionPreference) {
        if requested == current {
            return (requested, direction == .asc ? .desc : .asc)
        }
        return (requested, requested == .modified || requested == .size ? .desc : .asc)
    }

    /// Whether a column is the one a folder's list is ordered by.
    public static func isActive(_ column: DetailColumn, sortBy: SortByPreference) -> Bool {
        sortKey(for: column, search: false) == sortBy.rawValue
    }
}
