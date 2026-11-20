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
