// The reading file systems of the review's tests, given to a write service: every writing call fails, so a paste
// fails on them
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
    func chmod(_ path: String, _ mode: UInt32) throws { throw refused(path) }
    func utimes(_ path: String, _ atimeMs: Double, _ mtimeMs: Double) throws { throw refused(path) }
    func copyMetadata(_ source: String, _ destination: String) throws { throw refused(destination) }
    func copyMetadataToRunInPlace(_ source: String, _ destination: String) throws { throw refused(destination) }
    func setAcl(_ path: String, _ acl: String?) throws { throw refused(path) }
    func trash(_ path: String) throws -> String? { throw refused(path) }
    func canModifyFolder(_ path: String) throws { throw refused(path) }
}

extension MockAnalysisFileSystem: ReadOnlyWriteFileSystem {}
