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
///
/// Several test processes run on this Mac at once, so every image is made fresh, with a volume name
/// of its own (`FT<kind letter><pid>-<n>`) and a volume UUID of its own (clones of one blank image share
/// theirs): no test finds another process's volume under the name it expects, and no volume is
/// mounted as "<name> 1" beside one of the same name. Its mount point is the one hdiutil reports for
/// its own device.
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

        /// The format's name in `tools/fixtures/disk-images.sh` and the parity scenarios.
        var imageName: String {
            switch self {
            case .apfsCaseSensitive: "apfs-cs"
            case .apfsSmall: "apfs-small"
            case .fat32Small: "fat32-small"
            default: rawValue
            }
        }

        /// `hdiutil create -fs`.
        var fileSystem: String {
            switch self {
            case .fat32, .fat32Small: "MS-DOS FAT32"
            case .exfat: "ExFAT"
            case .hfs: "Journaled HFS+"
            case .apfs, .apfsSmall: "APFS"
            case .apfsCaseSensitive: "Case-sensitive APFS"
            }
        }

        /// The disk's size. 40 MB is about the smallest disk newfs_msdos still makes FAT32 (it needs
        /// 65,525 clusters).
        var megabytes: Int {
            switch self {
            case .apfsSmall: 32
            case .fat32Small: 40
            default: 256
            }
        }

        /// The letter that tells the kind in a volume name (FAT and exFAT names are at most 11 characters).
        var letter: String {
            switch self {
            case .fat32: "F"
            case .fat32Small: "G"
            case .exfat: "X"
            case .hfs: "H"
            case .apfs: "A"
            case .apfsCaseSensitive: "C"
            case .apfsSmall: "S"
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

    /// Mounts a fresh image of `kind`, runs `body` with the volume's folder, and detaches (with force)
    /// and deletes the image afterwards, also when `body` throws.
    ///
    /// At most `DiskImageSlots.perKind` volumes of a kind at a time on this Mac, across test processes (a pool
    /// of file locks): it bounds how many images are attached at once, while tests of one kind in different
    /// suites or processes don't wait for each other.
    ///
    /// `ownMountPoint` mounts it in a folder of its own instead of `/Volumes/<name>`.
    public static func withVolume<T>(
        _ kind: Kind, ownMountPoint: Bool = false, isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let mounted = try await Mounted.make(kind, ownMountPoint: ownMountPoint)
        let result: Result<T, any Error>
        do {
            result = .success(try await body(mounted.mount))
        } catch {
            result = .failure(error)
        }
        await offCallersActor { mounted.close() }
        return try result.get()
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
        await offCallersActor { removeAll(at: folder) }
        if let last = await SharedVolumes.shared.leave(kind) {
            await offCallersActor { last.close() }
        }
        return try result.get()
    }

    /// A fresh image, attached, with a slot of its kind held until `close`.
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
            let (work, image) = try await offCallersActor { () throws -> (TemporaryDirectory, URL) in
                detachLeftoversOnce()
                // The process id in the folder's name tells a later run whose image it was (detachLeftovers).
                let work = try TemporaryDirectory(prefix: "\(workPrefix)-pid\(getpid())")
                let image = work.appending("volume.sparseimage")
                do {
                    // Made before the lock is taken: making an image takes a second or two.
                    try makeImage(kind, at: image)
                } catch {
                    work.remove()
                    throw error
                }
                return (work, image)
            }
            let lock: Int32
            do {
                lock = try await DiskImageSlots.acquire(kind.imageName)
            } catch {
                work.remove()
                throw error
            }
            do {
                let attached = try await offCallersActor {
                    var mountPoint: URL?
                    if ownMountPoint {
                        let folder = work.appending("mount")
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        mountPoint = folder
                    }
                    return try attach(image, at: mountPoint)
                }
                StillAttached.shared.add(attached, image: image, work: work)
                return Mounted(lock: lock, work: work, image: image, attached: attached)
            } catch {
                work.remove()
                DiskImageSlots.release(lock)
                throw error
            }
        }

        /// Detaches the image, deletes it and releases its slot. An image that wouldn't detach is
        /// kept, with its folder, for the process's exit to try again (and the next run after that).
        func close() {
            if detach(attached, image: image) {
                StillAttached.shared.remove(attached)
                work.remove()
            }
            DiskImageSlots.release(lock)
        }
    }

    /// Images this process attached and hasn't detached yet, detached when it exits, so a test that
    /// failed or a detach that gave up leaves nothing mounted.
    private final class StillAttached: @unchecked Sendable {
        static let shared = StillAttached()

        private struct Entry {
            let attached: Attached
            let image: URL
            let work: TemporaryDirectory
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var exitHookInstalled = false

        func add(_ attached: Attached, image: URL, work: TemporaryDirectory) {
            lock.lock()
            defer { lock.unlock() }
            entries[attached.device] = Entry(attached: attached, image: image, work: work)
            if !exitHookInstalled {
                exitHookInstalled = true
                atexit { DiskImage.StillAttached.shared.detachAll() }
            }
        }

        func remove(_ attached: Attached) {
            lock.lock()
            defer { lock.unlock() }
            entries[attached.device] = nil
        }

        func detachAll() {
            lock.lock()
            let all = entries.values
            entries = [:]
            lock.unlock()
            for entry in all {
                if DiskImage.detach(entry.attached, image: entry.image) { entry.work.remove() }
            }
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

    /// Runs `work`, which blocks for as long as hdiutil takes (seconds on a busy Mac), on a thread of its own: never
    /// on the caller's actor, where it would stall every other test of a `@MainActor` suite running alongside, nor
    /// in Swift's shared pool, whose few threads every async test needs.
    private static func offCallersActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try work() }) }.start()
        }
    }

    private static func offCallersActor(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            Thread {
                work()
                continuation.resume()
            }.start()
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

    // MARK: - Making and attaching images

    /// The prefix of the folders that hold a test's image (`ft-disk-pid<pid>-<uuid>`).
    static let workPrefix = "ft-disk"

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0

        func take() -> Int {
            lock.lock()
            defer { lock.unlock() }
            next += 1
            return next
        }
    }

    private static let volumeCount = Counter()

    /// `FT<kind letter><pid>-<n>`, at most 11 characters (a FAT name's limit): no volume of another
    /// process, or of this one, has it while this image is attached.
    static func uniqueVolumeName(_ kind: Kind) -> String {
        let count = String(volumeCount.take() % (36 * 36), radix: 36, uppercase: true)
        return "FT\(kind.letter)\(getpid())-\(count)"
    }

    /// Makes a blank sparse image of `kind` at `path`, with a volume name of its own.
    static func makeImage(_ kind: Kind, at path: URL) throws {
        let arguments = [
            "create", "-quiet", "-type", "SPARSE", "-size", "\(kind.megabytes)m", "-fs", kind.fileSystem,
            "-volname", uniqueVolumeName(kind), path.path,
        ]
        var lastError: (any Error)?
        for attempt in 0..<3 {
            if attempt > 0 {
                try? FileManager.default.removeItem(at: path)
                Thread.sleep(forTimeInterval: 1)
            }
            do {
                _ = try run("/usr/bin/hdiutil", arguments)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Failure(description: "hdiutil create failed for \(path.path)")
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
            let volume = entities.first(where: { $0["mount-point"] is String && $0["dev-entry"] is String }),
            let mountPoint = volume["mount-point"] as? String,
            let slice = volume["dev-entry"] as? String
        else {
            throw Failure(description: "hdiutil attach reported no mount point for \(image.path)")
        }
        // realpath'd, so paths the code under test reports match ours. Not with resolvingSymlinksInPath,
        // which takes /private off a mount point of its own (/private/var/folders/...), where the volume
        // is mounted.
        let attached = Attached(mount: URL(fileURLWithPath: realPath(mountPoint)), device: wholeDisk(of: slice))
        // The folder is this image's volume: mounted from the device hdiutil gave it.
        guard mountedFrom(attached.mount.path) == slice else {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-force", attached.device])
            throw Failure(
                description: "\(attached.mount.path) is not mounted from \(slice), which hdiutil attached it from")
        }
        return attached
    }

    /// The device the volume at `path` is mounted from (`/dev/disk4s1`); nil when nothing is there.
    private static func mountedFrom(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
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
    /// is no longer attached, so it can be deleted. False when it is still attached.
    ///
    /// Only while the image is still attached: once it is detached (a test may eject it itself), its
    /// `/dev/diskN` is the next attach's, in any process on the Mac, and detaching it would take another
    /// test's disk away. For the same reason it waits on the image, not on its mount point.
    ///
    /// `hdiutil info` now and then leaves out an image that is attached while the Mac is busy (one listing
    /// has it, the next doesn't, with nothing detaching it). So a volume still mounted at its mount point
    /// from its own device counts as attached too: its mount point is its own while it is mounted.
    private static func detach(_ attached: Attached, image: URL) -> Bool {
        for attempt in 0..<3 {
            guard isAttached(image, device: attached.device) != false || isMounted(attached) else { return true }
            let force = attempt > 0
            _ = try? run("/usr/bin/hdiutil", ["detach"] + (force ? ["-force"] : []) + [attached.device])
            if waitUntilDetached(attached, image: image, timeout: 30) { return true }
        }
        return false
    }

    private static func waitUntilDetached(_ attached: Attached, image: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isAttached(image) == false && !isMounted(attached) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    /// Whether the volume is still mounted at its mount point from a slice of its device.
    private static func isMounted(_ attached: Attached) -> Bool {
        mountedFrom(attached.mount.path).map(wholeDisk(of:)) == attached.device
    }

    /// Whether `image` is attached (with `device` among its devices, when given); nil when hdiutil
    /// couldn't say.
    private static func isAttached(_ image: URL, device: String? = nil) -> Bool? {
        guard let images = attachedImages() else { return nil }
        let real = image.resolvingSymlinksInPath().path
        return images.contains { entry in
            guard URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path == real else { return false }
            guard let device else { return true }
            return entry.devices.contains(device)
        }
    }

    /// Every attached image with its devices (`hdiutil info`); nil when hdiutil couldn't say.
    private static func attachedImages() -> [(path: String, devices: [String])]? {
        guard let data = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { return nil }
        return images.compactMap { entry in
            guard let path = entry["image-path"] as? String else { return nil }
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            return (path, entities.compactMap { $0["dev-entry"] as? String })
        }
    }

    // MARK: - Leftovers of earlier runs

    private static let leftoversDetached: Void = detachLeftovers()

    /// Detaches the images of earlier runs, once per process, before its first image is attached.
    static func detachLeftoversOnce() {
        _ = leftoversDetached
    }

    /// The prefixes of the folders that hold test images: DiskImage's and ExecDiskImages'.
    private static let leftoverPrefixes = [workPrefix, ExecDiskImages.folderPrefix]

    /// How long a folder must have been there to count as left over.
    private static let leftoverAge: TimeInterval = 3 * 60

    /// Detaches the images a test process that is gone left attached (it was killed, or its detach gave
    /// up), and removes their folders: a folder `<prefix>-pid<pid>-<uuid>` older than a few minutes whose
    /// process is gone. Folders of earlier versions name no process (`<prefix>-<uuid>`): their images
    /// count as left over once the image file is gone (its test gave up detaching it and deleted it) or
    /// after an hour.
    static func detachLeftovers() {
        let temporary = realPath(NSTemporaryDirectory())
        for image in attachedImages() ?? [] {
            let folder = (image.path as NSString).deletingLastPathComponent
            guard isLeftover(folder: folder, image: image.path) else { continue }
            for device in Set(image.devices.map(wholeDisk(of:))) {
                // Asked again right before: a device that is no longer this image's is another disk's now.
                guard isAttached(URL(fileURLWithPath: image.path), device: device) == true else { continue }
                _ = try? run("/usr/bin/hdiutil", ["detach", "-force", device])
            }
            if realPath((folder as NSString).deletingLastPathComponent) == temporary {
                removeAll(at: URL(fileURLWithPath: folder))
            }
        }
        // Folders whose images are gone already.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary)) ?? []
        for name in names where Owner(folderName: name) != nil {
            let folder = temporary + "/" + name
            if isLeftover(folder: folder, image: nil) {
                // `hdiutil info` leaves out an attached image now and then while the Mac is busy (see `detach`), so
                // the list above may not have had it: its own mount point still says it is there.
                if let device = deviceMounted(on: folder + "/mount") {
                    _ = try? run("/usr/bin/hdiutil", ["detach", "-force", wholeDisk(of: device)])
                }
                removeAll(at: URL(fileURLWithPath: folder))
            }
        }
    }

    /// The device of a volume mounted on exactly `path`; nil when `path` is only a folder of the disk it is on.
    private static func deviceMounted(on path: String) -> String? {
        var info = statfs()
        let real = realPath(path)
        guard statfs(real, &info) == 0,
            withUnsafeBytes(of: &info.f_mntonname, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == real
        else { return nil }
        return withUnsafeBytes(of: &info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func isLeftover(folder: String, image: String?) -> Bool {
        guard let owner = Owner(folderName: (folder as NSString).lastPathComponent) else { return false }
        let age = (try? FileManager.default.attributesOfItem(atPath: folder)[.creationDate] as? Date)
            .map { -$0.timeIntervalSinceNow }
        switch owner {
        case .process(let pid):
            guard pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { return false }
            return age.map { $0 > leftoverAge } ?? true
        case .unnamed:
            if let image, !FileManager.default.fileExists(atPath: image) { return true }
            return age.map { $0 > 60 * 60 } ?? false
        }
    }

    /// Who made a folder of test images: `<prefix>-pid<pid>-<uuid>`, or `<prefix>-<uuid>` from an earlier
    /// version, which names no process.
    private enum Owner {
        case process(pid_t)
        case unnamed

        init?(folderName name: String) {
            guard let prefix = leftoverPrefixes.first(where: { name.hasPrefix($0 + "-") }) else { return nil }
            let rest = name.dropFirst(prefix.count + 1)
            guard rest.hasPrefix("pid") else {
                self = .unnamed
                return
            }
            let digits = rest.dropFirst(3).prefix { $0.isASCII && $0.isNumber }
            guard let pid = pid_t(digits), rest.dropFirst(3 + digits.count).first == "-" else {
                self = .unnamed
                return
            }
            self = .process(pid)
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
