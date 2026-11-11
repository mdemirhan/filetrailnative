import FTFileSystem
import FTFoundation
import Foundation

/// What a cell shows: its text, the tooltip, and whether it is the muted placeholder.
struct ListCellContent: Equatable {
    var text: String
    var tooltip: String? = nil
    var isPlaceholder = false
}

enum ListCellText {
    /// A folder or bundle shows this until its size is calculated.
    static let folderSizePlaceholder = "--"

    /// Folders and bundles show "--", as in Finder, until their size is calculated. An empty
    /// string is kept for metadata that is still loading.
    static func detailSize(entry: DirectoryEntry, metadata: EntryMetadata?) -> String {
        if entry.isFolderSizeEligible { return folderSizePlaceholder }
        guard let metadata, metadata.sizeStatus != .deferred else { return "" }
        return SizeText.size(
            metadata.sizeBytes, status: FTFoundation.SizeStatus(rawValue: metadata.sizeStatus.rawValue) ?? .unavailable)
    }

    /// The Size cell: a calculated folder's size, "Calculating…", or `detailSize`.
    static func size(entry: DirectoryEntry, metadata: EntryMetadata?, folderSize: FolderSizeEntry) -> ListCellContent {
        var label: String?
        if entry.isFolderSizeEligible {
            switch folderSize {
            case .ready(let bytes, _, _, _): label = SizeText.size(bytes, status: .ready)
            case .calculating: label = "Calculating…"
            default: break
            }
        }
        let text = label ?? detailSize(entry: entry, metadata: metadata)
        return ListCellContent(text: text, isPlaceholder: text == folderSizePlaceholder)
    }

    /// A date said relative to now ("24 min ago", "Today, 9:12 AM"), the whole date as the tooltip; empty while the
    /// row's details are still loading.
    static func date(_ date: Date?, now: Date) -> ListCellContent {
        guard let date else { return ListCellContent(text: "") }
        return ListCellContent(
            text: DateText.shared.relative(date, now: now), tooltip: DateText.shared.exactDateTime(date))
    }

    /// Whether the date reads in minutes, and so needs the minute clock.
    static func readsInMinutes(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return DateText.shared.isWithinLastHour(date, now: now)
    }

    /// The octal code, with the letters as the tooltip.
    static func permissions(_ metadata: EntryMetadata?) -> ListCellContent {
        guard let parts = PermissionText.split(metadata?.permissionMode) else { return ListCellContent(text: "") }
        return ListCellContent(text: parts.octal, tooltip: parts.symbolic)
    }

    /// A cell's text as the list shows it, for fitting a column to its widest value.
    static func content(
        column: DetailColumn, entry: DirectoryEntry, metadata: EntryMetadata?, folderSize: FolderSizeEntry, now: Date
    ) -> ListCellContent {
        switch column {
        case .name: return ListCellContent(text: entry.name)
        case .folder: return ListCellContent(text: "")
        case .size: return size(entry: entry, metadata: metadata, folderSize: folderSize)
        case .kind: return ListCellContent(text: metadata?.kindLabel ?? "")
        case .permissions: return permissions(metadata)
        case .modified: return date(metadata?.modifiedAt, now: now)
        case .created: return date(metadata?.createdAt, now: now)
        }
    }
}
