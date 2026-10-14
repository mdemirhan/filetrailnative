// Port of packages/native-fs/src/native_eject.c (nativeEjectVolume)
import Darwin
import DiskArbitration
import Dispatch
import Foundation

/// Eject, as Finder's sidebar button and File > Eject do it.
///
/// With `wholeDisk`, every volume mounted from the same physical disk is unmounted, then the disk itself is
/// ejected: a disk image is detached, a drive spun down and let go. Without it only the volume at `path` is
/// unmounted and its disk stays attached. A network share, or another mount not on a device, is unmounted
/// either way.
///
/// Unmounting goes through Disk Arbitration, which asks the apps that registered to hear of it (they may
/// refuse) and refuses itself while a file on the volume is open. `force` unmounts anyway, as Finder's Force
/// Eject does. Throws `EjectError`. Runs on a background queue: an unmount waits for the file system to
/// finish writing, and a network share that stopped answering can take long.
public enum VolumeEjector {
    /// Long enough for a slow disk to finish writing; a network share that stopped answering fails rather
    /// than holding a thread forever.
    public static let defaultTimeoutSeconds = 120

    public static func eject(
        path: String, force: Bool = false, wholeDisk: Bool = false, timeoutSeconds: Int = defaultTimeoutSeconds
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let job = EjectJob(path: path, force: force, wholeDisk: wholeDisk, timeout: timeoutSeconds)
                do {
                    try job.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The errno a Disk Arbitration status stands for. A refusal for an open file comes as
    /// unix_err(EBUSY), the system's errno wrapped.
    static func errno(ofStatus status: Int32) -> Int32 {
        if (status & ~0x3fff) == 0xc000 {
            return status & 0x3fff
        }
        switch UInt32(bitPattern: status) {
        case bits(kDAReturnBusy), bits(kDAReturnExclusiveAccess): return EBUSY
        case bits(kDAReturnNotFound): return ENOENT
        case bits(kDAReturnNotPermitted): return EPERM
        case bits(kDAReturnNotPrivileged): return EACCES
        case bits(kDAReturnNotReady): return EAGAIN
        case bits(kDAReturnUnsupported): return ENOTSUP
        default: return EIO
        }
    }

    private static func bits<T: BinaryInteger>(_ value: T) -> UInt32 { UInt32(truncatingIfNeeded: value) }
}

/// What Disk Arbitration's callback reports. The callback holds one reference of its own, so a result that
/// comes after the wait gave up lands in memory that is still there.
private final class DAResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    var reason: String?
}

private let daCallback: @convention(c) (DADisk, DADissenter?, UnsafeMutableRawPointer?) -> Void = {
    _, dissenter, context in
    guard let context else { return }
    let result = Unmanaged<DAResult>.fromOpaque(context).takeRetainedValue()
    if let dissenter {
        result.status = Int32(truncatingIfNeeded: DADissenterGetStatus(dissenter))
        result.reason = DADissenterGetStatusString(dissenter) as String?
    } else {
        result.status = 0
    }
    result.done.signal()
}

private final class EjectJob {
    let path: String
    let force: Bool
    let wholeDisk: Bool
    let timeout: Int

    init(path: String, force: Bool, wholeDisk: Bool, timeout: Int) {
        self.path = path
        self.force = force
        self.wholeDisk = wholeDisk
        self.timeout = timeout
    }

    func run() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw EjectError(errnum: EIO, path: path)
        }
        let queue = DispatchQueue(label: "filetrail.eject")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        try eject(session)
    }

    private func eject(_ session: DASession) throws {
        var mount = statfs()
        guard statfs(path, &mount) == 0, MountRecord(mount).path == path else {
            throw EjectError(errnum: ENOENT, path: path)
        }
        let record = MountRecord(mount)
        guard wholeDisk, let disk = VolumeListing.deviceDisk(of: record, PhysicalDisk.lookup(bsdName:)) else {
            try unmountVolume(session, path)
            return
        }

        // This volume first, so that a refusal names it when it is the one in use; then the rest on its
        // disk, wherever they are mounted.
        try unmountVolume(session, path)
        let others = VolumeListing.mounts().filter {
            VolumeListing.deviceDisk(of: $0, PhysicalDisk.lookup(bsdName:))?.whole == disk.whole
        }.map(\.path)
        for other in others {
            try unmountVolume(session, other)
        }
        try ejectDisk(session, disk.whole)
    }

    /// Waits for a request's callback, at most `timeout` seconds.
    private func wait(for result: DAResult, path: String) throws {
        if result.done.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            throw EjectError(errnum: ETIMEDOUT, path: path)
        }
        if result.status != 0 {
            throw EjectError(
                errnum: VolumeEjector.errno(ofStatus: result.status), path: path,
                reason: result.reason)
        }
    }

    private func unmountVolume(_ session: DASession, _ path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            // A mount Disk Arbitration doesn't know of.
            if unmount(path, force ? MNT_FORCE : 0) != 0 {
                throw EjectError(errnum: errno, path: path)
            }
            return
        }
        let result = DAResult()
        let context = Unmanaged.passRetained(result).toOpaque()
        DADiskUnmount(
            disk, DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault),
            daCallback, context)
        try wait(for: result, path: path)
    }

    private func ejectDisk(_ session: DASession, _ bsdName: String) throws {
        // Gone with its volumes (a disk image can detach on its own).
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return }
        let result = DAResult()
        let context = Unmanaged.passRetained(result).toOpaque()
        DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), daCallback, context)
        do {
            try wait(for: result, path: "/dev/\(bsdName)")
        } catch let error as EjectError where error.errnum == ENOTSUP {
            // A drive that can't be ejected is let go of once its volumes are unmounted, as Finder leaves it.
            return
        }
    }
}
