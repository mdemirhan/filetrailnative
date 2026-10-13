// A fresh folder per test, removed afterwards even when a test left locked or read-only items in it.
import Darwin
import Foundation

public struct TemporaryDirectory: Sendable {
    public let url: URL

    public var path: String { url.path }

    public init(prefix: String = "ft-test") throws {
        // realpath'd, so paths the code under test reports (/private/var/...) match ours.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// `name` inside the folder.
    public func appending(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Clears the Locked flag and gives the owner write access everywhere, then removes the folder.
    public func remove() {
        let paths = (FileManager.default.subpaths(atPath: path) ?? []).map { path + "/" + $0 }
        for item in [path] + paths {
            lchflags(item, 0)
            var info = stat()
            if lstat(item, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR {
                chmod(item, (info.st_mode & 0o7777) | S_IRWXU)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs `body` with a fresh temporary folder and removes it afterwards.
public func withTemporaryDirectory<T>(
    prefix: String = "ft-test", _ body: (TemporaryDirectory) throws -> T
) throws -> T {
    let directory = try TemporaryDirectory(prefix: prefix)
    defer { directory.remove() }
    return try body(directory)
}

/// Runs `body` with a fresh temporary folder and removes it afterwards.
public func withTemporaryDirectory<T>(
    prefix: String = "ft-test", isolation: isolated (any Actor)? = #isolation,
    _ body: (TemporaryDirectory) async throws -> T
) async throws -> T {
    let directory = try TemporaryDirectory(prefix: prefix)
    defer { directory.remove() }
    return try await body(directory)
}
