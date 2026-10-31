// Port of apps/desktop/src/renderer/lib/infoPreview.ts
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

/// What the list already knows of an item (`DirectoryEntryMetadata`).
public struct InfoMetadata: Equatable, Sendable {
    public var kindLabel: String
    public var createdAt: String?
    public var modifiedAt: String?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?

    public init(
        kindLabel: String, createdAt: String? = nil, modifiedAt: String? = nil, sizeBytes: Int64? = nil,
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
public struct InfoItem: Equatable, Sendable {
    public var path: String
    public var name: String
    public var fileExtension: String
    public var kind: EntryKind
    public var kindLabel: String
    public var isHidden: Bool
    public var isSymlink: Bool
    public var createdAt: String?
    public var modifiedAt: String?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?

    public init(
        path: String, name: String, fileExtension: String = "", kind: EntryKind, kindLabel: String,
        isHidden: Bool = false, isSymlink: Bool = false, createdAt: String? = nil, modifiedAt: String? = nil,
        sizeBytes: Int64? = nil, sizeStatus: SizeStatus = .deferred, permissionMode: Int? = nil
    ) {
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
        properties: InfoItem?
    ) -> Resolved? {
        guard let path, !path.isEmpty else { return nil }
        if let properties, properties.path == path { return Resolved(item: properties, pending: false) }
        let entry = entries.first { $0.path == path } ?? (path == currentPath ? folderEntry(path) : nil)
        guard let entry else { return nil }
        let metadata = metadataByPath[path]
        return Resolved(
            item: InfoItem(
                path: entry.path, name: entry.name, fileExtension: entry.fileExtension, kind: entry.kind,
                kindLabel: metadata?.kindLabel
                    ?? fallbackKindLabel(kind: entry.kind, fileExtension: entry.fileExtension),
                isHidden: entry.isHidden, isSymlink: entry.isSymlink, createdAt: metadata?.createdAt,
                modifiedAt: metadata?.modifiedAt, sizeBytes: metadata?.sizeBytes,
                sizeStatus: metadata?.sizeStatus ?? .deferred, permissionMode: metadata?.permissionMode),
            pending: true)
    }

    /// `folderEntryForPath`.
    public static func folderEntry(_ path: String) -> InfoEntry {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "Macintosh HD"
        return InfoEntry(path: path, name: name, kind: .directory)
    }

    /// The kind shown before the system's own description is known.
    public static func fallbackKindLabel(kind: EntryKind, fileExtension: String) -> String {
        switch kind {
        case .directory: "Folder"
        case .symlinkDirectory: "Alias Folder"
        case .bundle: fileExtension == "app" ? "Application" : "Package"
        case .symlinkFile: "Alias"
        default: fileExtension.isEmpty ? "File" : "\(fileExtension.uppercased()) File"
        }
    }
}
