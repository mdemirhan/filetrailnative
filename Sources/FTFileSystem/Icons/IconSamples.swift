import FTFoundation
import Foundation

/// Items we own, so macOS returns the ordinary icon for their kind: a folder holding something and an empty one
/// (folders such as "/" or ~/Library carry custom icons and must not stand in for all folders), and an empty file
/// without an extension, once plain and once executable. They live in one fixed folder that every launch reuses.
public final class IconSamples: @unchecked Sendable {
    public let root: URL
    /// The folder's path as its URL spells it; the samples' paths are joined to it, as a URL would respell the whole
    /// path each time a part is added.
    private let folder: DiskPath
    private let lock = NSLock()
    private var made: [GenericIconKind: String]?
    private var madeTints: [String: String] = [:]
    private var madeAliasLinks: [String: String] = [:]

    public init(root: URL = IconSamples.defaultRoot) {
        self.root = root
        folder = DiskPath(urlSpelling: root) ?? DiskPath(NSTemporaryDirectory()).appending("filetrail-icon-samples")
    }

    public static var defaultRoot: URL {
        DiskPath(NSTemporaryDirectory()).appending("filetrail-icon-samples").url(isDirectory: true)
    }

    /// The sample item of a kind, made on first use. A failure is not remembered: the next call tries again.
    public func path(for kind: GenericIconKind) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let made, let path = made[kind] {
            return path
        }
        let paths = try create()
        made = paths
        return paths[kind] ?? folder.string
    }

    /// A folder of ours with only this tag, which Finder and Quick Look draw as a plain folder of its color.
    public func path(forTint color: FinderTagColor, isEmpty: Bool = false) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let name = "tag-\(color.rawValue)\(isEmpty ? "-empty" : "")"
        if let path = madeTints[name] { return path }
        let sample = folder.appending(name).string
        try makeFolder(sample, isEmpty: isEmpty)
        try FinderTags.write([FinderTag(name: String(describing: color), color: color)], to: sample)
        madeTints[name] = sample
        return sample
    }

    /// A symbolic link of ours that macOS draws as Finder draws an alias of `original`: the icon of its kind with the
    /// link's arrow, which is the arrow Finder puts on an alias. The link leads to a plain item of ours of the same kind
    /// (a folder, or an empty file with the same extension), so the alias shows no preview of the original and no color
    /// of its tags, as in Finder; an app, a package, a disk or a folder macOS draws with its own picture is led to
    /// itself, whose picture the alias shows.
    public func aliasLink(to original: String, isFolder: Bool) throws -> String {
        let name: String
        let target: String
        if isFolder && !IconCacheKey.isDrawnBySystem(path: original) {
            name = "alias-folder"
            target = try path(for: .folder)
        } else if isFolder || ItemNames.isMacOSPackageName(NodePath.basename(original))
            || IconCacheKey.isDrawnBySystem(path: original)
        {
            name = "alias-item-\(Self.stableHash(original))"
            target = original
        } else {
            let fileExtension = NodePath.extname(NodePath.basename(original)).dropFirst().lowercased()
            if fileExtension.isEmpty {
                let mode = (try? FileManager.default.attributesOfItem(atPath: original))?[.posixPermissions] as? Int
                let executable = (mode ?? 0) & 0o111 != 0
                name = executable ? "alias-executable" : "alias-file"
                target = try path(for: executable ? .executable : .file)
            } else {
                name = "alias-ext-\(fileExtension)"
                target = try sampleFile(withExtension: String(fileExtension))
            }
        }
        lock.lock()
        defer { lock.unlock() }
        if let made = madeAliasLinks[name] { return made }
        let link = folder.appending(name).string
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        madeAliasLinks[name] = link
        return link
    }

    /// An empty file of ours named with `fileExtension`, drawn with the icon of the files of that extension.
    private func sampleFile(withExtension fileExtension: String) throws -> String {
        let sample = folder.appending("sample.\(fileExtension)").string
        if !FileManager.default.fileExists(atPath: sample) {
            try FileManager.default.createDirectory(atPath: folder.string, withIntermediateDirectories: true)
            try Data().write(to: DiskPath(sample).url(isDirectory: false))
        }
        return sample
    }

    /// A name for a path that stays the same from launch to launch, unlike `hashValue`: FNV-1a over its bytes.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func create() throws -> [GenericIconKind: String] {
        let full = folder.appending("folder").string
        let emptyFolder = folder.appending("empty-folder").string
        let document = folder.appending("document").string
        let executable = folder.appending("executable").string
        let files = FileManager.default
        try makeFolder(full, isEmpty: false)
        try makeFolder(emptyFolder, isEmpty: true)
        for (path, mode) in [(document, 0o644), (executable, 0o755)] {
            try Data().write(to: DiskPath(path).url(isDirectory: false))
            try files.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        return [.folder: full, .emptyFolder: emptyFolder, .file: document, .executable: executable]
    }

    private func makeFolder(_ path: String, isEmpty: Bool) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if !isEmpty { try Data().write(to: DiskPath(path).appending("item").url(isDirectory: false)) }
    }
}
