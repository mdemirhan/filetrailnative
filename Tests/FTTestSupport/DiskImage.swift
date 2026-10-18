// Port of packages/core/src/fs/testDiskImage.ts (attach and detach approach)
import Darwin
import Foundation
import Testing

extension Tag {
    /// Tests that mount a disk image. Skipped when `FILETRAIL_NO_DISK_IMAGES=1`.
    @Tag public static var diskImage: Self
}

extension Trait where Self == ConditionTrait {
    /// Skips a test that mounts a disk image when `FILETRAIL_NO_DISK_IMAGES=1`.
    /// Use as `@Test(.tags(.diskImage), .diskImages)`.
    public static var diskImages: Self {
        .enabled(if: DiskImage.isEnabled, "disk images are disabled by FILETRAIL_NO_DISK_IMAGES=1")
    }
}

/// A small disk image mounted for the duration of a closure, for what one volume can't show:
/// other file systems, a case-sensitive disk, moving between disks.
public enum DiskImage {
    public enum Kind: String, CaseIterable, Sendable {
        case fat32
        case exfat
        case hfs
        case apfs
        case apfsCaseSensitive
        /// A 32 MB APFS disk, for tests that fill it (the original filled 20 to 32 MB disks).
        case apfsSmall
        /// A 40 MB FAT32 disk, about the smallest that is still FAT32, for tests that fill it.
        case fat32Small

        /// The blank image's name in `tools/fixtures/disk-images.sh`.
        var imageName: String {
            switch self {
            case .apfsCaseSensitive: "apfs-cs"
            case .apfsSmall: "apfs-small"
            case .fat32Small: "fat32-small"
            default: rawValue
            }
        }

        public var isCaseSensitive: Bool { self == .apfsCaseSensitive }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FILETRAIL_NO_DISK_IMAGES"] != "1"
    }

    /// Mounts a fresh clone of the blank image of `kind`, runs `body` with the volume's folder, and
    /// detaches (with force) and deletes the clone afterwards, also when `body` throws.
    ///
    /// One volume of a kind at a time, also across test processes: clones of one blank image carry the
    /// same volume UUID, and while one is attached, attaching another fails with "no mountable file
    /// systems" or mounts it under a different name. Each kind has a volume name of its own, so no
    /// volume of another kind takes this one's `/Volumes` folder while the kind's lock is held.
    ///
    /// `ownMountPoint` mounts it in a folder of its own instead of `/Volumes/<name>`, which the next
    /// clone of the kind mounted anywhere on the Mac takes once this one is unmounted: for tests that
    /// still act on the path after that.
    public static func withVolume<T>(
        _ kind: Kind, ownMountPoint: Bool = false, isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let mounted = try await Mounted.make(kind, ownMountPoint: ownMountPoint)
        defer { mounted.close() }
        return try await body(mounted.mount)
    }

    /// Runs `body` with a fresh folder of its own on a volume of `kind` that the tests of this process
    /// running at the same time share, and removes the folder afterwards. The first of them mounts the
    /// volume (in a folder of its own), and the last one to finish detaches it.
    ///
    /// For tests that need a real volume of a kind but not a whole one: nothing of the volume's own (its
    /// root, free space, Trash, mounting or ejecting) and nothing another test does in a folder of its own.
    public static func withSharedVolume<T>(
        _ kind: Kind, isolation: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> T
    ) async throws -> T {
        let volume = try await SharedVolumes.shared.join(kind)
        let folder = volume.appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        let result: Result<T, any Error>
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            result = .success(try await body(folder))
        } catch {
            result = .failure(error)
        }
        removeAll(at: folder)
        if let last = await SharedVolumes.shared.leave(kind) {
            last.close()
        }
        return try result.get()
    }

    /// A clone of a blank image, attached, with its kind's lock held until `close`.
    private final class Mounted: Sendable {
        let mount: URL
        private let lock: Int32
        private let work: TemporaryDirectory
        private let image: URL
        private let attached: Attached

        private init(lock: Int32, work: TemporaryDirectory, image: URL, attached: Attached) {
            self.mount = attached.mount
            self.lock = lock
            self.work = work
            self.image = image
            self.attached = attached
        }

        static func make(_ kind: Kind, ownMountPoint: Bool) async throws -> Mounted {
            let lock = try await acquireLock(for: kind)
            let work: TemporaryDirectory
            do {
                work = try TemporaryDirectory(prefix: "ft-disk")
            } catch {
                releaseLock(lock)
                throw error
            }
            do {
                let image = work.appending("volume.sparseimage")
                try clone(kind, to: image)
                var mountPoint: URL?
                if ownMountPoint {
                    let folder = work.appending("mount")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    mountPoint = folder
                }
                return Mounted(lock: lock, work: work, image: image, attached: try attach(image, at: mountPoint))
            } catch {
                work.remove()
                releaseLock(lock)
                throw error
            }
        }

        /// Detaches the image, deletes the clone and releases the kind's lock.
        func close() {
            detach(attached, image: image)
            work.remove()
            releaseLock(lock)
        }
    }

    /// The volumes `withSharedVolume` lends, one per kind, with how many tests are using each.
    private actor SharedVolumes {
        static let shared = SharedVolumes()

        private struct Entry {
            var users: Int
            let mounting: Task<Mounted, any Error>
        }

        private var entries: [Kind: Entry] = [:]

        func join(_ kind: Kind) async throws -> URL {
            let mounting: Task<Mounted, any Error>
            if var entry = entries[kind] {
                entry.users += 1
                entries[kind] = entry
                mounting = entry.mounting
            } else {
                mounting = Task { try await Mounted.make(kind, ownMountPoint: true) }
                entries[kind] = Entry(users: 1, mounting: mounting)
            }
            do {
                return try await mounting.value.mount
            } catch {
                _ = await leave(kind)
                throw error
            }
        }

        /// The volume for the caller to close when it was its last user.
        func leave(_ kind: Kind) async -> Mounted? {
            guard var entry = entries[kind] else { return nil }
            entry.users -= 1
            guard entry.users == 0 else {
                entries[kind] = entry
                return nil
            }
            entries[kind] = nil
            return try? await entry.mounting.value
        }
    }

    /// Clears the Locked flag and gives the owner write access everywhere in `folder`, then removes it.
    private static func removeAll(at folder: URL) {
        let path = folder.path
        let paths = (FileManager.default.subpaths(atPath: path) ?? []).map { path + "/" + $0 }
        for item in [path] + paths {
            lchflags(item, 0)
            var info = stat()
            if lstat(item, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR {
                chmod(item, (info.st_mode & 0o7777) | S_IRWXU)
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Takes an exclusive `flock` on a file next to the blank images, polling so no thread is blocked.
    private static func acquireLock(for kind: Kind) async throws -> Int32 {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let path = cacheDirectory.appendingPathComponent("\(kind.imageName).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure(description: "cannot open \(path): errno \(errno)") }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                close(descriptor)
                throw Failure(description: "cannot lock \(path): errno \(errno)")
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch {
                close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    private static func releaseLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The blank images of the tests (not the parity goldens' 256 MB ones beside them, which share volume
    /// names between kinds).
    private static var cacheDirectory: URL {
        let base =
            ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches/filetrail-port")
        return base.appendingPathComponent("fixtures/disks/tests")
    }

    private static func clone(_ kind: Kind, to destination: URL) throws {
        let source = cacheDirectory.appendingPathComponent("\(kind.imageName).sparseimage")
        if !FileManager.default.fileExists(atPath: source.path) {
            // First use on this machine: make the blank images.
            let script = repositoryRoot.appendingPathComponent("tools/fixtures/disk-images.sh")
            _ = try run("/bin/bash", [script.path])
        }
        // copyItem on APFS clones the file (copy on write), the same as `cp -c`.
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private struct Attached: Sendable {
        let mount: URL
        /// The whole-disk device (`/dev/diskN`), which detaches every volume of the image.
        let device: String
    }

    private static func attach(_ image: URL, at mountPoint: URL?) throws -> Attached {
        let output = try run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-noautoopen", "-plist"] + (mountPoint.map { ["-mountpoint", $0.path] } ?? [])
                + [image.path])
        guard
            let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first,
            let slice = entities.first(where: { $0["mount-point"] != nil })?["dev-entry"] as? String
        else { throw Failure(description: "hdiutil attach reported no mount point for \(image.path)") }
        // realpath'd, so paths the code under test reports match ours. Not with resolvingSymlinksInPath,
        // which takes /private off a mount point of its own (/private/var/folders/...), where the volume
        // is mounted.
        return Attached(mount: URL(fileURLWithPath: realPath(mountPoint)), device: wholeDisk(of: slice))
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `/dev/disk4s1` -> `/dev/disk4`.
    private static func wholeDisk(of slice: String) -> String {
        guard let range = slice.range(of: #"^/dev/disk[0-9]+"#, options: .regularExpression) else { return slice }
        return String(slice[range])
    }

    /// Detaches by device (a path can be busy), forcing on the retries, and returns once the image
    /// is no longer attached, so the clone can be deleted.
    ///
    /// Only while the image is still attached: once it is detached (a test may eject it itself), its
    /// `/dev/diskN` is the next attach's, in any process on the Mac, and detaching it would take another
    /// test's disk away. For the same reason it waits on the image, not on its mount point, which the next
    /// clone of the kind may take.
    private static func detach(_ attached: Attached, image: URL) {
        for attempt in 0..<3 {
            guard isAttached(image, device: attached.device) != false else { return }
            let force = attempt > 0
            _ = try? run("/usr/bin/hdiutil", ["detach"] + (force ? ["-force"] : []) + [attached.device])
            if waitUntilDetached(image, timeout: 30) { return }
        }
    }

    private static func waitUntilDetached(_ image: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isAttached(image) == false { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    /// Whether `image` is attached (with `device` among its devices, when given); nil when hdiutil
    /// couldn't say.
    private static func isAttached(_ image: URL, device: String? = nil) -> Bool? {
        guard let data = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { return nil }
        let real = image.resolvingSymlinksInPath().path
        return images.contains { entry in
            guard let path = entry["image-path"] as? String,
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path == real
            else { return false }
            guard let device else { return true }
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            return entities.contains { $0["dev-entry"] as? String == device }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting, so a full pipe can't stall the tool.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw Failure(description: "\(tool) \(arguments.first ?? "") failed: \(message)")
        }
        return data
    }
}
