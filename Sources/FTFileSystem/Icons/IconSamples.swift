// Port of getIconSamples and createIconSamples (apps/desktop/src/main/bootstrap/systemHandlers.ts)
import Foundation

/// Items we own, so macOS returns the ordinary icon for their kind: a folder holding something and an empty one
/// (folders such as "/" or ~/Library carry custom icons and must not stand in for all folders), and an empty file
/// without an extension, once plain and once executable. They live in one fixed folder that every launch reuses.
public final class IconSamples: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var made: [GenericIconKind: String]?
    private var madeTints: [String: String] = [:]

    public init(root: URL = IconSamples.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("filetrail-icon-samples", isDirectory: true)
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
        return paths[kind] ?? root.path
    }

    /// A folder of ours with only this tag, which Finder and Quick Look draw as a plain folder of its color.
    public func path(forTint color: FinderTagColor, isEmpty: Bool = false) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let name = "tag-\(color.rawValue)\(isEmpty ? "-empty" : "")"
        if let path = madeTints[name] { return path }
        let folder = root.appendingPathComponent(name)
        try makeFolder(folder, isEmpty: isEmpty)
        try FinderTags.write([FinderTag(name: String(describing: color), color: color)], to: folder.path)
        madeTints[name] = folder.path
        return folder.path
    }

    private func create() throws -> [GenericIconKind: String] {
        let folder = root.appendingPathComponent("folder")
        let emptyFolder = root.appendingPathComponent("empty-folder")
        let document = root.appendingPathComponent("document")
        let executable = root.appendingPathComponent("executable")
        let files = FileManager.default
        try makeFolder(folder, isEmpty: false)
        try makeFolder(emptyFolder, isEmpty: true)
        for (url, mode) in [(document, 0o644), (executable, 0o755)] {
            try Data().write(to: url)
            try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        return [
            .folder: folder.path, .emptyFolder: emptyFolder.path, .file: document.path, .executable: executable.path,
        ]
    }

    private func makeFolder(_ folder: URL, isEmpty: Bool) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !isEmpty { try Data().write(to: folder.appendingPathComponent("item")) }
    }
}
