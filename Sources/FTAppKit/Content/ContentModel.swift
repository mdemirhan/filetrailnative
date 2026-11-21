import FTFileSystem
import FTFoundation
import Foundation

extension DirectoryEntry: ListFilterEntry {}

extension DirectoryEntry {
    /// The item's file URL, spelled as its path is; whether it is a folder is what its listing found, a link to one
    /// counting as one.
    var url: URL { DiskPath(path).url(isDirectory: kind.isDirectoryKind || kind == .bundle) }

    /// A folder, or a link to one: what opens in place, and what Folders First puts ahead.
    var isDirectoryLike: Bool { kind.isDirectoryKind }

    /// A folder or a bundle: its size is calculated, not listed. A link to a folder is
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
        case .alias: iconKind = .alias
        case .bundle: iconKind = .bundle
        case .other: iconKind = .other
        }
        return IconEntry(
            path: path, name: name, extension: fileExtension, kind: iconKind, isExecutable: isExecutable,
            hasCustomIcon: hasCustomIcon == true, tagColor: tagColor, isEmptyFolder: isEmptyFolder == true)
    }

    var sizeSortKey: SizeSortKey {
        SizeSortKey(
            path: path, name: name, isDirectoryKind: isDirectoryLike, isFolderSizeEligible: isFolderSizeEligible,
            listedSize: sizeBytes)
    }
}

/// A folder's read error as the window shows it: the message, and the errno when a system call failed.
public struct FolderReadError: Equatable, Sendable {
    public var message: String
    public var errnum: Int32?

    public init(message: String, errnum: Int32?) {
        self.message = message
        self.errnum = errnum
    }
}

/// Why a folder could not be read, as the window needs to tell it apart.
enum FolderReadFailure {
    /// The folder is no longer there (ENOENT, ENOTDIR, or "Path is not a directory"), and the
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
    private static func message(_ error: any Error) -> String {
        if let explorer = error as? ExplorerError { return explorer.description }
        return error.localizedDescription
    }

    /// The error as the window keeps it: its message, and the errno of a system call that failed.
    static func readError(_ error: any Error) -> FolderReadError {
        let errnum: Int32?
        if let explorer = error as? ExplorerError {
            if case .system(let code, _, _) = explorer { errnum = code } else { errnum = nil }
        } else {
            let error = error as NSError
            errnum = error.domain == NSPOSIXErrorDomain ? Int32(truncatingIfNeeded: error.code) : nil
        }
        return FolderReadError(message: message(error), errnum: errnum)
    }

    /// Whether the Trash was refused for want of Full Disk Access: macOS refuses to list it to an app without
    /// (EPERM), even though everything inside it can still be read.
    static func isTrashRefused(path: String, error: FolderReadError?, homePath: String) -> Bool {
        guard let error, !path.isEmpty, path == FavoriteLabel.trashPath(homePath: homePath) else { return false }
        return error.errnum == EPERM
    }
}

/// A group as the views of the folder show it: its header, and where its items are in the entries shown.
struct ShownGroup: Equatable {
    var group: EntryGroup
    /// The positions of its items in `entries`.
    var range: Range<Int>
}

/// What the content pane shows in place of items.
enum ContentLoadState: Equatable {
    /// Nothing read yet (no folder).
    case idle
    /// A folder is being read.
    case loading
    case loaded
    case failed(FolderReadError)
}

/// The folder on screen: what was listed, the order and filter it is shown in, and the sizes bars and the size order
/// need. Pure data, so the rules are testable without a window.
struct FolderContents {
    var path: String
    /// As the listing returned them.
    var listed: [DirectoryEntry]
    /// What the list narrows to (the typed filter, not a search).
    var filter = ""
    var filterMode = NameMatchMode.fuzzy
    /// The entries the filter can find among, when the text only grew: those the shorter text kept, in the order shown.
    var candidates: [DirectoryEntry]?
    /// Names beyond ASCII, folded once for the keystrokes to come.
    var foldedNames: FoldedNameCache?

    /// The entries shown, in order: filtered, and for a size sort finished with the folder sizes the listing could not
    /// know.
    func shown(
        sortBy: SortByPreference, direction: SortDirectionPreference, foldersFirst: Bool,
        folderSizeBytes: (String) -> Int64?
    ) -> [DirectoryEntry] {
        let matching = ListFilter.filterByName(
            candidates ?? listed, query: filter, mode: filterMode, cache: foldedNames)
        guard sortBy == .size else { return matching }
        return SizeOrder.sorted(
            matching, key: \.sizeSortKey, descending: direction == .desc, foldersFirst: foldersFirst,
            folderSizeBytes: folderSizeBytes)
    }

    /// A file's size from the listing, a folder's or bundle's once it is calculated.
    static func sizeBytes(of entry: DirectoryEntry, folderSizeBytes: (String) -> Int64?) -> Int64? {
        entry.isFolderSizeEligible ? folderSizeBytes(entry.path) : entry.sizeBytes
    }

    /// The largest size among all of the folder's entries, not only those on screen; nil when there is
    /// none above zero.
    func largestSize(folderSizeBytes: (String) -> Int64?) -> Int64? {
        var sizes: [Int64?] = []
        sizes.reserveCapacity(listed.count)
        for entry in listed { sizes.append(Self.sizeBytes(of: entry, folderSizeBytes: folderSizeBytes)) }
        return SizeBars.maxBytes(sizes)
    }
}
