// Port of the entry helpers of apps/desktop/src/renderer/lib/explorerAppUtils.ts (isFolderSizeEligibleKind,
// isDirectoryLikeEntry), isFolderGoneError (lib/explorerNavigation.ts:293-298) and isTrashListingRefused (lib/favorites.ts:106)
import FTFileSystem
import FTFoundation
import Foundation

extension DirectoryEntry: ListFilterEntry {}

extension DirectoryEntry {
    var url: URL { URL(fileURLWithPath: path) }

    /// A folder, or a link to one: what opens in place, and what Folders First puts ahead.
    var isDirectoryLike: Bool { kind.isDirectoryKind }

    /// A folder or a bundle: its size is calculated, not listed (`isFolderSizeEligibleKind`). A link to a folder is
    /// not measured: it has the size of the link itself.
    var isFolderSizeEligible: Bool { kind == .directory || kind == .bundle }

    /// What the icon cache keys an entry by.
    var iconEntry: IconEntry {
        let iconKind: IconEntryKind
        switch kind {
        case .directory: iconKind = .directory
        case .file: iconKind = .file
        case .symlinkDirectory: iconKind = .symlinkDirectory
        case .symlinkFile: iconKind = .symlinkFile
        case .bundle: iconKind = .bundle
        case .other: iconKind = .other
        }
        return IconEntry(
            path: path, name: name, extension: fileExtension, kind: iconKind, isExecutable: isExecutable)
    }

    var sizeSortKey: SizeSortKey {
        SizeSortKey(
            path: path, name: name, isDirectoryKind: isDirectoryLike, isFolderSizeEligible: isFolderSizeEligible,
            listedSize: sizeBytes)
    }
}

extension URL {
    /// A path for comparing locations (no trailing slash, no `.` or `..`).
    var comparablePath: String { standardizedFileURL.path }
}

/// Why a folder could not be read, as the window needs to tell it apart.
enum FolderReadFailure {
    /// `isFolderGoneError`: the folder is no longer there (ENOENT, ENOTDIR, or "Path is not a directory"), and the
    /// same words later in the message do not count. EACCES and EPERM are not "gone".
    static func isGone(_ error: any Error) -> Bool {
        guard let explorer = error as? ExplorerError else {
            let code = (error as NSError).code
            return (error as NSError).domain == NSPOSIXErrorDomain && (code == Int(ENOENT) || code == Int(ENOTDIR))
        }
        switch explorer {
        case .notADirectory: return true
        case .outsideDirectory: return false
        case .system(let code, _, _): return code == ENOENT || code == ENOTDIR
        }
    }

    /// The message the folder's error card shows.
    static func message(_ error: any Error) -> String {
        if let explorer = error as? ExplorerError { return explorer.description }
        return error.localizedDescription
    }

    /// `isTrashListingRefused`: macOS refuses to list the Trash to an app without Full Disk Access, even though
    /// everything inside it can still be read.
    static func isTrashRefused(path: String, message: String?, homePath: String) -> Bool {
        guard let message, !path.isEmpty, path == FavoriteLabel.trashPath(homePath: homePath) else { return false }
        return message.contains("EPERM") || message.lowercased().contains("operation not permitted")
    }
}

/// What the content pane shows in place of items.
enum ContentLoadState: Equatable {
    /// Nothing read yet (no folder).
    case idle
    /// A folder is being read.
    case loading
    case loaded
    case failed(message: String)
}

/// The folder on screen: what was listed, the order and filter it is shown in, and the sizes bars and the size order
/// need. Pure data, so the rules are testable without a window.
struct FolderContents {
    var path: String
    /// As the listing returned them.
    var listed: [DirectoryEntry]
    /// What the list narrows to (the spike's filter; searching is P5-07's).
    var filter = ""

    /// The entries shown, in order: filtered, and for a size sort finished with the folder sizes the listing could not
    /// know (`sortEntriesBySize`).
    func shown(
        sortBy: SortByPreference, direction: SortDirectionPreference, foldersFirst: Bool,
        folderSizeBytes: (String) -> Int64?
    ) -> [DirectoryEntry] {
        let matching = ListFilter.filterByName(listed, query: filter)
        guard sortBy == .size else { return matching }
        return SizeOrder.sorted(
            matching, key: \.sizeSortKey, descending: direction == .desc, foldersFirst: foldersFirst,
            folderSizeBytes: folderSizeBytes)
    }

    /// A file's size from the listing, a folder's or bundle's once it is calculated (`getSizeBytes` of `sizeBars`).
    static func sizeBytes(of entry: DirectoryEntry, folderSizeBytes: (String) -> Int64?) -> Int64? {
        entry.isFolderSizeEligible ? folderSizeBytes(entry.path) : entry.sizeBytes
    }

    /// The largest size among all of the folder's entries, not only those on screen (B-INFO-176); nil when there is
    /// none above zero.
    func largestSize(folderSizeBytes: (String) -> Int64?) -> Int64? {
        var sizes: [Int64?] = []
        sizes.reserveCapacity(listed.count)
        for entry in listed { sizes.append(Self.sizeBytes(of: entry, folderSizeBytes: folderSizeBytes)) }
        return SizeBars.maxBytes(sizes)
    }
}
