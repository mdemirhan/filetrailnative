// The reading file systems of the review's tests, given to a write service: what the original's tests give it,
// objects without the writing calls, which a paste then fails on
import Darwin
import Foundation

@testable import FTOperations

/// A file system that can only be read: each write fails with EROFS.
protocol ReadOnlyWriteFileSystem: WriteServiceFileSystem {}

extension ReadOnlyWriteFileSystem {
    private func refused(_ path: String) -> NativeError {
        NativeError.errno(EROFS, syscall: "write", path: path)
    }

    func renameExclusive(_ from: String, _ to: String) throws { throw refused(from) }
    func mkdir(_ path: String) throws { throw refused(path) }
    func rm(_ path: String, recursive: Bool, force: Bool) throws { throw refused(path) }
    func rmdir(_ path: String) throws { throw refused(path) }
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        throw refused(destination)
    }
    func getFlags(_ path: String) throws -> UInt32 { 0 }
    func setFlags(_ path: String, _ flags: UInt32) throws { throw refused(path) }
}

extension MockAnalysisFileSystem: ReadOnlyWriteFileSystem {}
