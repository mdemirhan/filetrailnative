// Port of getIconSamples and createIconSamples (apps/desktop/src/main/bootstrap/systemHandlers.ts)
import Foundation

/// Items we own, so NSWorkspace returns the ordinary icon for their kind: an empty folder (folders such as
/// "/" or ~/Library carry custom icons and must not stand in for all folders), and an empty file without an
/// extension, once plain and once executable. They live in one fixed folder that every launch reuses.
public final class IconSamples: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var made: [GenericIconKind: String]?

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
