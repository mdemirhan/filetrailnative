// Port of nativeIconCacheKey, SPECIAL_FOLDER_NAMES and GENERIC_ICON_KINDS (apps/desktop/src/renderer/lib/fileIcons.tsx), isVolumeRootPath (renderer/lib/volumes.ts)
import Foundation

/// The kinds of listing entry an icon is asked for (`kind` of the original's directory entries).
public enum IconEntryKind: Sendable, Equatable {
    case file, directory, symlinkFile, symlinkDirectory, bundle, other
}

/// What the icon cache key depends on in a listing entry.
public struct IconEntry: Sendable, Equatable {
    public var path: String
    public var name: String
    public var `extension`: String
    public var kind: IconEntryKind
    /// Known for listing entries; nil for a search result, whose extension-less files are then asked for by path.
    public var isExecutable: Bool?

    public init(
        path: String, name: String = "", extension: String = "", kind: IconEntryKind = .file,
        isExecutable: Bool? = nil
    ) {
        self.path = path
        self.name = name
        self.extension = `extension`
        self.kind = kind
        self.isExecutable = isExecutable
    }
}

/// The plain icons shared by a whole kind of item, drawn from a sample item of that kind
/// (`generic` in the original's `system:getFileIcon`).
public enum GenericIconKind: String, Sendable, CaseIterable {
    case folder, file, executable

    /// The cache key of the kind.
    public var cacheKey: String {
        switch self {
        case .folder: "kind:directory"
        case .file: "kind:file"
        case .executable: "kind:executable"
        }
    }
}

/// An icon to be fetched: where it is cached, and the item (or kind) it is drawn from.
public struct IconRequest: Sendable, Equatable {
    public var cacheKey: String
    public var path: String
    public var generic: GenericIconKind?

    public init(cacheKey: String, path: String, generic: GenericIconKind? = nil) {
        self.cacheKey = cacheKey
        self.path = path
        self.generic = generic
    }

    /// The icon of a listing entry. Files share one icon per extension, extension-less files one of two,
    /// and ordinary folders one; apps, bundles, symlinks, volumes and special folders have their own.
    public init(entry: IconEntry) {
        let key = IconCacheKey.key(for: entry)
        self.init(cacheKey: key, path: entry.path, generic: IconCacheKey.genericKind(forKey: key))
    }

    /// An application's own icon, for the app pop-ups and lists in Settings.
    public static func app(path: String) -> IconRequest {
        IconRequest(cacheKey: "app:\(path)", path: path)
    }

    /// The plain icon of a kind. The path is not used for an icon asked for by kind.
    public static func generic(_ kind: GenericIconKind) -> IconRequest {
        IconRequest(cacheKey: kind.cacheKey, path: "/", generic: kind)
    }
}

public enum IconCacheKey {
    /// Folders macOS draws with their own icon.
    static let specialFolderNames: Set<String> = [
        "Applications", "Desktop", "Developer", "Documents", "Downloads", "Library", "Movies", "Music",
        "Pictures", "Public", "System", "Users",
    ]

    public static func key(for entry: IconEntry) -> String {
        switch entry.kind {
        case .bundle, .other, .symlinkFile, .symlinkDirectory:
            return "path:\(entry.path)"
        case .directory:
            let name =
                entry.name.isEmpty
                ? (entry.path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "")
                : entry.name
            // A disk's top folder is drawn as the disk: a drive, a disk image, a network share.
            return isVolumeRootPath(entry.path) || specialFolderNames.contains(name)
                ? "path:\(entry.path)" : GenericIconKind.folder.cacheKey
        case .file:
            break
        }
        let fileExtension = entry.extension.lowercased()
        if !fileExtension.isEmpty {
            return "ext:\(fileExtension)"
        }
        // A listing says whether such a file is executable; anything else (a search result) does not,
        // and is asked for by path.
        if let executable = entry.isExecutable {
            return executable ? GenericIconKind.executable.cacheKey : GenericIconKind.file.cacheKey
        }
        return "path:\(entry.path)"
    }

    /// The sample kind to draw a shared key from; nil for keys that go with one path.
    public static func genericKind(forKey key: String) -> GenericIconKind? {
        GenericIconKind.allCases.first { $0.cacheKey == key }
    }

    /// The root of a volume: the startup disk ("/") or a disk mounted at /Volumes/<name>.
    public static func isVolumeRootPath(_ path: String) -> Bool {
        volumeRootPath(of: path) == path
    }

    /// Which disk a path is on, told from the path alone: /Volumes/<name>, or the startup disk.
    public static func volumeRootPath(of path: String) -> String {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return "/" }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        return name.isEmpty ? "/" : prefix + name
    }
}
