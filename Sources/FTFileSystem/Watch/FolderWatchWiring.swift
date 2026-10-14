// Port of the createFolderWatches wiring in apps/desktop/src/main/bootstrap.ts
import Foundation

extension FolderWatches.Dependencies {
    /// The folder watches as the app has them: an FSEvents stream per folder, the folder's modification time
    /// read with `stat`, and `cache` let go of what a change made outside the app touched before the window
    /// is told, so it reads the folder again rather than being handed the listing it had.
    @MainActor
    public static func app(
        cache: ResponseCache, fileSystem: any ExplorerFileSystem = NativeFileSystem(),
        onFolderChanged: @escaping @MainActor (_ windowID: Int, _ change: FolderChange) -> Void
    ) -> FolderWatches.Dependencies {
        FolderWatches.Dependencies(
            watchFolder: { path, onChange, onFail in
                FSEventsFolderWatcher.watchFolder(path: path, onChange: onChange, onFail: onFail)
            },
            readModifiedTime: { path in
                // A disk read, off the main actor.
                await Task.detached(priority: .utility) {
                    (try? fileSystem.stat(path))?.mtimeMs.map(Double.init)
                }.value
            },
            onFolderChanged: onFolderChanged,
            forgetCachedListings: { path, changedPaths in
                cache.forgetFolderListings(path, changedPaths: changedPaths)
            })
    }
}
