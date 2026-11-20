import FTFoundation
import Foundation

extension FolderWatches.Dependencies {
    /// The folder watches as the app has them: an FSEvents stream per folder, the folder's modification time
    /// read with `stat`, and `cache` let go of what a change made outside the app touched before the window
    /// is told, so it reads the folder again rather than being handed the listing it had. The Trash is watched on
    /// every disk: a change on another disk says only that the listing changed, its items not being in the folder.
    @MainActor
    public static func app(
        cache: ResponseCache, fileSystem: any ExplorerFileSystem = NativeFileSystem(),
        trash: TrashFolders = TrashFolders(),
        onFolderChanged: @escaping @MainActor (_ windowID: Int, _ change: FolderChange) -> Void
    ) -> FolderWatches.Dependencies {
        FolderWatches.Dependencies(
            watchFolder: { path, onChange, onFail, onStart in
                let stopFolder = FSEventsFolderWatcher.watchFolder(
                    path: path, onChange: onChange, onFail: onFail, onStart: onStart)
                let stopOthers = trash.listedWith(path).map { other in
                    FSEventsFolderWatcher.watchFolder(
                        path: other, onDisk: TrashFolders.disk(of: other), onChange: { _ in onChange(nil) },
                        onFail: { onChange(nil) })
                }
                return {
                    stopFolder()
                    for stop in stopOthers { stop() }
                }
            },
            readModifiedTime: { path in
                // A disk read, which may wait on its disk.
                await BlockingWork.run(qos: .utility) {
                    // Added up with the Trash's other folders, as a listing's own time is.
                    FolderModifiedTime.read(path, alsoListing: trash.listedWith(path), fileSystem)
                }
            },
            onFolderChanged: onFolderChanged,
            forgetCachedListings: { path, changedPaths in
                cache.forgetFolderListings(path, changedPaths: changedPaths)
            })
    }
}
