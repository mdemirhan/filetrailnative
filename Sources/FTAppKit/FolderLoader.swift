import Foundation
import UniformTypeIdentifiers

struct FileItem: Sendable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let modified: Date?
    let size: Int64?
    let kind: String

    /// Folders open in place; packages (apps, bundles) open like files.
    var opensAsFolder: Bool { isDirectory && !isPackage }
}

struct FolderListing: Sendable {
    let folder: URL
    let items: [FileItem]
}

/// Reads a folder off the main thread. Everything the views show is read here,
/// so drawing a row never touches the disk (except for its icon).
///
/// `localizedNameKey` and `localizedTypeDescriptionKey` are avoided: each asks
/// LaunchServices per file (about 145 ms for 3,000 files). The content type
/// gives the kind (looked up once per type) and whether a folder is a package.
enum FolderLoader {
    private static let keys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .contentTypeKey, .hasHiddenExtensionKey,
        .contentModificationDateKey, .fileSizeKey,
    ]

    static func load(_ folder: URL) throws -> FolderListing {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        let keySet = Set(keys)
        var kinds: [UTType: String] = [:]
        let items = urls.map { url in
            let values = try? url.resourceValues(forKeys: keySet)
            let isDirectory = values?.isDirectory ?? false
            let type = values?.contentType
            let isPackage = isDirectory && type?.conforms(to: .package) == true
            var name = values?.name ?? url.lastPathComponent
            if values?.hasHiddenExtension == true || (isPackage && type?.conforms(to: .application) == true) {
                name = (name as NSString).deletingPathExtension
            }
            let kindType = type ?? .data
            let kind: String
            if let known = kinds[kindType] {
                kind = known
            } else {
                // UTType says "folder" and nothing for unknown data; Finder says "Folder" and "Document".
                let description = kindType == .data ? "Document" : kindType.localizedDescription ?? "Document"
                kind = description.prefix(1).uppercased() + description.dropFirst()
                kinds[kindType] = kind
            }
            return FileItem(
                url: url,
                name: name,
                isDirectory: isDirectory,
                isPackage: isPackage,
                modified: values?.contentModificationDate,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                kind: kind)
        }
        return FolderListing(folder: folder, items: items)
    }

    /// Free space as Finder counts it (purgeable space included). Takes ~17 ms,
    /// so it is read after the folder is on screen.
    static func availableCapacity(at folder: URL) -> Int64? {
        try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// The folder an item opens into: itself, or a symbolic link's target folder.
    static func folderTarget(of item: FileItem) -> URL? {
        if item.opensAsFolder { return item.url }
        guard !item.isDirectory else { return nil }
        let resolved = item.url.resolvingSymlinksInPath()
        guard resolved != item.url,
            let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
            values.isDirectory == true, values.isPackage != true
        else { return nil }
        return resolved
    }
}

enum Sorting {
    static func sorted(_ items: [FileItem], by descriptor: NSSortDescriptor) -> [FileItem] {
        let byName: (FileItem, FileItem) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let ordered: [FileItem]
        switch descriptor.key {
        case "modified":
            ordered = items.sorted { a, b in
                a.modified == b.modified
                    ? byName(a, b) : (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            }
        case "size":
            ordered = items.sorted { a, b in
                a.size == b.size ? byName(a, b) : (a.size ?? -1) < (b.size ?? -1)
            }
        case "kind":
            ordered = items.sorted { a, b in
                let order = a.kind.localizedStandardCompare(b.kind)
                return order == .orderedSame ? byName(a, b) : order == .orderedAscending
            }
        default:
            ordered = items.sorted(by: byName)
        }
        return descriptor.ascending ? ordered : ordered.reversed()
    }
}

extension URL {
    /// A path for comparing locations (no trailing slash, no `.` or `..`).
    var comparablePath: String { standardizedFileURL.path }
}
