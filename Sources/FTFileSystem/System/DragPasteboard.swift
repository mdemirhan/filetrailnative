// Port of nativeReadDragPasteboard and nativeReadDragChangeCount (packages/native-fs/src/native_filedrag.m) and of
// readDraggedIn and readDragChangeCount (apps/desktop/src/main/bootstrap/fileDrag.ts)
import AppKit
import FTFoundation
import Foundation

/// What a drag carries (`nativeReadDragPasteboard`): its change count, which every new drag changes, and its files.
public struct DragPasteboardContents: Equatable, Sendable {
    public var changeCount: Int
    public var paths: [String]

    public init(changeCount: Int, paths: [String]) {
        self.changeCount = changeCount
        self.paths = paths
    }
}

/// A file a drag from another app carries, as it is on disk (`system:readDraggedIn`'s items).
public struct DraggedInItem: Equatable, Sendable {
    public var path: String
    public var kind: EntryKind

    public init(path: String, kind: EntryKind) {
        self.path = path
        self.kind = kind
    }
}

/// What a drag from another app carries, read from its pasteboard.
public enum DragPasteboard {
    /// The files `pasteboard` holds: file URLs only, Finder's file references (`file:///.file/id=…`) as their paths,
    /// each once, in order. Promised files, text and links have none.
    public static func read(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> DragPasteboardContents {
        let changeCount = pasteboard.changeCount
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<FTFoundation.NameKeys.Exact>()
        var paths: [String] = []
        for url in urls {
            let path = (url as NSURL).filePathURL?.path ?? ""
            if !path.isEmpty, seen.insert(FTFoundation.NameKeys.Exact(path)).inserted { paths.append(path) }
        }
        return DragPasteboardContents(changeCount: changeCount, paths: paths)
    }

    /// `nativeReadDragChangeCount`: which drag is going on, without reading what it carries.
    public static func changeCount(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Int {
        pasteboard.changeCount
    }

    /// How a path is on disk, for `draggedIn`: whether it is a link, a folder, and for a link what it points to.
    public struct Stat: Sendable {
        public var isDirectory: Bool
        public var isSymbolicLink: Bool

        public init(isDirectory: Bool, isSymbolicLink: Bool) {
            self.isDirectory = isDirectory
            self.isSymbolicLink = isSymbolicLink
        }
    }

    /// `lstat`, nil when the path can't be looked at.
    public static let lstat: @Sendable (String) -> Stat? = { path in
        var info = Darwin.stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return Stat(isDirectory: type == S_IFDIR, isSymbolicLink: type == S_IFLNK)
    }

    /// `stat`, through links.
    public static let stat: @Sendable (String) -> Stat? = { path in
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else { return nil }
        return Stat(isDirectory: info.st_mode & S_IFMT == S_IFDIR, isSymbolicLink: false)
    }

    /// `readDraggedIn`: each dragged file's kind as it is on disk (a link is the link; its kind says where it
    /// points), what can't be looked at left out. More files than one copy takes are refused as a whole.
    public static func draggedIn(
        _ contents: DragPasteboardContents, lstat: @Sendable (String) -> Stat? = DragPasteboard.lstat,
        stat: @Sendable (String) -> Stat? = DragPasteboard.stat
    ) -> (changeCount: Int, items: [DraggedInItem]) {
        let paths = contents.paths.filter { $0.utf16.first == 0x2F }
        guard paths.count <= FileDragImages.maxPaths else { return (contents.changeCount, []) }
        let items = paths.compactMap { path -> DraggedInItem? in
            guard let info = lstat(path) else { return nil }
            if info.isSymbolicLink {
                let pointsToFolder = stat(path)?.isDirectory ?? false
                return DraggedInItem(path: path, kind: pointsToFolder ? .symlinkDirectory : .symlinkFile)
            }
            return DraggedInItem(path: path, kind: info.isDirectory ? .directory : .file)
        }
        return (contents.changeCount, items)
    }
}
