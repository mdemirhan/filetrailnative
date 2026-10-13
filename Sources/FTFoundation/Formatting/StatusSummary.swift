// Port of apps/desktop/src/renderer/lib/statusSummary.ts (and formatSearchStatus from lib/searchResults.ts)
import Foundation

/// The size the status bar shows: the selection's, or the folder on screen's with nothing selected.
/// Nil (an absent `StatusSize?`) while it is neither known nor being calculated.
public enum StatusSize: Equatable, Sendable {
    case ready(sizeBytes: Int64)
    case calculating
}

public enum StatusSummary {
    /// The selection's size once every size in it is known; while a folder in it is being
    /// calculated, that it is.
    public static func selectionSize(_ selection: SelectionSize) -> StatusSize? {
        if let total = selection.totalBytes {
            return .ready(sizeBytes: total)
        }
        if case .calculating = selection.folderSizeEntry {
            return .calculating
        }
        return nil
    }

    public static func folderSize(_ entry: FolderSizeEntry) -> StatusSize? {
        switch entry {
        case .ready(let sizeBytes, _, _, _): .ready(sizeBytes: sizeBytes)
        case .calculating: .calculating
        case .idle, .error: nil
        }
    }

    public static func sizeText(_ size: StatusSize?) -> String? {
        switch size {
        case nil: nil
        case .ready(let sizeBytes): SizeText.size(sizeBytes)
        case .calculating: "Calculating…"
        }
    }

    /// The path bar's right-hand summary replaces Finder's separate status bar: item or selection
    /// count, and the size of the selection, or of the folder on screen with nothing selected, when
    /// it is known. `shownCount` is how many of the items the list shows, when typing has narrowed it.
    public static func content(itemCount: Int, shownCount: Int? = nil, selectedCount: Int, size: StatusSize?) -> String
    {
        var parts = [
            selectedCount == 0
                ? ListFilter.formatItemCount(shown: shownCount ?? itemCount, total: itemCount)
                : "\(selectedCount) of \(itemCount) selected"
        ]
        if let text = sizeText(size) {
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    /// One line of search status: the result count, and the selection with its size when known.
    public static func search(
        isSearching: Bool, shown: Int, totalCount: Int, selectedCount: Int, selectionSize: StatusSize? = nil
    ) -> String {
        let noun = totalCount == 1 ? "result" : "results"
        let count = shown == totalCount ? "\(totalCount) \(noun)" : "\(shown) of \(totalCount) \(noun)"
        var parts = [isSearching ? "Searching… \(count)" : count]
        if selectedCount > 0 {
            parts.append("\(selectedCount) selected")
            if let text = sizeText(selectionSize) {
                parts.append(text)
            }
        }
        return parts.joined(separator: " · ")
    }
}
