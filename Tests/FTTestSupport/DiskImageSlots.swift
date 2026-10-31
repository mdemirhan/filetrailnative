// The slots a test's disk image takes on this Mac: a small pool of file locks for each kind of image
import Darwin
import Foundation

/// A small pool of slots for each kind of disk image, shared by every test process on this Mac: an image is
/// attached only while its test holds one, which bounds how many are attached at once, while tests of one kind in
/// different suites or processes run side by side.
///
/// A slot is an exclusive `flock` on `<kind>.lock` (the first, the one earlier versions took for the whole kind),
/// `<kind>-2.lock`, … under the port's cache, taken by polling, so no thread is blocked.
public enum DiskImageSlots {
    /// How many images of a kind may be attached at once (`FILETRAIL_DISK_IMAGE_SLOTS`, 2 by default).
    public static var perKind: Int {
        ProcessInfo.processInfo.environment["FILETRAIL_DISK_IMAGE_SLOTS"].flatMap { Int($0) }.map { max(1, $0) } ?? 2
    }

    /// Takes a free slot of `kind` in `directory`, waiting for one while all `slots` are taken. Returns the lock's
    /// descriptor, for `release`.
    public static func acquire(
        _ kind: String, slots: Int = perKind, in directory: URL = lockDirectory
    ) async throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptors = try (1...max(1, slots)).map { slot -> Int32 in
            let path = directory.appendingPathComponent(slot == 1 ? "\(kind).lock" : "\(kind)-\(slot).lock").path
            let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw DiskImage.Failure(description: "cannot open \(path): errno \(errno)") }
            return descriptor
        }
        func closeAll(but kept: Int32? = nil) {
            for descriptor in descriptors where descriptor != kept { close(descriptor) }
        }
        while true {
            for descriptor in descriptors {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    closeAll(but: descriptor)
                    return descriptor
                }
                guard errno == EWOULDBLOCK else {
                    let failure = DiskImage.Failure(description: "cannot lock a slot of \(kind): errno \(errno)")
                    closeAll()
                    throw failure
                }
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch {
                closeAll()
                throw error
            }
        }
    }

    public static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Where the slots' locks are (beside the blank images earlier versions cloned, so a test process of an earlier
    /// version takes the first slot's lock).
    public static var lockDirectory: URL {
        let base =
            ProcessInfo.processInfo.environment["FILETRAIL_DEV_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches/filetrail-dev")
        return base.appendingPathComponent("fixtures/disks/tests")
    }
}
