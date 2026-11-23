import Foundation

/// A listed item, as far as the info views need it (`DirectoryEntry`).
public struct InfoEntry: Equatable, Sendable {
    public var path: String
    public var name: String
    public var fileExtension: String
    public var kind: EntryKind
    public var isHidden: Bool
    public var isSymlink: Bool

    public init(
        path: String, name: String, fileExtension: String = "", kind: EntryKind, isHidden: Bool = false,
        isSymlink: Bool = false
    ) {
        self.path = path
        self.name = name
        self.fileExtension = fileExtension
        self.kind = kind
        self.isHidden = isHidden
        self.isSymlink = isSymlink
    }
}

/// What the list already knows of an item.
public struct InfoMetadata: Equatable, Sendable {
    public var kindLabel: String
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?

    public init(
        kindLabel: String, createdAt: Date? = nil, modifiedAt: Date? = nil, sizeBytes: Int64? = nil,
        sizeStatus: SizeStatus = .deferred, permissionMode: Int? = nil
    ) {
        self.kindLabel = kindLabel
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.sizeStatus = sizeStatus
        self.permissionMode = permissionMode
    }
}

/// An item's properties (`ItemProperties`), or the preview made from the list.
/// Where a symbolic link or an alias leads, as Get Info says.
public enum InfoOriginal: Equatable, Sendable {
    case found(String)
    /// Deleted, or on a disk or a server not connected.
    case missing
}

public struct InfoItem: Equatable, Sendable {
    public var path: String
    public var name: String
    public var fileExtension: String
    public var kind: EntryKind
    public var kindLabel: String
    public var isHidden: Bool
    public var isSymlink: Bool
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?
    /// For a symbolic link or an alias, where it leads; nil for anything else.
    public var original: InfoOriginal?

    public init(
        path: String, name: String, fileExtension: String = "", kind: EntryKind, kindLabel: String,
        isHidden: Bool = false, isSymlink: Bool = false, createdAt: Date? = nil, modifiedAt: Date? = nil,
        sizeBytes: Int64? = nil, sizeStatus: SizeStatus = .deferred, permissionMode: Int? = nil,
        original: InfoOriginal? = nil
    ) {
        self.original = original
        self.path = path
        self.name = name
        self.fileExtension = fileExtension
        self.kind = kind
        self.kindLabel = kindLabel
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.sizeStatus = sizeStatus
        self.permissionMode = permissionMode
    }
}

public enum InfoPreview {
    public struct Resolved: Equatable, Sendable {
        public var item: InfoItem
        public var pending: Bool
    }

    /// What the info views show for `path`: the item's full properties once they arrive, and until then a preview built
    /// from what the file list already knows, so switching items updates in place instead of blanking.
    public static func resolve(
        path: String?, currentPath: String, entries: [InfoEntry], metadataByPath: [String: InfoMetadata],
        properties: InfoItem?, homePath: String = "", startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> Resolved? {
        guard let path, !path.isEmpty else { return nil }
        if var properties, properties.path == path {
            properties.name = displayName(properties.path, name: properties.name, homePath: homePath)
            return Resolved(item: properties, pending: false)
        }
        let entry =
            entries.first { $0.path == path }
            ?? (path == currentPath ? folderEntry(path, homePath: homePath, startupDiskName: startupDiskName) : nil)
        guard let entry else { return nil }
        let metadata = metadataByPath[path]
        return Resolved(
            item: InfoItem(
                path: entry.path, name: displayName(entry.path, name: entry.name, homePath: homePath),
                fileExtension: entry.fileExtension, kind: entry.kind,
                kindLabel: metadata?.kindLabel
                    ?? fallbackKindLabel(kind: entry.kind, fileExtension: entry.fileExtension),
                isHidden: entry.isHidden, isSymlink: entry.isSymlink, createdAt: metadata?.createdAt,
                modifiedAt: metadata?.modifiedAt, sizeBytes: metadata?.sizeBytes,
                sizeStatus: metadata?.sizeStatus ?? .deferred, permissionMode: metadata?.permissionMode),
            pending: true)
    }

    /// A folder the list shows no row of, named as its tab is: `/` has the startup disk's name, a Trash folder "Trash".
    public static func folderEntry(
        _ path: String, homePath: String = "", startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> InfoEntry {
        InfoEntry(
            path: path, name: TabText.folderDisplayName(path, homePath: homePath, startupDiskName: startupDiskName),
            kind: .directory)
    }

    /// An item's name in the info views: "Trash" for a Trash folder, as its tab and the path bar call it, else `name`.
    public static func displayName(_ path: String, name: String, homePath: String) -> String {
        Paths.isTrashFolder(path, homePath: homePath) ? "Trash" : name
    }

    /// The kind shown before the system's own description is known.
    public static func fallbackKindLabel(kind: EntryKind, fileExtension: String) -> String {
        switch kind {
        case .directory: "Folder"
        case .bundle: fileExtension == "app" ? "Application" : "Package"
        case .symlinkDirectory, .symlinkFile: "Symbolic Link"
        default: fileExtension.isEmpty ? "File" : "\(fileExtension.uppercased()) File"
        }
    }
}
