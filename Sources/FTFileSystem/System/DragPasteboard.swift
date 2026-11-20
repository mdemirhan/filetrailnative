import AppKit
import FTFoundation
import Foundation

/// What a drag carries: its change count, which every new drag changes, and its files.
public struct DragPasteboardContents: Equatable, Sendable {
    public var changeCount: Int
    public var paths: [String]

    public init(changeCount: Int, paths: [String]) {
        self.changeCount = changeCount
        self.paths = paths
    }
}

/// A file a drag from another app carries, as it is on disk.
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
    /// each once, in order. Promised files, text and links have none. A path is read as its URL holds it
    /// (`DiskPath(urlSpelling:)`), which is how the app that started the drag spelled it, and `draggedIn` respells it
    /// as the disk has it.
    public static func read(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> DragPasteboardContents {
        let changeCount = pasteboard.changeCount
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<FTFoundation.NameKeys.Exact>()
        var paths: [String] = []
        for url in urls {
            let path = (url as NSURL).filePathURL.flatMap { DiskPath(urlSpelling: $0)?.string } ?? ""
            if !path.isEmpty, seen.insert(FTFoundation.NameKeys.Exact(path)).inserted { paths.append(path) }
        }
        return DragPasteboardContents(changeCount: changeCount, paths: paths)
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

    /// How a dragged file's path is respelled as its disk has it, for `draggedIn`: the folder it is in
    /// (`asOnDisk()`), and the item's own name as that folder holds it (`namedAsOnDisk()`).
    public struct Respelling: Sendable {
        public var folder: @Sendable (DiskPath) -> DiskPath
        public var name: @Sendable (DiskPath) -> DiskPath

        public init(
            folder: @escaping @Sendable (DiskPath) -> DiskPath, name: @escaping @Sendable (DiskPath) -> DiskPath
        ) {
            self.folder = folder
            self.name = name
        }

        /// The disk asked.
        public static let onDisk = Respelling(folder: { $0.asOnDisk() }, name: { $0.namedAsOnDisk() })
        /// Every path taken as it is given, the disk not asked.
        public static let asGiven = Respelling(folder: { $0 }, name: { $0 })
    }

    /// The dragged files' paths as the disk spells them, each once, in order: the other app spelled them its own
    /// way, and what a drop copies or moves is kept beside paths from listings. The disk is asked for each folder
    /// once, however many of its items are dragged, and for an item's own name only where the name has a letter
    /// outside ASCII, the only names with another spelling of their accents; a name in ASCII is taken as given.
    static func asOnDisk(_ paths: [String], _ respelling: Respelling) -> [String] {
        var folders: [DiskPath: DiskPath] = [:]
        var seen = Set<DiskPath>()
        var respelled: [String] = []
        respelled.reserveCapacity(paths.count)
        for path in paths {
            let given = DiskPath(path)
            let name = given.name
            var item = given
            if !name.isEmpty {
                let parent = given.parent
                let folder = folders[parent] ?? respelling.folder(parent)
                folders[parent] = folder
                item = folder.appending(name)
                if name.utf8.contains(where: { $0 >= 0x80 }) { item = respelling.name(item) }
            }
            if seen.insert(item).inserted { respelled.append(item.string) }
        }
        return respelled
    }

    /// Each dragged file as it is on disk: its path as the disk spells it (`asOnDisk`), and its kind (a link is the
    /// link; its kind says where it points), what can't be looked at left out. More files than one copy takes are
    /// refused as a whole.
    public static func draggedIn(
        _ contents: DragPasteboardContents, lstat: @Sendable (String) -> Stat? = DragPasteboard.lstat,
        stat: @Sendable (String) -> Stat? = DragPasteboard.stat, respelling: Respelling = .onDisk
    ) -> (changeCount: Int, items: [DraggedInItem]) {
        let given = contents.paths.filter { $0.utf16.first == 0x2F }
        guard given.count <= FileDragImages.maxPaths else { return (contents.changeCount, []) }
        let paths = asOnDisk(given, respelling)
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
