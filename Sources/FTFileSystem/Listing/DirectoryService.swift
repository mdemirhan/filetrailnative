// Port of the browsing channels of apps/desktop/src/main/bootstrap.ts over packages/core/src/fs/explorerService.ts
// (the explorer worker is replaced by this actor)
import Foundation

/// Reading folders: snapshot listing with sort and folders-first, tree children, item details, path
/// suggestions and resolve, with the response cache the windows' behavior depends on.
///
/// Folders are read in one call each (getattrlistbulk) and sorted off the main thread. Item details, which
/// the window asks for as rows scroll into view, run at a lower priority and never hold up a listing.
public actor DirectoryService {
    private let fileSystem: any ExplorerFileSystem
    private let kinds: KindLabeler
    private let trash: TrashFolders
    /// Shared with the folder watch, which tells it what changed outside the app.
    public nonisolated let cache: ResponseCache

    public init(
        fileSystem: any ExplorerFileSystem = NativeFileSystem(), cache: ResponseCache = ResponseCache(),
        kinds: KindLabeler = .system, trash: TrashFolders = TrashFolders()
    ) {
        self.fileSystem = fileSystem
        self.cache = cache
        self.kinds = kinds
        self.trash = trash
    }

    /// The children of a folder that are folders (or links to folders), by name.
    public func treeChildren(path: String, includeHidden: Bool = false) async throws -> TreeChildren {
        let fileSystem = fileSystem
        let trash = trash
        return try await cache.treeChildren(TreeKey(path: path, includeHidden: includeHidden)) {
            try ExplorerListing.treeChildren(path: path, includeHidden: includeHidden, trash: trash, fileSystem)
        }
    }

    /// The Trash is listed as Finder shows it, with what is in the Trash of every disk, and a disk's own Trash is the
    /// same folder by another name, as is its ".Trashes". Without Full Disk Access, when only the home folder's is
    /// refused, a disk's own Trash can still be opened as itself.
    public func snapshot(
        path: String, includeHidden: Bool = false, sortBy: DirectorySortKey = .name,
        sortDirection: SortDirection = .ascending, foldersFirst: Bool = true
    ) async throws -> DirectorySnapshot {
        let listed = trash.listedFolder(for: path)
        func read(_ path: String, alsoListing: [String]) async throws -> DirectorySnapshot {
            let fileSystem = fileSystem
            let kinds = kinds
            let trash = trash
            let key = ListingKey(
                path: path, includeHidden: includeHidden, sortBy: sortBy, sortDirection: sortDirection,
                foldersFirst: foldersFirst)
            return try await cache.directorySnapshot(key) {
                try ExplorerListing.snapshot(
                    path: path, includeHidden: includeHidden, sortBy: sortBy, sortDirection: sortDirection,
                    foldersFirst: foldersFirst, alsoListing: alsoListing, trash: trash, fileSystem, kinds: kinds)
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
    public func hasHiddenFlag(path: String) -> Bool {
        (try? fileSystem.lstat(path))?.hasHiddenFlag == true
    }

    public func itemProperties(path: String) -> ItemProperties {
        ExplorerListing.itemProperties(path: path, fileSystem, kinds: kinds)
    }

    public func pathSuggestions(inputPath: String, includeHidden: Bool = false, limit: Int = 12) throws
        -> PathSuggestions
    {
        try ExplorerListing.pathSuggestions(
            inputPath: inputPath, includeHidden: includeHidden, limit: limit, trash: trash, fileSystem)
    }

    public func resolvePath(_ path: String) -> ResolvedPath {
        ExplorerListing.resolvePathTarget(path, fileSystem)
    }
}
