import FTFoundation
import Foundation

/// The kinds of listing entry an icon is asked for.
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
    /// A folder with its own icon, which it can't share with the others.
    public var hasCustomIcon: Bool
    /// A folder's tag color, which it is drawn in.
    public var tagColor: FinderTagColor?
    /// A folder known to hold nothing. One not known to is drawn as holding something.
    public var isEmptyFolder: Bool

    public init(
        path: String, name: String = "", extension: String = "", kind: IconEntryKind = .file,
        isExecutable: Bool? = nil, hasCustomIcon: Bool = false, tagColor: FinderTagColor? = nil,
        isEmptyFolder: Bool = false
    ) {
        self.path = path
        self.name = name
        self.extension = `extension`
        self.kind = kind
        self.isExecutable = isExecutable
        self.hasCustomIcon = hasCustomIcon
        self.tagColor = tagColor
        self.isEmptyFolder = isEmptyFolder
    }
}

/// The plain icons shared by a whole kind of item, drawn from a sample item of that kind.
public enum GenericIconKind: String, Sendable, CaseIterable {
    case folder, emptyFolder, file, executable

    /// The cache key of the kind.
    public var cacheKey: String {
        switch self {
        case .folder: "kind:directory"
        case .emptyFolder: "kind:directory:empty"
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
    /// Drawn as the plain folder of this tag color, which all such folders share.
    public var tint: FinderTagColor?
    /// A folder that holds nothing: which sample of a tag color it is drawn from.
    public var isEmptyFolder: Bool
    /// A folder asked for by its path, with the picture of its own that Finder draws.
    public var isFolder: Bool

    public init(
        cacheKey: String, path: String, generic: GenericIconKind? = nil, tint: FinderTagColor? = nil,
        isEmptyFolder: Bool = false, isFolder: Bool = false
    ) {
        self.cacheKey = cacheKey
        self.path = path
        self.generic = generic
        self.tint = tint
        self.isEmptyFolder = isEmptyFolder
        self.isFolder = isFolder
    }

    /// The icon of a listing entry. Files share one icon per extension, extension-less files one of two,
    /// and ordinary folders one for holding something and one for holding nothing; apps, bundles, symlinks,
    /// volumes and special folders have their own.
    ///
    /// A special folder or a disk is drawn by NSWorkspace, not Quick Look: its picture doesn't change with what it
    /// holds, and Quick Look looks inside, which for Desktop, Documents and Downloads makes macOS ask for permission
    /// though the folder was only shown.
    public init(entry: IconEntry) {
        let key = IconCacheKey.key(for: entry)
        let tint = entry.tagColor.flatMap {
            key == IconCacheKey.tintedFolderKey($0, isEmpty: entry.isEmptyFolder) ? $0 : nil
        }
        let generic = IconCacheKey.genericKind(forKey: key)
        self.init(
            cacheKey: key, path: entry.path, generic: generic, tint: tint,
            isEmptyFolder: tint != nil && entry.isEmptyFolder,
            isFolder: entry.kind == .directory && generic == nil && tint == nil
                && !IconCacheKey.isDrawnBySystem(entry))
    }

    /// An application's own icon, for the app pop-ups and lists in Settings.
    public static func app(path: String) -> IconRequest {
        IconRequest(cacheKey: "app:\(path)", path: path)
    }

    /// The plain folder of a tag color, which all folders of that color share. The path is not used.
    public static func tintedFolder(_ color: FinderTagColor, isEmpty: Bool) -> IconRequest {
        IconRequest(
            cacheKey: IconCacheKey.tintedFolderKey(color, isEmpty: isEmpty), path: "/", tint: color,
            isEmptyFolder: isEmpty)
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

    /// A special folder or a disk's top folder, which is drawn as the disk: a drive, a disk image, a network share.
    static func isDrawnBySystem(_ entry: IconEntry) -> Bool {
        VolumePaths.isVolumeRootPath(entry.path) || specialFolderNames.contains(folderName(entry))
    }

    private static func folderName(_ entry: IconEntry) -> String {
        entry.name.isEmpty
            ? (entry.path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "")
            : entry.name
    }

    public static func key(for entry: IconEntry) -> String {
        switch entry.kind {
        case .bundle, .other, .symlinkFile, .symlinkDirectory:
            return "path:\(entry.path)"
        case .directory:
            let isEmpty = entry.isEmptyFolder
            if entry.hasCustomIcon || isDrawnBySystem(entry) {
                return isEmpty ? "path:\(entry.path):empty" : "path:\(entry.path)"
            }
            return entry.tagColor.map { tintedFolderKey($0, isEmpty: isEmpty) }
                ?? (isEmpty ? GenericIconKind.emptyFolder : .folder).cacheKey
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

    /// The key the folders of a tag color share, those holding nothing apart from the others.
    static func tintedFolderKey(_ color: FinderTagColor, isEmpty: Bool = false) -> String {
        "\((isEmpty ? GenericIconKind.emptyFolder : .folder).cacheKey):\(color.rawValue)"
    }

    /// The extension of a key the files of one extension share; nil for other keys.
    public static func fileExtension(ofKey key: String) -> String? {
        key.hasPrefix("ext:") ? String(key.dropFirst(4)) : nil
    }

    /// The sample kind to draw a shared key from; nil for keys that go with one path.
    public static func genericKind(forKey key: String) -> GenericIconKind? {
        GenericIconKind.allCases.first { $0.cacheKey == key }
    }
}
