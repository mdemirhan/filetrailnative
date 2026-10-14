@testable import FTFileSystem
import Foundation

struct FakeError: Error {}

/// A file system the tests script: what a read, `stat`, `lstat` and `realpath` answer, and which paths were
/// asked about.
final class FakeFileSystem: ExplorerFileSystem, @unchecked Sendable {
    var directory: @Sendable (String) throws -> [DirectoryRecord] = { _ in throw FakeError() }
    var statHandler: @Sendable (String) throws -> FileStats = { _ in throw FakeError() }
    var lstatHandler: @Sendable (String) throws -> FileStats = { _ in throw FakeError() }
    var realpathHandler: @Sendable (String) throws -> String = { $0 }

    private let lock = NSLock()
    private var statPaths: [String] = []
    private var lstatPaths: [String] = []

    /// The paths asked about by `stat` and `lstat`.
    var lookedUp: [String] {
        lock.lock()
        defer { lock.unlock() }
        return statPaths + lstatPaths
    }

    func readDirectory(_ path: String) throws -> [DirectoryRecord] { try directory(path) }

    func stat(_ path: String) throws -> FileStats {
        lock.lock()
        statPaths.append(path)
        lock.unlock()
        return try statHandler(path)
    }

    func lstat(_ path: String) throws -> FileStats {
        lock.lock()
        lstatPaths.append(path)
        lock.unlock()
        return try lstatHandler(path)
    }

    func realpath(_ path: String) throws -> String { try realpathHandler(path) }
}

/// `fakeStats` of the original's tests.
func fakeStats(
    directory: Bool, file: Bool, size: Int64, symbolicLink: Bool = false, mtimeMs: Int64? = 1_704_153_600_000,
    birthtimeMs: Int64? = 1_704_067_200_000
) -> FileStats {
    FileStats(
        type: directory ? .directory : file ? .file : symbolicLink ? .symlink : .other, size: size,
        birthtimeMs: birthtimeMs, mtimeMs: mtimeMs, mode: directory ? 0o755 : 0o644)
}

/// `fakeDirent` of the original's tests.
func fakeDirent(_ name: String, directory: Bool = false, file: Bool = false, symbolicLink: Bool = false)
    -> DirectoryRecord
{
    DirectoryRecord(name: name, type: directory ? .directory : file ? .file : symbolicLink ? .symlink : .other)
}

/// `2024-01-02T00:00:00.000Z` as milliseconds.
let jan2 = 1_704_153_600_000 as Int64
