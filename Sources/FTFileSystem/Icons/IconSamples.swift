// Port of getIconSamples and createIconSamples (apps/desktop/src/main/bootstrap/systemHandlers.ts)
import Foundation

/// Items we own, so NSWorkspace returns the ordinary icon for their kind: an empty folder (folders such as
/// "/" or ~/Library carry custom icons and must not stand in for all folders), and an empty file without an
/// extension, once plain and once executable. They live in one fixed folder that every launch reuses.
public final class IconSamples: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var made: [GenericIconKind: String]?
    private var madeTints: [FinderTagColor: String] = [:]

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

    /// A folder of ours that macOS draws as a plain folder of this tag color, as Finder draws a tagged one. macOS gives
    /// no such icon on request, and for a folder with only a tag it answers with the blue one: it tints only a folder
    /// customized as Finder's Customize Folder does, here with a blank emoji. If that stops working the icon is blue.
    public func path(forTint color: FinderTagColor) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let path = madeTints[color] { return path }
        let folder = root.appendingPathComponent("folder-\(color.rawValue)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FinderTags.write([FinderTag(name: String(describing: color), color: color)], to: folder.path)
        try FinderTags.markCustomized(folder.path, configuration: #"{"emoji":" "}"#)
        madeTints[color] = folder.path
        return folder.path
    }

    private func create() throws -> [GenericIconKind: String] {
        let folder = root.appendingPathComponent("folder")
        let document = root.appendingPathComponent("document")
        let executable = root.appendingPathComponent("executable")
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for (url, mode) in [(document, 0o644), (executable, 0o755)] {
            try Data().write(to: url)
            try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        return [.folder: folder.path, .file: document.path, .executable: executable.path]
    }
}
