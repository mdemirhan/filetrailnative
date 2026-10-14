// Helpers of packages/native-fs/src/native-fs.test.ts: fillDisk, waitForSync, and files made byte by byte
import Darwin
import Foundation

@testable import FTOperations

enum NativeTestFiles {
    struct WriteFailure: Error {
        let errnum: Int32
        var code: String { NativeErrno.name(of: errnum) }
    }

    /// `writeFileSync`: creates or truncates the file and writes `bytes`, also to a named fork
    /// ("file/..namedfork/rsrc").
    static func write(_ path: String, _ bytes: [UInt8]) throws(WriteFailure) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw WriteFailure(errnum: errno) }
        defer { close(descriptor) }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard written > 0 else { throw WriteFailure(errnum: errno) }
            offset += written
        }
    }

    static func write(_ path: String, _ text: String) throws {
        try write(path, Array(text.utf8))
    }

    static func read(_ path: String) -> [UInt8]? {
        FileManager.default.contents(atPath: path).map(Array.init)
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// `/usr/sbin/mkfile <megabytes>m path`: a file of zeros, written out (not sparse).
    static func makeFile(_ path: String, megabytes: Int) throws {
        let chunk = [UInt8](repeating: 0, count: 1024 * 1024)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw WriteFailure(errnum: errno) }
        defer { close(descriptor) }
        for _ in 0..<megabytes {
            let written = chunk.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard written == chunk.count else { throw WriteFailure(errnum: errno) }
        }
    }

    /// Fills a disk until a write of even 64 KB no longer fits, and says how the disk told it was full: ENOSPC,
    /// or another of `fullCodes` for a disk that says it otherwise.
    @discardableResult
    static func fillDisk(_ mountPath: String, fullCodes: [String] = ["ENOSPC"]) throws -> String {
        var count = 0
        var fullCode = "ENOSPC"
        for chunkSize in [1024 * 1024, 64 * 1024] {
            let chunk = [UInt8](repeating: 1, count: chunkSize)
            while true {
                let path = mountPath + "/fill-\(count)"
                count += 1
                do {
                    try write(path, chunk)
                } catch {
                    unlink(path)
                    guard fullCodes.contains(error.code) else { throw error }
                    fullCode = error.code
                    break
                }
            }
        }
        return fullCode
    }

    /// The bytes the disk says are free (`statfs` `f_bavail`).
    static func freeBytes(_ path: String) -> Int {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return 0 }
        return Int(info.f_bavail) * Int(info.f_bsize)
    }

    /// `waitForSync`: watched without yielding, so a busy machine can't delay what follows.
    static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw OperationError("Timed out waiting for the condition.")
            }
        }
    }

    static func setXattr(_ path: String, _ name: String, _ value: String) -> Int32 {
        let bytes = Array(value.utf8)
        return setxattr(path, name, bytes, bytes.count, 0, 0)
    }

    static func xattrNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        _ = listxattr(path, &buffer, size, 0)
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}

/// Runs a closure on a thread of its own and lets the test wait for it, as the original's copies run on the
/// libuv pool while the test watches the disk.
final class Background<T: Sendable>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<T, any Error>?

    init(_ body: @escaping @Sendable () throws -> T) {
        Thread.detachNewThread { [self] in
            result = Result { try body() }
            done.signal()
        }
    }

    func wait() throws -> T {
        done.wait()
        guard let result else { throw OperationError("no result") }
        return try result.get()
    }
}

/// /dev answers the Trash with NSFeatureUnsupportedError only until the process has moved something to the
/// Trash; then with a bare NSFileWriteUnknownError. The original runs that case first in its file. Here every test
/// of this target that calls the real Trash touches `devNull` first, so the /dev case is always the process's
/// first Trash call, whatever order the tests run in.
enum TrashProbe {
    /// nil when running as root, who could move /dev/null (the original skips the case then).
    static let devNull: Result<String?, any Error>? =
        getuid() == 0 ? nil : Result { try NativeFS.trashItem("/dev/null") }

    static func touch() {
        _ = devNull
    }
}
