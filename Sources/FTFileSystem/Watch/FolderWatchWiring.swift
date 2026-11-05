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
            watchFolder: { path, onChange, onFail in
                let stopFolder = FSEventsFolderWatcher.watchFolder(path: path, onChange: onChange, onFail: onFail)
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
                // A disk read, off the main actor.
                await Task.detached(priority: .utility) {
                    guard let time = (try? fileSystem.stat(path))?.mtimeMs else { return nil }
                    // Added up with the Trash's other folders: a change to any of them changes the total.
                    return trash.listedWith(path).reduce(Double(time)) { total, other in
                        total + Double((try? fileSystem.stat(other))?.mtimeMs ?? 0)
                    }
                }.value
            },
            onFolderChanged: onFolderChanged,
            forgetCachedListings: { path, changedPaths in
                cache.forgetFolderListings(path, changedPaths: changedPaths)
            })
    }
}
