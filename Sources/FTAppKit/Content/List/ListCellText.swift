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

    /// Folders and bundles show "--", as in Finder, until their size is calculated. A file shows the size its folder
    /// read gave until its details are read; an empty string is kept while neither has it.
    static func detailSize(entry: DirectoryEntry, metadata: EntryMetadata?) -> String {
        if entry.isFolderSizeEligible { return folderSizePlaceholder }
        guard let metadata else { return entry.sizeBytes.map { SizeText.size($0, status: .ready) } ?? "" }
        guard metadata.sizeStatus != .deferred else { return "" }
        return SizeText.size(
            metadata.sizeBytes, status: FTFoundation.SizeStatus(rawValue: metadata.sizeStatus.rawValue) ?? .unavailable)
    }

    /// The Size cell: a calculated folder's size, "Calculating…", "Waiting…" behind another, or `detailSize`.
    static func size(entry: DirectoryEntry, metadata: EntryMetadata?, folderSize: FolderSizeEntry) -> ListCellContent {
        var label: String?
        if entry.isFolderSizeEligible {
            switch folderSize {
            case .ready(let bytes, _, _, _): label = SizeText.size(bytes, status: .ready)
            case .calculating(_, let waiting): label = waiting ? "Waiting…" : "Calculating…"
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
    static func permissions(entry: DirectoryEntry, metadata: EntryMetadata?) -> ListCellContent {
        let mode = metadata.map(\.permissionMode) ?? entry.permissionMode
        guard let parts = PermissionText.split(mode) else { return ListCellContent(text: "") }
        return ListCellContent(text: parts.octal, tooltip: parts.symbolic)
    }

    /// The tags' names with commas, as the Tags cell reads them, and as its tooltip.
    static func tags(_ tags: [FinderTag]?) -> ListCellContent {
        let text = (tags ?? []).map(\.name).joined(separator: ", ")
        return ListCellContent(text: text, tooltip: text.isEmpty ? nil : text)
    }

    /// A cell's text as the list shows it, for fitting a column to its widest value. `tags` are the item's as a read of
    /// the rows on screen found them, for the Tags cell.
    static func content(
        column: DetailColumn, entry: DirectoryEntry, metadata: EntryMetadata?, folderSize: FolderSizeEntry, now: Date,
        tags: [FinderTag]? = nil
    ) -> ListCellContent {
        switch column {
        case .name: return ListCellContent(text: entry.name)
        case .folder: return ListCellContent(text: "")
        case .size: return size(entry: entry, metadata: metadata, folderSize: folderSize)
        case .kind: return ListCellContent(text: metadata?.kindLabel ?? "")
        case .permissions: return permissions(entry: entry, metadata: metadata)
        case .modified: return date(modifiedAt(entry, metadata), now: now)
        case .created: return date(createdAt(entry, metadata), now: now)
        case .added: return date(addedAt(entry, metadata), now: now)
        case .lastOpened: return date(metadata?.lastOpenedAt, now: now)
        case .tags: return Self.tags(tags)
        }
    }

    // The row's details once read, and what its folder read gave until then.
    static func modifiedAt(_ entry: DirectoryEntry, _ metadata: EntryMetadata?) -> Date? {
        metadata.map(\.modifiedAt) ?? entry.listedModifiedAt
    }

    static func createdAt(_ entry: DirectoryEntry, _ metadata: EntryMetadata?) -> Date? {
        metadata.map(\.createdAt) ?? entry.listedCreatedAt
    }

    static func addedAt(_ entry: DirectoryEntry, _ metadata: EntryMetadata?) -> Date? {
        metadata.map(\.addedAt) ?? entry.listedAddedAt
    }
}
