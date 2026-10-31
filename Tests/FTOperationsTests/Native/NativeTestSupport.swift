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

    /// The disk's whole size (`statfs` `f_blocks`).
    static func totalBytes(_ path: String) -> Int {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return 0 }
        return Int(info.f_blocks) * Int(info.f_bsize)
    }

    /// The length of the file at `path`, or -1 when there is none.
    static func size(_ path: String) -> Int {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_size) : -1
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

    /// The File Manager's volume reference number of the disk `path` is on (FSGetCatalogInfo's `volume`), or
    /// the OSErr it answered; nil when CoreServices has no such functions.
    ///
    /// The Trash finds a disk by this number. The Mac hands out one per mount, counting down from -100 at
    /// startup in 16 bits, and never takes one back. Once it has counted past -32768 (about 32,700 mounts since
    /// the Mac started: weeks of parallel test runs), a newly mounted disk gets a positive number that means no
    /// volume: FSGetCatalogInfo answers errFSBadFSRef (-1401) for it, and every Trash call on it fails with
    /// NSFileNoSuchFileError over nsvErr (-35), on any file system, mounted anywhere. Disks mounted before keep
    /// theirs; only a restart starts the count again. The functions are looked up at run time: the SDK no
    /// longer shows them to Swift.
    static func volumeReference(of path: String) -> Result<Int16, OSErrCode>? {
        typealias MakeRef =
            @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer, UnsafeMutableRawPointer?)
            -> Int32
        typealias GetCatalogInfo =
            @convention(c) (
                UnsafeRawPointer, UInt32, UnsafeMutableRawPointer, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                UnsafeMutableRawPointer?
            ) -> Int16
        guard let services = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
            let makeRef = dlsym(services, "FSPathMakeRef"), let getCatalogInfo = dlsym(services, "FSGetCatalogInfo")
        else { return nil }
        // An FSRef is 80 opaque bytes; FSCatalogInfo (packed to 2) has `volume` after the UInt16 nodeFlags.
        let fsRef = UnsafeMutableRawPointer.allocate(byteCount: 80, alignment: 8)
        let info = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer {
            fsRef.deallocate()
            info.deallocate()
        }
        info.initializeMemory(as: UInt8.self, repeating: 0, count: 512)
        let made = unsafeBitCast(makeRef, to: MakeRef.self)(path, fsRef, nil)
        guard made == 0 else { return .failure(OSErrCode(Int(made))) }
        let kFSCatInfoVolume: UInt32 = 0x0004
        let read = unsafeBitCast(getCatalogInfo, to: GetCatalogInfo.self)(fsRef, kFSCatInfoVolume, info, nil, nil, nil)
        guard read == 0 else { return .failure(OSErrCode(Int(read))) }
        return .success(info.load(fromByteOffset: 2, as: Int16.self))
    }

    /// What `volumeReference` says, in a sentence for a failing test.
    static func volumeReferenceReport(of path: String) -> String {
        switch volumeReference(of: path) {
        case .success(let number) where number < 0:
            "the File Manager knows the disk (volume reference \(number))"
        case .success(let number):
            "the File Manager gave the disk no volume (reference \(number)): restart the Mac (see TrashProbe)"
        case .failure(let code):
            "the File Manager knows no volume for the disk (\(code.value)): if the Mac mounted some 32,700 disks "
                + "since it started, restart it (see TrashProbe)"
        case nil:
            "CoreServices can't say whether the File Manager knows the disk"
        }
    }
}

struct OSErrCode: Error, Equatable {
    let value: Int
    init(_ value: Int) { self.value = value }
}
