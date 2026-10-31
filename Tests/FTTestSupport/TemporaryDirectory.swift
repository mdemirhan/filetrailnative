// A fresh folder per test, removed afterwards even when a test left locked or read-only items in it.
import Darwin
import Foundation

public struct TemporaryDirectory: Sendable {
    public let url: URL

    public var path: String { url.path }

    public init(prefix: String = "ft-test") throws {
        // realpath'd, so paths the code under test reports (/private/var/...) match ours.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        try self.init(in: base, prefix: prefix)
    }

    private init(in base: URL, prefix: String) throws {
        url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// A fresh folder in this process's folder of `ShallowTestFolders`, for a test that shows it in a window. Its
    /// path is its real one (`/private/tmp/...`), the one a listing reports.
    public static func shallow(prefix: String) throws -> TemporaryDirectory {
        try TemporaryDirectory(in: try ShallowTestFolders.root(), prefix: prefix)
    }

    /// `name` inside the folder.
    public func appending(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Clears the Locked flag and gives the owner write access everywhere, then removes the folder.
    public func remove() {
        Self.removeAll(at: url)
    }

    static func removeAll(at url: URL) {
        let path = url.path
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

/// The folders of window tests, in a folder of this process's own under /private/tmp (`filetrail-tests/pid<pid>`),
/// removed when the process exits.
///
/// Not in the system's temporary folder: a window's sidebar lists every folder above the one on screen, and the
/// temporary folder of a Mac that runs the suites all day holds tens of thousands of items, which made each refresh
/// of the sidebar take seconds, and some window tests minutes.
public enum ShallowTestFolders {
    private static let made: Result<URL, any Error> = Result {
        let parent = URL(fileURLWithPath: "/private/tmp/filetrail-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        removeLeftovers(in: parent)
        let root = parent.appendingPathComponent("pid\(getpid())", isDirectory: true)
        // The folder of a process that is gone, whose number this process now has, is a leftover too.
        TemporaryDirectory.removeAll(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        atexit { ShallowTestFolders.removeOwn() }
        return root
    }

    /// This process's folder, made on the first call.
    public static func root() throws -> URL {
        try made.get()
    }

    private static func removeOwn() {
        if case .success(let root) = made { TemporaryDirectory.removeAll(at: root) }
    }

    /// The folders of processes that are gone (killed, or crashed before they removed theirs).
    private static func removeLeftovers(in parent: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] {
            guard name.hasPrefix("pid"), let pid = pid_t(name.dropFirst(3)), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                TemporaryDirectory.removeAll(at: parent.appendingPathComponent(name, isDirectory: true))
            }
        }
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
