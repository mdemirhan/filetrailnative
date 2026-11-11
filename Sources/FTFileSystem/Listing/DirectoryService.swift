import FTFoundation
import Foundation

/// Reading folders: snapshot listing with sort and folders-first, tree children, item details, path
/// suggestions and resolve, with the response cache the windows' behavior depends on.
///
/// Folders are read in one call each (getattrlistbulk) and sorted off the main thread. Requests run side by side and
/// share nothing but the cache, so a folder whose read stalls (a network share that stopped answering) holds up only
/// those asking for it, not every window. Item details, which the window asks for as rows scroll into view, run at a
/// lower priority and never hold up a listing.
public final class DirectoryService: Sendable {
    private let fileSystem: any ExplorerFileSystem
    private let kinds: KindLabeler
    private let trash: TrashFolders
    /// The order names are listed in.
    private let order: NameOrder
    /// Shared with the folder watch, which tells it what changed outside the app.
    public let cache: ResponseCache

    public init(
        fileSystem: any ExplorerFileSystem = NativeFileSystem(), cache: ResponseCache = ResponseCache(),
        kinds: KindLabeler = .system, trash: TrashFolders = TrashFolders(), order: NameOrder = .current
    ) {
        self.fileSystem = fileSystem
        self.cache = cache
        self.kinds = kinds
        self.trash = trash
        self.order = order
    }

    /// The children of a folder that are folders (or links to folders), by name.
    @concurrent
    public func treeChildren(path: String, includeHidden: Bool = false) async throws -> TreeChildren {
        let fileSystem = fileSystem
        let trash = trash
        let order = order
        return try await cache.treeChildren(TreeKey(path: path, includeHidden: includeHidden)) {
            try ExplorerListing.treeChildren(
                path: path, includeHidden: includeHidden, trash: trash, fileSystem, order: order)
        }
    }

    /// The Trash is listed as Finder shows it, with what is in the Trash of every disk, and a disk's own Trash is the
    /// same folder by another name, as is its ".Trashes". Without Full Disk Access, when only the home folder's is
    /// refused, a disk's own Trash can still be opened as itself.
    @concurrent
    public func snapshot(
        path: String, includeHidden: Bool = false, sortBy: DirectorySortKey = .name,
        sortDirection: SortDirection = .ascending, foldersFirst: Bool = true
    ) async throws -> DirectorySnapshot {
        let listed = trash.listedFolder(for: path)
        func read(_ path: String, alsoListing: [String]) async throws -> DirectorySnapshot {
            let fileSystem = fileSystem
            let kinds = kinds
            let trash = trash
            let order = order
            let key = ListingKey(
                path: path, includeHidden: includeHidden, sortBy: sortBy, sortDirection: sortDirection,
                foldersFirst: foldersFirst)
            return try await cache.directorySnapshot(key) {
                try ExplorerListing.snapshot(
                    path: path, includeHidden: includeHidden, sortBy: sortBy, sortDirection: sortDirection,
                    foldersFirst: foldersFirst, alsoListing: alsoListing, trash: trash, fileSystem, kinds: kinds,
                    order: order)
            }
        }
        do {
            return try await read(listed, alsoListing: trash.listedWith(listed))
        } catch  where listed != path {
            return try await read(trash.ownFolder(for: path), alsoListing: [])
        }
    }

    /// Details of items in one folder, in the order asked; a folder's size is deferred. The folder is named as
    /// asked, not resolved, and only the items not kept are checked to be in it.
    @concurrent
    public func metadata(directoryPath: String, paths: [String]) async throws -> MetadataBatch {
        let fileSystem = fileSystem
        let kinds = kinds
        let items = try await cache.metadata(for: paths) { missing in
            try await Task.detached(priority: .utility) {
                try ExplorerListing.metadataBatch(
                    directoryPath: directoryPath, paths: missing, fileSystem, kinds: kinds
                ).items
            }.value
        }
        return MetadataBatch(directoryPath: directoryPath, items: items)
    }

    /// Whether the item itself has the flag that hides it, for telling a hidden folder from its path alone.
    @concurrent
    public func hasHiddenFlag(path: String) async -> Bool {
        (try? fileSystem.lstat(path))?.hasHiddenFlag == true
    }

    @concurrent
    public func itemProperties(
        path: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) async -> ItemProperties {
        ExplorerListing.itemProperties(path: path, fileSystem, kinds: kinds, startupDiskName: startupDiskName)
    }

    @concurrent
    public func pathSuggestions(inputPath: String, includeHidden: Bool = false, limit: Int = 12) async throws
        -> PathSuggestions
    {
        try ExplorerListing.pathSuggestions(
            inputPath: inputPath, includeHidden: includeHidden, limit: limit, trash: trash, fileSystem, order: order)
    }
}
