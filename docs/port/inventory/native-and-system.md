# File Trail native layer and system services: inventory and Swift/AppKit mapping

Repo root: `/Users/tcmudemirhan/src/tsproj/filetrail`. All paths below are relative to it. Line numbers are from the current checkout.

## 0. Things to know first

- **The addon.** One N-API addon, `packages/native-fs`. `binding.gyp:5-21` lists 15 sources. It links AppKit, CoreServices, DiskArbitration, Foundation, ImageIO, IOKit, QuickLookThumbnailing and UniformTypeIdentifiers (`binding.gyp:25-55`). The ObjC files use manual retain/release (MRC); there is no `-fobjc-arc`.
- **Module init.** It lives in `native_copyfile.c:299-365` (`NAPI_MODULE(..., init)`), and each file registers itself through a `register_*` function.
- **Threading.** Nearly every async function uses `napi_create_async_work`, so the work runs on the libuv thread pool and a promise is resolved on the JS thread. The exceptions are:
  - folder size spawns its own 4 pthreads;
  - file icons hop to the main queue;
  - thumbnails use a GCD global queue plus a threadsafe function;
  - drag functions and `nativeListVolumes`/`nativeListMounts`/`nativeKindForPath` are synchronous on the caller's thread.
- **Bug: `nativeReadDragChangeCount` is not exported.**
  - It is registered natively (`native_filedrag.m:575-577`) and declared in `index.d.ts:415`.
  - `index.js:88-116` does not re-export it.
  - `apps/desktop/src/main/bootstrap/fileDrag.ts:39-43,195` reads it through `require("@filetrail/native-fs")`, so it gets `undefined`, and `system:readDragChangeCount` throws.
  - The renderer swallows the failure (`renderer/hooks/useExplorerDragAndDrop.ts:828-830`), so the "drag came back, is it the same drag?" check never works. This doesn't matter for the port, but don't use the Electron build as the reference for this behavior.
  - `nativeFolderSizeTakeFinished` is also left out of `index.js`, but on purpose: the wrapper calls `binding.nativeFolderSizeTakeFinished` internally (`index.js:36`).
- **Not sandboxed.** `apps/desktop/scripts/entitlements.mac.plist` has only `cs.allow-jit` and `automation.apple-events`. The app relies on this to spawn `fd`/`hdiutil`/`osascript`/`open`, call DiskArbitration, change Launch Services defaults and walk any path. Keep the Swift app non-sandboxed (Developer ID + hardened runtime + `com.apple.security.automation.apple-events`). Drop `allow-jit`.
- **Info.plist additions.** These are in `apps/desktop/scripts/make-macos-app.sh:186-202`:
  - `NSAppleEventsUsageDescription` (for Empty Trash);
  - `CFBundleDocumentTypes`: Viewer, `LSHandlerRank=Alternate`, `com.apple.disk-image`;
  - bundle id `com.filetrail.desktop`.

---

## 1. Native function inventory

### Error mapping (`native_errors.c`, `native_errors.h`)

- `native_errno_code(int)` (`native_errors.c:20-191`) is a hand-written switch over every macOS errno (it can't rely on libuv's `uv_err_name` inside Electron). Unknown values give `"UNKNOWN"`.
- `native_errno_error(env, errnum, syscall, path, dest)` (`native_errors.c:203-242`) builds a Node-style `Error("<CODE>: <strerror>, <syscall> '<path>'[ -> '<dest>']")` with `code`, `errno`, `syscall`, `path` and optionally `dest`.
- Other error shapes:
  - Folder size uses the custom code `"ECANCELLED"` (double L), not `ECANCELED` (`native_foldersize.c:789`). The copy stop path uses the real `ECANCELED`.
  - Trash errors use the Cocoa message plus an errno mapping plus `cocoaCode` (see the Trash entry below).
  - Eject errors add `reason` (DiskArbitration's own text).
  - Open With errors are plain messages.
- **Swift:** throw `POSIXError(POSIXErrorCode(rawValue: errno)!)` or `CocoaError`, and keep an app-level `enum FileOpError { case exists, crossDevice, busy, noTrash, locked, ... }`. `POSIXErrorCode` already names every errno, so the hand-written table goes away.

### Function-by-function

**`nativeCopyFile(src, dst, stopFlag?: Int32Array) → Promise<void>`** (`native_copyfile.c:101-143, 189-295`; d.ts `:23`)
- APIs: `copyfile(3)` with `COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL | COPYFILE_DATA_SPARSE` (`:112-113`).
- When a stop flag is given:
  - `copyfile_state_alloc` with a `COPYFILE_STATE_STATUS_CB` callback (`:123-130`). The callback `copy_status` (`:73-97`):
    - returns `COPYFILE_QUIT` during `COPYFILE_COPY_DATA` once the flag is set;
    - writes `COPYFILE_STATE_COPIED` into elements 2-3 of the Int32Array, read as one Int64 for progress;
    - on `COPYFILE_ERR`, returns `COPYFILE_SKIP` for a failed xattr unless the xattr is `XATTR_RESOURCEFORK_NAME`. A resource-fork failure quits with the write's errno.
  - A stopped copy reports `ECANCELED` (`:135-138`).
- Threading: libuv pool. Errors come from `native_errno_error(..., "copyfile", src, dst)`.
- JS wrapper: `packages/core/src/fs/stoppableCopy.ts` polls the bytes counter every 250 ms and maps an `AbortSignal` to the flag.
- **Swift:** call `copyfile()` directly from Swift (Darwin module) with the same flags and a `copyfile_callback_t` C closure. Pass context through `COPYFILE_STATE_STATUS_CTX` as an `Unmanaged` pointer to a class holding a `ManagedAtomic<Bool>` and an atomic progress counter. Don't use `FileManager.copyItem`: it has no EXCL, no stop and no sparse support. You could use `clonefile(2)` first and fall back, but `COPYFILE_CLONE` already does that.

**`nativeCopyMetadata(src, dst) → Promise<void>`** (`native_copyfile.c:148-154`)
- `copyfile(..., COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC)`: mode, flags, dates, xattrs (tags, custom icon, quarantine) and ACL onto an existing folder. Not recursive.
- **Swift:** the same `copyfile` call.

**`nativeRenameExclusive(from, to) → Promise<void>`** (`native_rename.c:66-94`)
- `renamex_np(from, to, RENAME_EXCL)`. On `ENOTSUP` it falls back to `lstat(to)` (EEXIST if present) and then `rename(2)`. That leaves a known race window, documented at `:79-83`.
- Errors carry syscall `"rename"`, from and to.
- `RENAME_SWAP` is not used anywhere. A Replace stages the new item, trashes the old one, then does an exclusive rename, all journaled (`packages/core/src/fs/copyPasteExecution.ts:1492-1591,1854`).
- **Swift:** call `renamex_np` from Darwin directly. Consider `RENAME_SWAP` for an atomic Replace, which `FileManager.replaceItemAt` doesn't give you with EXCL semantics.

**`nativeIsCaseSensitive(path) → Promise<bool|null>`** (`native_rename.c:169-182`)
- `pathconf(path, _PC_CASE_SENSITIVE)`. `EINVAL` gives `null`.
- **Swift:** `URLResourceValues.volumeSupportsCaseSensitiveNames` (`.volumeSupportsCaseSensitiveNamesKey`), or `pathconf`.

**`nativeUsesAppleDouble(path) → Promise<bool|null>`** (`native_rename.c:250-272`)
- `getattrlist(2)` with `ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES`, checking `VOL_CAP_INT_EXTENDED_ATTR` in `VOL_CAPABILITIES_INTERFACES`. Native xattrs give false; AppleDouble gives true.
- Used by `isAppleDoubleOnItsVolume` (`packages/core/src/fs/writeServiceTypes.ts:381-411`), which also checks the `0x00051607` magic.
- **Swift:** `getattrlist` from Darwin. There is no `URLResourceKey` for this capability; `volumeSupportsExtendedSecurityKey` is a different one.

**`nativeGetFlags(path) → Promise<number>` / `nativeSetFlags(path, flags)`** (`native_flags.c:34-48`)
- `lstat(2).st_flags` and `lchflags(2)`, without following symlinks. `UF_IMMUTABLE` is Finder's "Locked".
- **Swift:** `lstat`/`lchflags`. For Locked only you could use `URLResourceValues.isUserImmutable`, but keep the raw flags for undo fidelity.

**`nativeGetAcl(path) → Promise<string|null>` / `nativeSetAcl(path, text|null)`** (`native_acl.c:54-120`)
- `acl_get_link_np(path, ACL_TYPE_EXTENDED)` then `acl_to_text`. ENOENT is told apart from "no ACL" with `lstat`.
- Setting uses `acl_from_text` (or `acl_init(0)` for none) then `acl_set_link_np`.
- Used by Undo, to lift and restore `group:everyone deny delete` (`native_acl.c:12-14`).
- **Swift:** the same C calls (`Darwin.acl_*`), or `FileManager.attributesOfItem` (`.posixPermissions` only, so no). Keep the C calls.

**`nativeIsPackage(path) → Promise<bool|null>`** (`native_package.m:26-41`)
- `NSURL getResourceValue:NSURLIsPackageKey`.
- **Swift:** `url.resourceValues(forKeys: [.isPackageKey]).isPackage`.

**`nativeTrashItem(path) → Promise<string|null>`** (`native_trash.m:101-130`)
- `-[NSFileManager trashItemAtURL:resultingItemURL:error:]`, returning the resulting path (it may be renamed, e.g. "notes 2.txt").
- `errno_of` (`:57-99`) maps:
  - a POSIX domain error or underlying POSIX error to that errno;
  - Cocoa `NSFeatureUnsupportedError` to `ENOTSUP`, `NoSuchFile` to `ENOENT`, `NoPermission` to `EACCES`, `VolumeReadOnly` to `EROFS`, `OutOfSpace` to `ENOSPC`, and so on;
  - an underlying `OSStatus -1426` (`errFSOperationNotSupported`) to `ENOTSUP`.
- It rejects with `cocoaCode` and the Cocoa `localizedDescription` (`:141-165`).
- Policy layer `apps/desktop/src/main/bootstrap/trashItem.ts:21-56`:
  - checks Locked first;
  - never offers permanent delete on the startup disk;
  - marks `NO_TRASH_ERROR_CODE` when ENOTSUP, or when there is no errno and `diskHasTrash` is false.
- **Swift:** `try FileManager.default.trashItem(at:resultingItemURL:)`, the same API. Port `errno_of` as a function on `NSError`.

**`nativeGetFileIcon(path, size 16-512) → Promise<PNG|null>`** (`native_fileicon.m:60-163`)
- `NSWorkspace iconForFile:`, `setSize:`, drawn into an `NSBitmapImageRep` (RGBA, 8 bpc, `NSCalibratedRGBColorSpace`), then `representationUsingType:PNG`.
- Threading: the pool thread `dispatch_async`es to the **main queue** and waits on a semaphore for at most 10 s (`:146-155`), with a ref-counted context so a late-running block is safe.
- Always resolves; failure gives `null`.
- **Swift:** `NSWorkspace.shared.icon(forFile:)` returns an `NSImage` that you hand straight to `NSImageView`/the cell. No PNG round-trip is needed. For a type-level icon use `NSWorkspace.shared.icon(for: UTType)`. `icon(forFile:)` is documented as thread-safe on recent macOS, but drawing should stay on the main actor.

**`nativeGetFileThumbnail(path, size 16-1024) → Promise<JPEG|PNG|null>`** (`native_thumbnail.m:156-245`)
- `QLThumbnailGenerationRequest(fileAt:size:scale:1.0, representationTypes:.thumbnail)`.
- `iconMode = !shows_picture(url)`: pictures and video come back as raw content, anything else gets Finder's page-with-shadow style (`:116-125, 226`). The type check is `NSURLContentTypeKey` after resolving symlinks, conforming to `UTTypeImage` or `UTTypeAudiovisualContent`.
- `generateBestRepresentationForRequest`. The result is encoded with `CGImageDestination`: JPEG at quality 0.82 if every pixel is opaque (checked by scanning pixels), PNG otherwise (`:43-112`).
- Threading: GCD global queue (user-initiated), Quick Look works out of process, and the result comes back through `napi_threadsafe_function`. Nothing blocks.
- **Swift:** `QLThumbnailGenerator.shared.generateBestRepresentation(for:)` (async/await), then `thumbnail.nsImage`. Skip the encoding. Set `iconMode` the same way. Use `.thumbnail` only (not `.lowQualityThumbnail`) to match today, or request `[.icon, .thumbnail]` with `generateRepresentations` for progressive display. Scale should be `NSScreen.backingScaleFactor`; today it is 1.0 with a doubled pixel size.

**`nativeKindForPath(path) → string|null`** (sync) (`native_thumbnail.m:251-313`)
- First `MDItemCreate` and `MDItemCopyAttribute(kMDItemKind)` (Spotlight's Kind, e.g. "Markdown Document").
- Then the deprecated `LSCopyKindStringForURL`.
- Then `NSURLLocalizedTypeDescriptionKey`.
- The caller caches by extension (`packages/core/src/fs/explorerService.ts:558-578`).
- **Swift:** `MDItemCreateWithURL` + `MDItemCopyAttribute(kMDItemKind)`, falling back to `url.resourceValues(forKeys:[.localizedTypeDescriptionKey])`. Cache per UTType identifier, not per extension.

**`nativeOpenWithApplications(paths[], appPaths[]) → Promise<{defaultApp, apps[], kinds[], appInfo[]}>`** (`native_openwith.m:248-352`)
- Per path:
  - `NSWorkspace URLForApplicationToOpenURL:` for the default app, asked for each file until two disagree (`:270-280`);
  - `NSURLContentTypeKey` for the UTType;
  - `NSWorkspace URLsForApplicationsToOpenURL:`, asked once per type, de-duplicated by standardized path (`:208-234`).
- Apps are intersected across all paths, keeping Launch Services' order (`:307-316`).
- App info (`:107-132`): `NSURLIsDirectoryKey`, `NSBundle bundleWithURL`, `NSURLLocalizedNameKey` minus ".app", `CFBundleShortVersionString`, `bundleIdentifier`.
- Kind names use `MDItem kMDItemKind`, falling back to `UTType.localizedDescription`. `isFolder` is `conformsTo UTTypeDirectory`.
- Cache: two `NSMutableDictionary` behind an `os_unfair_lock` (`type_cache` keyed by UTI, `app_cache` keyed by app path). When one reaches 1024 entries it is wiped (`:139-161`).
- Result is built as JSON with `NSJSONSerialization`.
- **Swift:** `NSWorkspace.shared.urlForApplication(toOpen: URL)` and `urlsForApplications(toOpen: URL)` (macOS 12+), plus `Bundle(url:)`. Cache with an actor-protected dictionary.

**`nativeSetDefaultApplication(appPath, uti)`** (`native_openwith.m:418-457`)
- Refuses UTIs that conform to `UTTypeDirectory`.
- Calls `NSWorkspace setDefaultApplicationAtURL:toOpenContentType:completionHandler:` and waits on a semaphore for at most 10 s, then clears the cache.
- **Swift:** `try await NSWorkspace.shared.setDefaultApplication(at:toOpen: UTType)`.

**`nativeForgetOpenWithCache()`** (`native_openwith.m:163-168, 516-522`) clears both caches.

**`nativeDatesTaken(paths[]) → Promise<(string|null)[]>`** (`native_datestaken.m:56-104`)
- Checks `UTType typeWithFilenameExtension` conforms to `UTTypeImage` (by extension only).
- `CGImageSourceCreateWithURL` with `kCGImageSourceShouldCache:NO`, then `CGImageSourceCopyPropertiesAtIndex(0)`, then `kCGImagePropertyExifDictionary` → `DateTimeOriginal`, else `DateTimeDigitized`.
- The EXIF string "YYYY:MM:DD HH:MM:SS" becomes local ISO "YYYY-MM-DDTHH:MM:SS"; a "0000" year is rejected.
- Used only by batch rename.
- **Swift:** the same ImageIO calls (`CGImageSourceCopyPropertiesAtIndex`). Optionally also read `kCGImagePropertyExifOffsetTimeOriginal`.

**`nativeFolderSize(path, onFinished?, {background}) → Promise<json>`, `nativeFolderSizeTakeFinished()`, `nativeFolderSizeCancel()`, `nativeItemSize(path)`.** See section 3.

**`nativeListVolumes() → Volume[]` (sync) and `nativeListMounts()` (sync)** (`native_volumes.c:130-196`). See section 6.

**`nativeEjectVolume(path, {force, wholeDisk})`** (`native_eject.c`). See section 6.

**`nativeStartFileDrag(...)`, `nativeReadDragPasteboard()`, `nativeReadDragChangeCount()`** (`native_filedrag.m`). See section 9.

---

## 2. Directory listing (`packages/core/src/fs/explorerService.ts`, worker)

**Where it runs.**
- A Node `worker_thread` (`packages/core/src/worker/explorerWorker.ts`) uses `original-fs` so `.asar` files aren't treated as folders (`:19-36`).
- Two queues: `directory:getMetadataBatch` is low priority; everything else is normal priority (`:96-132, 227-232`). Requests are processed **serially**, one at a time.
- The main process talks to it through `ExplorerWorkerClient` (`explorerWorkerClient.ts`).
- **Swift:** a `actor DirectoryService` or a dedicated serial `DispatchQueue`/`OperationQueue` with two priorities. No `.asar` concern.

**Snapshot** (`listDirectorySnapshot`, `explorerService.ts:78-136`).
- `resolveDirectoryPath` (`:361-373`): `stat` must be a directory, then `realpath`, so aliased paths collapse to one.
- `readdir(withFileTypes)`, so only the d_type of each entry is read.
- Per entry:
  - **Hidden**: dot-prefix only (`isHiddenName`, `:531-533`), filtered unless `includeHidden`. `UF_HIDDEN` / `NSURLIsHiddenKey` are not consulted, so items like `/usr` would show.
  - **Kind** (`classifyEntry`, `:323-346`):
    - A directory is `"bundle"` if the name's extension is in a hard-coded list (`packages/contracts/src/itemName.ts:31-46`: `.app .framework .bundle .plugin .kext .xpc .xcodeproj .playground .prefpane .appex`), otherwise `"directory"`.
    - A symlink is `stat`ed and becomes `symlink_directory` or `symlink_file` (or `other` if broken).
    - Packages are not detected through `NSURLIsPackageKey` here (that is only used in write operations), so Keynote/Pages documents and `.photoslibrary` show as plain folders in listings.
  - **Finder aliases** (bookmark files) are not resolved anywhere. They appear as files. Only POSIX symlinks are labelled "Alias File"/"Alias Folder" (`:585-590`).
  - **Localized names**: not used. Raw `dirent.name` throughout (no `NSURLLocalizedNameKey`); the only special case is "/" named "Macintosh HD" (`:178`).
  - **Extra stat** only when the sort needs it (`modified`/`size`), or for extension-less files, to set `isExecutable` from `mode & 0o111` (`:96-102`).
- Output entry fields: `path, name, extension, kind, isHidden, isSymlink, isExecutable?, sizeBytes?` (size only when sorting by size).

**Sorting** (`compareEntries`, `:452-511`).
- `foldersFirst` (directory or symlink_directory; bundles count as files), then the sort key, with nulls last in both directions, then name as tiebreak, and desc negates.
- Name compare is `localeCompare(undefined, {numeric:true, sensitivity:"base"})`, i.e. Finder-like natural sort, case- and diacritic-insensitive.
- Kind sort compares the kind label.
- **Swift:** `String.localizedStandardCompare(_:)`, which is exactly Finder's comparator.

**Metadata batch** (`getDirectoryMetadataBatch`, `:140-159, 276-295`).
- Paths must all be direct children of the directory.
- Per path: `lstat` + `stat`, giving `kindLabel`, `createdAt` (birthtime), `modifiedAt` (mtime), `sizeBytes`/`sizeStatus`, and `permissionMode & 0o777`.
- Folder size is `"deferred"`; a symlinked folder gets the link's own size (`:300-314`).
- The renderer asks only for visible/prioritized paths and keeps its own per-path cache and in-flight set (`renderer/hooks/useExplorerNavigationController.ts:2225-2285`).

**Item properties for Get Info** (`getItemProperties`, `:163-190`): the same fields plus `name`, `extension`, `isHidden`, `isSymlink`.

**Tree children** (`:43-74`): folders and symlinked folders only, sorted by name.

**Path suggestions** (`:194-254`): deepest existing prefix, prefix match (case-insensitive), folders only, limit 12.

**Paging / streaming.**
- None at the data layer: the whole `readdir` result is returned as one snapshot; there is no cursor.
- Visible-range lazy metadata is the only "paging". `MAX_PATHS_PER_REQUEST = 100_000` (`packages/contracts/src/limits.ts:6`).
- The renderer's "list paging" is only keyboard Page Up/Down.

**responseCache** (`apps/desktop/src/main/bootstrap/responseCache.ts`).
- TTL caches of **3 s** (`:9`), keyed by the `JSON.stringify(payload)`:
  - directory snapshots (max 64);
  - tree children (max 256);
  - metadata per path (max 5000).
- Oldest-first eviction with a sweep on insert (`:152-169`).
- `cacheGeneration` stops storing a result whose load started before a clear (`:52, 770-775`).
- `clearResponseCaches(changedPaths, removedItems)` after any write clears everything and notifies the folder-size listeners (`:83-96`).
- `forgetFolderListings(folder, changedPaths|null)` after a watch event drops only that folder's listings (and the parent's when the change is unknown) and the affected metadata (`:103-132`).
- `withTiming` logs anything slower than 120 ms (`:742-756`).

**Swift recommendation for listing.**
- Use `FileManager.default.contentsOfDirectory(at:includingPropertiesForKeys:options:)`, or better an `FileManager.enumerator(at:includingPropertiesForKeys:options:[.skipsSubdirectoryDescendants])`, prefetching `[.nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .isAliasFileKey, .localizedNameKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentTypeKey, .localizedTypeDescriptionKey, .isExecutableKey]`.
- That replaces the readdir + stat-per-entry pattern and lets you fix the package, hidden-flag and alias gaps with real system answers.
- For very large folders (100k+ entries), use `getattrlistbulk(2)` (already proven in `native_foldersize.c`) for the hot path, with `ATTR_CMN_NAME | OBJTYPE | MODTIME | CRTIME | FLAGS | ATTR_FILE_DATALENGTH`. It is several times faster than URL resource values.
- Resolve aliases with `URL(resolvingAliasFileAt:)`, and sort with `localizedStandardCompare`.

---

## 3. Folder size

**Native algorithm** (`native_foldersize.c`).
- Root: `open(O_RDONLY|O_DIRECTORY)` + `fstat` to get `root_dev` (`:567-580`).
- A shared LIFO work queue of `(fd, walk_dir_t*)` with mutex + condvar (`:172-290`) is drained by **4 pthreads** (`NUM_THREADS 4`, `:67`). Background requests get `pthread_attr_set_qos_class_np(QOS_CLASS_UTILITY)` (`:613-626`).
- Each directory is read with `getattrlistbulk(dirfd, attrs, 256 KiB buf)` (`:66, 345`). The attributes (`init_attrlist`, `:297-308`) are `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE`, `ATTR_DIR_MOUNTSTATUS`, `ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH`.
- Counting:
  - `VREG`/`VLNK`: adds the data length to logical size and the alloc size to disk size; `fileCount++`. Symlinks are not followed.
  - `VDIR`: `folderCount++`. If `DIR_MNTSTATUS_MNTPOINT` it is skipped (so `/System/Volumes/Data` is skipped and the firmlinks are walked instead). Otherwise `openat(O_DIRECTORY|O_NOFOLLOW)`, then `fstat` to check `st_dev == root_dev`, then push to the queue (`:411-453`).
  - Open errors `EACCES/EPERM/ENOENT/ENOTDIR/ELOOP` are skipped (counted as an empty folder, as Finder does). Other errors mark the folder "incomplete" (`:209-215`).
  - A `getattrlistbulk` failure part way marks it incomplete (`:346-350`).
- Packages are walked like folders, and their contents count.
- **No hard-link dedup.** Every `VREG` entry is added; there is no inode/linkcount tracking. Hard-linked files (e.g. Time Machine-style trees, Xcode DerivedData) are counted once per link. **No clone dedup** either: APFS clones count their full alloc size each time, as Finder's "on disk" also does.
- Completion counting: each `walk_dir_t` has an atomic `pending` (its own listing plus unfinished children). The thread that brings it to 0 pushes it onto the finished list and adds its totals to the parent's (`finish_part`, `:479-507`). Incomplete folders aren't finished and taint their ancestors. A root that ends incomplete fails with the first read errno (`:649-651`).
- Streaming: JS polls `nativeFolderSizeTakeFinished` every **200 ms** (`index.js:12-42`) and gets `{"dev":N,"dirs":{path:[size,disk,files,folders]}}`. The final result carries the totals plus the leftover dirs (`:727-746`).
- Cancellation: `nativeFolderSizeCancel` sets `active_work->cancelled` (atomic), which every worker checks per `getattrlistbulk` batch and in `wq_pop`. The error has code `ECANCELLED` and an `error.finished` JSON of the whole folders done before the stop (`:786-795`; `index.js:65-73`).
- Only one walk runs at a time (a single `active_work` slot); `index.js:9-86` serializes later calls into a FIFO.
- `nativeItemSize(path)` (`:932-966`): `lstat`, then `getattrlist(FSOPT_NOFOLLOW, ATTR_FILE_ALLOCSIZE|DATALENGTH)`, giving `{kind:file|folder|other, sizeBytes, diskBytes, dev}`. Used to adjust totals after a delete.

**Cache and job management** (`responseCache.ts:211-678`, `folderSizeCache.ts`).
- `FolderSizeCache` (`folderSizeCache.ts:8-189`) keeps **every** measured dir forever (no TTL), keyed by path, with `{sizeBytes, diskBytes, fileCount, folderCount, dev, measurement#}`. A `children` index (parent to child set) makes `forgetAtOrInside` and holder walks cheap. It can hold hundreds of thousands of entries after measuring home.
- Jobs: `start` answers at once from the cache, or runs, or queues.
  - Each window has at most one queued job; a new request from the same window cancels its own active walk (`:554-566`), but another window's walk is left to finish.
  - `automatic` requests run as background (utility QoS).
  - At most 256 finished jobs are kept (`:18, 182-198`).
  - The renderer polls `folderSize:getStatus` every 200 ms (`renderer/hooks/useFolderSizeCache.ts:22`) and also gets the `filetrail:folderSizeSettled` push.
  - `probeMany` answers only from the cache, so every folder on screen costs one lookup.
- Home-Trash tracking: `homeTrashCounted` records whether a walk could read `~/.Trash`, which needs Full Disk Access (`:233-237, 360-370, 418-422, 455-457`).
- Write interaction:
  - `noteWriteStarting`/`Ended` turn recording on and off, so sizes stored mid-write can be thrown away.
  - A running walk whose path is touched by a write is marked outdated, cancelled and rerun (`:249-268, 423-426, 449-452, 488-495`).

**Adjust after writes** (`folderSizeAdjust.ts:50-232`).
- After a delete or trash, each cached ancestor of the removed item has the item's contribution subtracted, but **only when exact**. `countedIn` walks from the item's parent up to the folder, requiring every intermediate to be cached from the same `measurement#` and `dev` (`:143-169`). Otherwise the folder's size is forgotten.
- A file contributes its size, disk size and 1 file. A folder contributes its own cached totals plus 1 folder, or only 1 folder if it is on another device (`:174-207`).
- An item moved into `~/.Trash` is added to the Trash's size and to its holders if `homeTrashCounted` (`:77-106`).
- Any negative result means it is forgotten (`:220-232`).
- Other changed paths go through `forgetAffected`: holders and descendants are forgotten.

**Swift recommendation.**
- Port the C walker almost verbatim. `getattrlistbulk` is callable from Swift, but buffer parsing is easier in a small C target inside the Swift package; keep it as C.
- Use `DispatchQueue.concurrentPerform` or a `TaskGroup` with 4 workers and `.utility` QoS for background walks. Cancel with `ManagedAtomic<Bool>`/`Task.isCancelled`. Stream finished dirs through `AsyncStream<[String: DirStats]>` instead of 200 ms polling.
- To add hard-link dedup: request `ATTR_FILE_LINKCOUNT` + `ATTR_CMN_FILEID`, and dedup `(dev, fileid)` when linkcount > 1, using a concurrent set.
- Port `FolderSizeCache` and `adjustForRemovals` as plain Swift classes; they are pure logic.
- Don't use `URLResourceValues.totalFileAllocatedSize` per file: it is about 10x slower.

---

## 4. Search via bundled fd

- **Binary.** `apps/desktop/assets/vendor/fd/darwin-arm64/fd`: fd **10.5.0**, Mach-O arm64 only, **2,970,480 bytes (about 2.8 MB)**. The manifest is `apps/desktop/assets/vendor/fd/manifest.json`; the archive SHA-256 there is **not verified at runtime** (only read for the About box).
- **Resolution.** `fdBinary.ts:20-56` tries several candidate paths (`dist/assets`, `resourcesPath/app/dist/assets`, `cwd`, source tree) and throws on non-arm64.
- **Invocation** (`packages/core/src/search/fdSearch.ts:62-104, 118-153`): `spawn(fdPath, args, {cwd: root, stdio:[ignore,pipe,pipe]})` inside the explorer worker.
- **Arguments:**
  - Always: `--type f --type d --print0 --absolute-path --color never`. Symlinks are never returned.
  - `--no-ignore` unless `skipGitIgnored`; the default is false, so gitignore is **not** respected by default.
  - `--exclude .git` if `skipGitFolders` (default true).
  - root `/` adds `--exclude /Volumes`.
  - `patternMode`: `"glob"` adds `--glob`; `"text"` (the default) adds `--fixed-strings`; `"regex"` adds nothing (fd regex).
  - `matchScope === "path"` adds `--full-path` (the default is `name`).
  - `!recursive` adds `--max-depth 1`.
  - `includeHidden` adds `--hidden`.
  - Finally `-- <query> <root>`.
  - Case sensitivity is fd's default **smart case**; no flag is passed.
  - Contract defaults are at `packages/contracts/src/ipc.ts:1077-1088`.
- **Streaming.**
  - stdout is split on NUL (`:240-266`). A trailing `/` marks a folder.
  - Each result item has `path, name, extension, kind (file | bundle by name list | directory), isHidden (dot), isSymlink:false, parentPath, relativeParentPath` (`:348-366`).
  - Results are stored in the job; the renderer polls `search:getUpdate(jobId, cursor)` every **120 ms**, or every 1000 ms for background tabs (`renderer/hooks/useExplorerSearchController.ts:41`, `useExplorerTabs.ts:46`).
  - The final poll drains and frees the job; up to 64 finished-job tombstones keep later polls idempotent (`:155-193, 224-238`).
- **Limit.** `SEARCH_RESULT_LIMIT = 20_000` (`:7`). On reaching it the job is `truncated` and fd gets SIGTERM (`:276-285`).
- **Cancellation.** `cancelSearch` sends SIGTERM (`:195-210`). On app quit the worker gets a `{close:true}` message and kills all fd processes (`explorerWorker.ts:100-107`, `explorerWorkerClient.ts:110-126`).
- **Errors.** stderr is captured and cleaned by `describeFdError` (`:340-345`).
- **Swift port choice.**
  - **(a) Keep fd.** About 2.9 MB more in the bundle; the arm64 slice is enough since the app is arm64-only, otherwise it would need `lipo` for universal. Embed it in `Contents/Helpers/` or `Contents/Resources/`, codesign it with the hardened runtime as part of the bundle, and run it with `Process` + `Pipe` (`FileHandle.readabilityHandler` or `bytes.async`), parse NUL-separated output into an `AsyncStream`, and kill with `process.terminate()`. Behavior stays identical, including gitignore support (fd's main differentiator).
  - **(b) Replace it natively.** A parallel `getattrlistbulk` walker (the folder-size engine) plus `NSRegularExpression`/`fnmatch(3)`/`localizedStandardContains`. That drops the binary but loses `.gitignore`/`.ignore` semantics unless you reimplement them.
  - **(c) Spotlight.** `NSMetadataQuery`/`MDQuery` is fast but index-dependent and different semantics; good as an optional "Spotlight" mode, not a drop-in.
  - **Recommendation:** keep fd for parity in v1 (only 2.9 MB); revisit later.

---

## 5. Folder watching

- **Mechanism.** Node `fs.watch(path, cb)` (`apps/desktop/src/main/bootstrap.ts:178-191`). On macOS, libuv backs `fs.watch` on a directory with an **FSEvents** stream (the comment at `folderWatch.ts:9-10` says so); for files it would be kqueue.
  - `name` is the changed entry's name relative to the watched folder.
  - An `"error"` event triggers `onFail`, which restarts the watch later.
- Only the **front tab's folder per window** is watched (one watch per webContents id). A watch is started or replaced on each `folder:watch` IPC and stopped on navigation or destroy (`bootstrap.ts:369-385`).
- **Debounce** (`folderWatch.ts:12-17, 96-121`):
  - settle **250 ms** after the last event;
  - at most one notification per **1000 ms** during a continuous burst;
  - more than **1000** changed names, an empty name, or the folder's own basename means `changedPaths = null` ("anything changed").
- **What triggers a refresh.**
  - `tell()` first calls `forgetFolderListings` (cache invalidation), then sends `filetrail:folderChanged {path, changedPaths}` to the window (`:82-94`).
  - The renderer `useFolderWatch` holds changes while a rename, menu, sheet or write is in progress, retries every 250 ms if the folder is still loading, and re-reads the listing and the changed items' metadata (`renderer/hooks/useFolderWatch.ts`).
- **Missed-change safety net.** On `browser-window-focus`, `checkForMissedChanges` compares the folder's `mtimeMs` with the value recorded after the last notification, and restarts a failed watch (`folderWatch.ts:136-156, 196-205`; `bootstrap.ts:197-199`). This covers network shares where FSEvents is unreliable.
- **/Volumes.** Watched separately with `fs.watch("/Volumes")` and a 250 ms settle (`volumes.ts:9, 75-83`).
- **Swift.**
  - Use `FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot`, latency about 0.1-0.25 s, scheduled with `FSEventStreamSetDispatchQueue`.
  - Filter events to direct children (FSEvents is recursive). With `FileEvents` you get full paths, which is better than Node's names.
  - `WatchRoot` gives rename and delete of the folder itself.
  - Alternatively, for a single directory, `DispatchSource.makeFileSystemObjectSource(fileDescriptor: open(path,O_EVTONLY), eventMask: [.write,.rename,.delete])` (kqueue). It is cheap but gives no names.
  - Keep the 250/1000 ms debounce and the mtime-on-activate check (`NSApplication.didBecomeActiveNotification` / `NSWindow.didBecomeKeyNotification`).

---

## 6. Volumes, Eject, disk images

**Enumeration** (`native_volumes.c:130-179`).
- `getmntinfo(&mounts, MNT_NOWAIT)` reads the kernel table without touching filesystems, so it never blocks on a dead network share.
- Kept: only `/Volumes/<name>` (no nested paths, no hidden names) without `MNT_DONTBROWSE`.
- Fields: `path, name (last component), isLocal (MNT_LOCAL), isReadOnly (MNT_RDONLY), fileSystem (f_fstypename), canEject, disk`.
- `volume_physical_disk(bsd)` (`:52-116`) uses IOKit:
  - `IOServiceGetMatchingService(IOBSDNameMatching)`, then walks parents in `kIOServicePlane` for the topmost `IOMedia` with `kIOMediaWholeKey` (crossing APFS container to physical store);
  - reads `kIOBSDNameKey`;
  - `ejectable = Ejectable || Removable || "Physical Interconnect Location" != "Internal"` (from `Protocol Characteristics`, searched up the parents).
  - Non-`/dev/` sources (network shares) get `canEject = true` and `disk = null`.
- `nativeListMounts` (`:181-196`) returns every mount `{path, isLocal}`, used by `diskHasTrash` (`bootstrap/diskHasTrash.ts:13-30`): the longest mount prefix of the realpath, case-insensitive. A network share is assumed to have no Trash.
- Watcher (`volumes.ts:52-96`): re-list on `/Volumes` change (250 ms settle), on window focus, after an eject, and after a disk image mount. Sorted naturally by name (`:27-31`). A change is broadcast as `filetrail:volumesChanged`.
- Volume capacity for Get Info: Node `statfs(path)`, `bavail*bsize` and `blocks*bsize` (`bootstrap/systemHandlers.ts:58-70`).
- `getDiskIds`: `stat(path).dev`, following symlinks, used to tell a move from a copy on drag (`bootstrap/diskIds.ts:10-24`).

**Eject** (`native_eject.c`).
- `statfs(path)` must be a mount point, otherwise `ENOENT` (`:195-198`).
- A `DASessionCreate` on a private serial dispatch queue (`:242-252`).
- Unmount: `DADiskCreateFromVolumePath` then `DADiskUnmount(kDADiskUnmountOptionDefault | Force)`. If DiskArbitration doesn't know the mount, it falls back to `unmount(2)` with `MNT_FORCE` (`:138-165`).
- `wholeDisk`:
  - unmount this volume first, so a refusal names it;
  - then every other mount whose physical disk matches (re-scan `getmntinfo`);
  - then `DADiskCreateFromBSDName(whole)` + `DADiskEject`. An eject failing with `ENOTSUP` (internal drive) is treated as success (`:193-237, 167-191`).
- Each DA call waits on a semaphore for at most **120 s**, giving `ETIMEDOUT` (`:44, 121-136`).
- Status mapping `errno_of_status` (`:81-102`): `unix_err(x)` (`(status & ~0x3fff)==0xc000`) unwraps to x; `Busy/ExclusiveAccess` → `EBUSY`; `NotFound` → `ENOENT`; `NotPermitted` → `EPERM`; `NotPrivileged` → `EACCES`; `NotReady` → `EAGAIN`; `Unsupported` → `ENOTSUP`; anything else → `EIO`. `DADissenterGetStatusString` becomes `reason`.
- JS policy (`volumes.ts:103-126`): `ENOENT` on the requested path counts as ejected; `EBUSY` gives `status:"busy"`, otherwise `"failed"`.
- Renderer:
  - `planEject` asks "Eject All / Eject (this volume only)" when the disk has several volumes (`renderer/hooks/useEjectVolume.ts:68-97`).
  - On busy it shows Finder's text with **Force Eject / Try Again / Cancel**, retrying on the busy path with `force:true` (`renderer/lib/eject.ts:96-101`, `useEjectVolume.ts:99-105`).
- **Swift.**
  - The simplest path is `NSWorkspace.shared.unmountAndEjectDevice(at: URL) throws`. It ejects the whole device, gives no force option and no per-volume choice, and its error lacks the dissenter text.
  - For parity, keep DiskArbitration from Swift: `DASessionCreate`, `DASessionSetDispatchQueue`, `DADiskUnmount`/`DADiskEject` with callbacks bridged to `withCheckedThrowingContinuation`; `DADiskCopyDescription` gives `kDADiskDescriptionMediaWholeKey`, `MediaEjectableKey`, `MediaRemovableKey`, `DeviceInternalKey`, `VolumeNetworkKey`, `MediaBSDNameKey` (that replaces the IOKit walk, except the APFS container to physical store hop, for which keep `DADiskCopyWholeDisk` plus the IOKit parent walk).
  - Enumerate with `FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:[.volumeNameKey,.volumeIsLocalKey,.volumeIsReadOnlyKey,.volumeIsEjectableKey,.volumeIsRemovableKey,.volumeIsInternalKey,.volumeIsBrowsableKey,.volumeTotalCapacityKey,.volumeAvailableCapacityForImportantUsageKey], options:[.skipHiddenVolumes])`. **Caution:** resource values can block on dead shares; `getmntinfo(MNT_NOWAIT)` was chosen deliberately to avoid that, so keep it for the synchronous sidebar list.
  - For mount/unmount notifications use `NSWorkspace.didMountNotification` / `didUnmountNotification` / `didRenameVolumeNotification` (better than watching `/Volumes`), or `DARegisterDiskAppearedCallback`.

**Disk images** (`apps/desktop/src/main/diskImages.ts`, `shared/diskImages.ts`).
- Extensions handled (`shared/diskImages.ts:4-17`): `dmg udif img toast dvdr cdr dmgpart iso sparseimage asif sparsebundle backupbundle`.
- Flow (`diskImages.ts:57-88`):
  1. `/usr/bin/hdiutil isencrypted -plist`. If encrypted, hand off to `open -a /System/Library/CoreServices/DiskImageMounter.app` (DiskImageMounter asks for the password in its own UI).
  2. `hdiutil imageinfo -plist`. If it has a "Software License Agreement", hand off the same way.
  3. `hdiutil attach -plist -noautoopen <image>`, with stdin ignored so a prompt is auto-declined. Stderr "attach canceled" means hand off; "attach failed - X" gives `reason` X.
  4. On success, refresh volumes and open the first `mount-point` sorted by name in a tab.
- Plist parsing is a regex (`:135-162`). Re-entrancy guard: the same image while opening gives `"busy"` (`:42, 90-101`).
- `app.on("open-file")` takes only disk images, queued until windows exist (`apps/desktop/src/main/main.ts:312-357`). The Info.plist registers `com.apple.disk-image` as Alternate Viewer.
- **Swift:**
  - keep `Process` running `hdiutil` (no public DiskImages framework; `DIHLDiskImageAttach` is private);
  - parse with `PropertyListSerialization` instead of regex;
  - hand off with `NSWorkspace.shared.open([url], withApplicationAt: DiskImageMounter.app, configuration:)`;
  - receive opens via `NSApplicationDelegate.application(_:open:)` and declare `CFBundleDocumentTypes` the same way.

---

## 7. Open With / default app / Always Open With / pinned apps

- **Lookup.** `system:getOpenWithApplications(paths, pinnedAppPaths)` calls `nativeOpenWithApplications` (section 1) and maps `appInfo` to `pinnedApps` (`bootstrap/systemHandlers.ts:172-197`). If Launch Services fails, it falls back to the pinned apps that exist on disk, named from the path.
- **Pinned apps.** A user preference `openWithApplications: {id, appPath, appName}[]` (`shared/appPreferences.ts:46-48, 242, 315, 419`), persisted in `userData/app-state.json` (`main/appStateStore.ts:457`).
- **Caching layers:**
  - native per-UTI and per-app caches (1024 cap, wiped on overflow);
  - cleared on every `browser-window-focus` (`bootstrap.ts:174-176`) and after `setDefault`;
  - renderer per-client LRU of 64 lookups keyed by `[paths, pinnedAppPaths]`, plus a generation counter (`renderer/hooks/useOpenWithLookup.ts:7-60`).
- **Opening.**
  - `open -a <app> <paths...>` via `execFile` (`systemHandlers.ts:135-168`).
  - Choosing Finder (`/System/Library/CoreServices/Finder.app`, `shared/finder.ts:3`) means `open -R <paths>` (reveal) instead.
  - `isValidApplicationBundlePath` requires an absolute path ending in `.app` with no `..` (`:297-306`).
  - Default open (double-click) is `shell.openPath(path)` (`:30-38`).
- **Always Open With.** `nativeSetDefaultApplication(app, uti)` (section 1), refused for directory types.
- **Other… picker.** `dialog.showOpenDialog` on `/Applications` filtered to `.app` (`:85-111`).
- **Swift:**
  - `NSWorkspace.shared.urlsForApplications(toOpen:)` / `urlForApplication(toOpen:)`;
  - open with `NSWorkspace.shared.open(_ urls:[URL], withApplicationAt:configuration:)` (async, returns `NSRunningApplication`);
  - reveal with `NSWorkspace.shared.activateFileViewerSelecting([URL])`;
  - default open with `NSWorkspace.shared.open(url)`;
  - set default with `setDefaultApplication(at:toOpen:)`;
  - picker is an `NSOpenPanel` with `allowedContentTypes=[.application]`;
  - invalidate caches on `NSApplication.didBecomeActiveNotification`.
  - App icons in the menu come from `NSWorkspace.icon(forFile: appPath)`.

---

## 8. Icons, thumbnails, Quick Look

**Icons.**
- Main side: `system:getFileIcon {path, size, generic?}` (`systemHandlers.ts:418-430`). For generic kinds it uses sample items created in `$TMPDIR/filetrail-icon-samples/` (an empty folder, a 0644 file, a 0755 executable, `:395-416`) so `iconForFile` returns the plain kind icon; then `nativeGetFileIcon` and base64.
- Renderer cache (`renderer/lib/fileIcons.tsx`):
  - an LRU of **2048** entries (`:14-15`);
  - sizes **64 px** for rows and **128 px** for icon view (`:18-19`);
  - the Get Info icon load is deferred 80 ms (`:22`);
  - pending requests are de-duplicated;
  - plain folder and plain file icons are preloaded at both sizes (`:86-97`).
- Cache key strategy (`:176-243`):
  - `ext:<ext>` for files with an extension;
  - `kind:file` / `kind:executable` for extension-less files;
  - `kind:directory` for ordinary folders;
  - `path:` for bundles, symlinks, `other`, volume roots and special folders (Applications, Desktop, Documents, Downloads, Library, …).
  - Consequence: custom folder icons on non-special folders are **not** shown.
- **Swift:**
  - `NSWorkspace.shared.icon(forFile:)` per item (it is internally cached by IconServices), or `icon(for: UTType)` for type-level icons;
  - an `NSCache<NSString, NSImage>` keyed the same way;
  - `NSImage` is resolution-independent, so there is no need to pick 64/128 px.
  - For custom folder icons, check `URLResourceValues.hasCustomIcon` (`kMDItem`/FinderInfo flag) or always use per-path icons for folders.

**Thumbnails.**
- `system:getFileThumbnail {path, size, knownVersion}` (`systemHandlers.ts:435-458`).
- Version is `mtimeMs:size`; if it matches `knownVersion` the answer is `{unchanged:true}`. Otherwise `nativeGetFileThumbnail` builds a data URL (JPEG detected by `FF D8`).
- Renderer (`renderer/lib/fileThumbnails.tsx:11-17`): **128 px**, LRU of **500**, at most **4 concurrent** loads.
- **Swift:**
  - `QLThumbnailGenerator.generateBestRepresentation`, or `generateRepresentations` for progressive icon then thumbnail;
  - `NSCache` keyed by `(path, contentModificationDate, fileSize)`;
  - a 4-wide `AsyncSemaphore`/`OperationQueue` with `maxConcurrentOperationCount = 4`;
  - cancel by keeping the request and calling `QLThumbnailGenerator.cancel(_:)` when a cell is reused (not possible today).

**Quick Look panel.**
- Space (`shared/shortcuts.ts:245-249`) and the Get Info button both send `system:quickLook {path}`, which calls `BrowserWindow.previewFile(path, basename)` (`systemHandlers.ts:73-83`). That is Electron's wrapper around `QLPreviewPanel`, for a **single file** only.
- **Swift:**
  - `QLPreviewPanel.shared()` with your view controller in the responder chain implementing `acceptsPreviewPanelControl`, `beginPreviewPanelControl`/`endPreviewPanelControl`;
  - a `QLPreviewPanelDataSource` returning the multiple selected URLs (`QLPreviewItem` is satisfied by `NSURL`);
  - a `QLPreviewPanelDelegate` with `sourceFrameOnScreen(for:)` and `transitionImage` for the zoom animation;
  - `previewPanel(_:handle:)` to forward arrow keys so the selection follows.
  - This is an upgrade: multi-selection and live selection follow are possible natively.

---

## 9. File drag in and out

**Drag out** (`native_filedrag.m:314-508`; `bootstrap/fileDrag.ts:59-112`).
- The renderer measures each visible item's icon and name rects (CSS px, times the zoom factor) plus an optional thumbnail data URL. The main process calls `nativeStartFileDrag(getNativeWindowHandle(), paths, directories, images, onEnded)` on the main thread.
- Native side:
  - Requires the left mouse button still down: `[NSEvent pressedMouseButtons] & 1` (`:412`).
  - Synthesizes a `NSEventTypeLeftMouseDragged` event at the current mouse location (`:418-429`).
  - One `NSDraggingItem` per path with `pasteboardWriter = NSURL fileURLWithPath:isDirectory:`, so it writes file URLs only. There are no file promises, so nothing like `NSFilePromiseProvider`.
  - Drag images:
    - icon component: the thumbnail if given, else `NSWorkspace iconForFile:`, fitted into `iconRect`;
    - label component: a pill on `NSColor selectedContentBackgroundColor`, white system font, middle-truncated, max 240 pt (`:162-186`);
    - items not on screen share the first item's frame and are invisible; with none placed, the first item is drawn at the pointer at 64 pt (`:221-235, 462-472`).
  - `[view beginDraggingSessionWithItems:event:source:]` with `animatesToStartingPositionsOnCancelOrFail = YES` and `draggingFormation = NSDraggingFormationStack` (`:482-492`). Exceptions are caught with `@try`.
  - `FileTrailDragSource` (`:89-156`):
    - `sourceOperationMaskForDraggingContext`: within the app, `Copy|Move`; outside, `Copy|Move|Generic|Link|Delete`.
    - `ignoreModifierKeysForDraggingSession` is YES only while over one of the app's own windows (`windowNumberAtPoint` + `NSApp windowWithWindowNumber`), so the page reads ⌥/⌘ itself.
    - `endedAtPoint:operation:` maps the operation (Delete > Move/Generic > Copy > Link > none) and where it ended (this window, another app window, elsewhere), then calls `onEnded` through a threadsafe function. It self-retains for the drag's lifetime.
- After the drop, `findDraggedAway` `lstat`s the dragged paths. Missing ones (`ENOENT`) clear caches (plus `~/.Trash` if it went to the Trash) and broadcast `filetrail:draggedAway` (`fileDrag.ts:118-147`).

**Drag in.**
- The Chromium web view receives HTML5 drag events. While a drag is over the window, the renderer calls `system:readDraggedIn`, which runs `nativeReadDragPasteboard()`:
  - `[NSPasteboard pasteboardWithName:NSPasteboardNameDrag]`, `changeCount`, `readObjectsForClasses:@[NSURL] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}`;
  - `url.filePathURL.path` resolves Finder's `file:///.file/id=` reference URLs;
  - de-duplicated with an ordered set (`native_filedrag.m:517-550`).
- `readDraggedIn` then `lstat`s/`stat`s each path to classify `file / directory / symlink_*`, drops unreadable ones, and refuses everything if there are more than 100,000 paths (`fileDrag.ts:152-189`).
- The drop itself uses `webUtils.getPathForFile(file)` (`preload/index.ts:195-199`).
- Promised files (Mail attachments, Photos) are **not supported**: no `NSFilePromiseReceiver`.
- `system:readDragChangeCount` is meant to tell a new drag from the known one, but is broken (section 0).
- `bringWindowToFront` (`fileDrag.ts:204-230`): `app.focus({steal:true})` + `show` + `focus`; if the window isn't focused after 250 ms, the Dock icon bounces (`app.dock.bounce("informational")`).
- Move vs copy decision: same `st_dev` (`getDiskIds`) means move, otherwise copy. ⌥ forces copy, ⌘ forces move, as in Finder.

**Swift.**
- Drag out:
  - `NSCollectionView`/`NSTableView` give this almost free via `pasteboardWriterForItemAt`/`pasteboardWriterForRow` returning `NSURL` (or `NSPasteboardItem` with `.fileURL`);
  - `draggingSession(_:sourceOperationMaskFor:)`;
  - `draggingSession(_:endedAt:operation:)`;
  - `ignoreModifierKeys(for:)`;
  - set `draggingFormation = .stack` and `animatesToStartingPositionsOnCancelOrFail`;
  - for custom images use `NSDraggingItem.imageComponentsProvider` exactly as now;
  - the synthesized mouse event goes away because the real `mouseDragged` event is available.
- Drag in:
  - `registerForDraggedTypes([.fileURL, NSFilePromiseReceiver.readableDraggedTypes...])`;
  - in `draggingEntered`/`draggingUpdated`, read `sender.draggingPasteboard.readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true])`;
  - `sender.draggingSequenceNumber` replaces the change-count workaround;
  - add `NSFilePromiseReceiver.receivePromisedFiles(atDestination:options:operationQueue:)` to support Mail and Photos;
  - use `NSRunningApplication.current.activate(options:)` / `NSApp.activate()` and `NSApp.requestUserAttention(.informationalRequest)` for the bounce.

---

## 10. Other system-level features

- **Open in Terminal** (`systemHandlers.ts:218-260, 320-327`).
  - Target is the folder itself, or the parent folder for a file.
  - `open -a <terminalApp.appPath or "Terminal"> <dir>`.
  - The terminal app is a preference (`terminalApp`, default Terminal at `/System/Applications/Utilities/Terminal.app`, `shared/appPreferences.ts:273`).
  - **Swift:** `NSWorkspace.shared.open([dirURL], withApplicationAt: terminalURL, configuration:)`. Terminal/iTerm/Ghostty accept a folder URL.
- **Edit in Text Editor** (⌘⇧E). `openPathsWithApplication([path], defaultTextEditor.appPath)` with the default `/System/Applications/TextEdit.app` (`shared/appPreferences.ts:268-270`; `renderer/hooks/useExplorerActions.ts:2660-2661`). **Swift:** the same `NSWorkspace.open(_:withApplicationAt:)`.
- **Show in Finder.** Routed as Open With Finder, which runs `open -R paths` (`useExplorerActions.ts:2730-2735`, `systemHandlers.ts:153-155`). **Swift:** `NSWorkspace.shared.activateFileViewerSelecting(urls)`.
- **Copy Path / Copy Name.**
  - `clipboard.writeText` (`bootstrap.ts:529-532`).
  - The path is shell-quoted only if it contains whitespace: `'...'` with `'\''` escaping (`renderer/lib/explorerAppUtils.ts:10-15`).
  - **Swift:** `NSPasteboard.general.clearContents(); setString(_:forType:.string)`. For file copy/paste between apps also write `.fileURL`.
- **Get Info data.**
  - Fields: Kind (MDItem kind), Created (`birthtime`), Modified (`mtime`), Permissions (`mode & 0o777` only), Where (parent path), size or folder size, volume capacity and free space (`statfs`) for volume roots (`components/GetInfoPanel.tsx:410-487`, `explorerService.ts:163-190`).
  - ACL and flags are read and written only inside write and undo operations, not displayed.
  - **Not implemented:** Finder tags (`com.apple.metadata:_kMDItemUserTags`), comments, Where-froms, owner/group names, "Last opened", localized display names, dimensions, Locked checkbox in the UI.
  - **Swift:** `URLResourceValues` `.creationDate`, `.contentModificationDate`, `.contentAccessDate`, `.tagNames` (read/write), `.localizedName`, `.isUserImmutable`; `FileManager.attributesOfItem` (`.ownerAccountName`, `.groupOwnerAccountName`, `.posixPermissions`); `MDItemCopyAttribute` for `kMDItemWhereFroms`, `kMDItemPixelWidth`/`Height`, `kMDItemLastUsedDate`; volume capacity via `.volumeTotalCapacityKey` and `.volumeAvailableCapacityForImportantUsageKey` (matches Finder's "Available" better than `statfs` `bavail`).
- **Trash state and Empty Trash.**
  - `getTrashState` reads `~/.Trash` and `/Volumes/*/.Trashes/<uid>`; `.DS_Store` doesn't count. An unreadable Trash (no Full Disk Access) gives `empty: null` (`systemHandlers.ts:333-362`).
  - Empty Trash runs `osascript -e 'with timeout of 86400 seconds' -e 'tell application "Finder" to empty trash' -e 'end timeout'`, reporting osascript's stderr (`:368-385`). It needs `NSAppleEventsUsageDescription` and the apple-events entitlement.
  - Full Disk Access settings open via `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` (`:40-54`).
  - **Swift:** `NSAppleScript(source:)` (in-process, same TCC prompt), or `SBApplication`/AEDesc to Finder `empty trash`; `NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:...")!)`. There is no public non-Finder Empty Trash API that respects "Empty Trash securely" semantics; `FileManager.removeItem` on each Trash entry is possible but differs from Finder (locked items, other volumes).
- **Volume info.** Node `statfs` (above).
- **Launch context** (`main/launchContext.ts:13-97`).
  - Startup folder from `--folder <p>` or `--folder=<p>`, or the first positional argument that isn't the app path, with `~` expansion, resolved against cwd/`PWD`; it must be a directory.
  - Single-instance lock: a `second-instance` event brings the app to front (`main.ts:68, 325-331`).
  - Dock menu "New Window" (`main.ts:259-263`).
  - Closing the last window doesn't quit (`main.ts:310`).
  - **Swift:** `CommandLine.arguments` / `ProcessInfo.processInfo.arguments`; `application(_:open:)` for URLs; `applicationShouldTerminateAfterLastWindowClosed → false`; `applicationDockMenu(_:)`; single instance is automatic for a bundle app (LaunchServices).
- **Logging and rotation.**
  - `userData/logs/app.log` (`main/appLog.ts:25-27`).
  - Lines are `ISO8601 LEVEL args…`, with errors as stacks and objects via `util.inspect` (`:47-55, 133-148`).
  - Rotate when the file would exceed **5 MB**; keep **10** files: `app.log` → `app.1.log` … `app.9.log`, deleting the oldest (`:22-23, 51-54`; `main/logRotation.ts:13-33`).
  - Debug lines are written only when `FILETRAIL_DEBUG=1` or `FILETRAIL_DEBUG_TIMINGS=1` (`appLog.ts:29-31`).
  - Writes go through a serialized promise queue; `flush()` runs on fatal startup errors.
  - Renderer logs arrive via `app:writeLog` (`bootstrap.ts:386-389`).
  - **Swift:** `os.Logger(subsystem:"com.filetrail.desktop", category:)` for the unified log, plus a small file logger with the same rotation (`FileHandle` append on a serial queue) if user-visible log files are still wanted.
- **App state.** `userData/app-state.json`; the Replace journal is `userData/replace-journal.json` (`bootstrap.ts:225-227`). **Swift:** `FileManager.urls(for: .applicationSupportDirectory)` / bundle id; Codable JSON.
- **Appearance.** `nativeTheme.themeSource`, `nativeTheme.on("updated")` (`main.ts:173, 641-655`). **Swift:** `NSApp.appearance = NSAppearance(named: .darkAqua/.aqua) or nil`; observe `effectiveAppearance` with KVO.
- **Edit menu actions.** Electron `webContents.undo/redo/cut/copy/paste/selectAll` (`systemHandlers.ts:262-281`) map to standard responder-chain selectors in AppKit (`undo:`, `copy:`, etc.).

---

## Quick API mapping table

| Concern | Current native/system call | Swift/AppKit equivalent |
|---|---|---|
| Copy file (CoW, metadata, EXCL, sparse, stoppable) | `copyfile(ALL\|CLONE\|NOFOLLOW_SRC\|EXCL\|DATA_SPARSE)` + status callback | same `copyfile` from Darwin (C callback with `Unmanaged` context) |
| Copy folder metadata | `copyfile(METADATA\|NOFOLLOW_SRC)` | same |
| Exclusive rename | `renamex_np(RENAME_EXCL)` → `lstat`+`rename` fallback | same; consider `RENAME_SWAP` for Replace |
| Case sensitivity | `pathconf(_PC_CASE_SENSITIVE)` | `.volumeSupportsCaseSensitiveNamesKey` |
| AppleDouble volume | `getattrlist(VOL_CAP_INT_EXTENDED_ATTR)` | `getattrlist` (no URL key) |
| Locked / BSD flags | `lstat.st_flags`, `lchflags` | same / `.isUserImmutableKey` |
| ACL | `acl_get_link_np`/`acl_to_text`/`acl_from_text`/`acl_set_link_np` | same C API |
| Package | `NSURLIsPackageKey` (writes only); name list in listings | `.isPackageKey` everywhere |
| Trash | `NSFileManager trashItemAtURL:resultingItemURL:` | `FileManager.trashItem(at:resultingItemURL:)` |
| Icon | `NSWorkspace iconForFile:` → PNG (main queue) | `NSWorkspace.icon(forFile:)` / `icon(for: UTType)` (NSImage directly) |
| Thumbnail | `QLThumbnailGenerator` (`iconMode` for non-media) → JPEG/PNG | `QLThumbnailGenerator` async → `nsImage` |
| Kind string | `MDItem kMDItemKind` → `LSCopyKindStringForURL` → `NSURLLocalizedTypeDescriptionKey` | `MDItemCopyAttribute` → `.localizedTypeDescriptionKey` |
| Open With list / default | `URLsForApplicationsToOpenURL:`, `URLForApplicationToOpenURL:` | `NSWorkspace.urlsForApplications(toOpen:)`, `urlForApplication(toOpen:)` |
| Always Open With | `setDefaultApplicationAtURL:toOpenContentType:` | `NSWorkspace.setDefaultApplication(at:toOpen:)` |
| Open with app / reveal / open | `open -a`, `open -R`, `shell.openPath` | `NSWorkspace.open(_:withApplicationAt:configuration:)`, `activateFileViewerSelecting`, `open(_:)` |
| Date taken | ImageIO `CGImageSourceCopyPropertiesAtIndex` EXIF | same |
| Folder size | 4-thread `getattrlistbulk` walker, same-dev, skip mountpoints | keep C walker in a SwiftPM C target; `TaskGroup` + `AsyncStream` |
| Volumes | `getmntinfo(MNT_NOWAIT)` + IOKit IOMedia walk | keep `getmntinfo`; DA `DADiskCopyDescription`; `NSWorkspace.didMount/didUnmount` |
| Eject | DiskArbitration `DADiskUnmount(Force)` + `DADiskEject`, 120 s timeout | same DA from Swift, or `NSWorkspace.unmountAndEjectDevice(at:)` (no force or per-volume) |
| Disk images | `hdiutil isencrypted/imageinfo/attach -plist -noautoopen`; DiskImageMounter hand-off | `Process` + `PropertyListSerialization`; `NSWorkspace.open(withApplicationAt:)` |
| Folder watch | Node `fs.watch` (FSEvents), 250/1000 ms debounce, mtime check on focus | `FSEventStreamCreate` (FileEvents, WatchRoot) or `DispatchSource` vnode |
| Search | bundled fd 10.5.0 (about 2.9 MB arm64) via `spawn`, NUL output, 20k cap, SIGTERM cancel | `Process` + `Pipe` (keep fd), or a native walker / `NSMetadataQuery` |
| Drag out | `NSDraggingSession` with `NSURL` writers, custom image components, `NSDraggingSource` | same, via `NSTableView`/`NSCollectionView` pasteboard writers |
| Drag in | `NSPasteboardNameDrag` read of file URLs (+ HTML5 drop) | `NSDraggingDestination` + `readObjects(forClasses:[NSURL])`; add `NSFilePromiseReceiver` |
| Quick Look | `BrowserWindow.previewFile` (single) | `QLPreviewPanel` + data source/delegate (multi-item) |
| Empty Trash | `osascript` to Finder (Apple Events) | `NSAppleScript` / Scripting Bridge |
| Volume capacity | Node `statfs` | `.volumeAvailableCapacityForImportantUsageKey` / `statfs` |
| Clipboard text | Electron `clipboard.writeText` | `NSPasteboard.general.setString` |
| Logging | file logger, 5 MB × 10 rotation | `os.Logger` (+ optional rotating file) |

## Gaps the current code leaves (worth fixing in the port)

1. `nativeReadDragChangeCount` is not exported from `index.js` (section 0).
2. Listings classify packages by a hard-coded extension list (`packages/contracts/src/itemName.ts:31-46`) instead of `NSURLIsPackageKey`.
3. Hidden means dot-prefix only; `UF_HIDDEN` is ignored.
4. Finder alias files are not resolved; "Alias" labels refer to symlinks.
5. Localized names are not used.
6. Folder size has no hard-link dedup.
7. The fd archive SHA-256 is never verified.
8. Quick Look is single-item.
9. No promised-file drops.
10. No Finder tags or owner names in Get Info.
11. Custom folder icons are skipped except for special folders (`renderer/lib/fileIcons.tsx:176-226`).