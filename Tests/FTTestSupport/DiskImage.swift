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

        /// The blank image's name in `tools/fixtures/disk-images.sh`.
        var imageName: String { self == .apfsCaseSensitive ? "apfs-cs" : rawValue }

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
    /// systems" or mounts it under a different name.
    public static func withVolume<T>(
        _ kind: Kind, isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let lock = try await acquireLock(for: kind)
        defer { releaseLock(lock) }
        let work = try TemporaryDirectory(prefix: "ft-disk")
        defer { work.remove() }
        let image = work.appending("volume.sparseimage")
        try clone(kind, to: image)
        let attached = try attach(image)
        defer { detach(attached, image: image) }
        return try await body(attached.mount)
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

    private static var cacheDirectory: URL {
        let base =
            ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches/filetrail-port")
        return base.appendingPathComponent("fixtures/disks")
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

    private struct Attached {
        let mount: URL
        /// The whole-disk device (`/dev/diskN`), which detaches every volume of the image.
        let device: String
    }

    private static func attach(_ image: URL) throws -> Attached {
        let output = try run(
            "/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-plist", image.path])
        guard
            let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first,
            let slice = entities.first(where: { $0["mount-point"] != nil })?["dev-entry"] as? String
        else { throw Failure(description: "hdiutil attach reported no mount point for \(image.path)") }
        // realpath'd, so paths the code under test reports match ours.
        return Attached(
            mount: URL(fileURLWithPath: mountPoint).resolvingSymlinksInPath(), device: wholeDisk(of: slice))
    }

    /// `/dev/disk4s1` -> `/dev/disk4`.
    private static func wholeDisk(of slice: String) -> String {
        guard let range = slice.range(of: #"^/dev/disk[0-9]+"#, options: .regularExpression) else { return slice }
        return String(slice[range])
    }

    /// Detaches by device (a path can be busy), forcing on the retries, and returns once the image
    /// is no longer attached and its mount point is gone, so the clone can be deleted.
    private static func detach(_ attached: Attached, image: URL) {
        for attempt in 0..<3 {
            let force = attempt > 0
            _ = try? run("/usr/bin/hdiutil", ["detach"] + (force ? ["-force"] : []) + [attached.device])
            if waitUntilGone(attached, image: image, timeout: 30) { return }
        }
    }

    private static func waitUntilGone(_ attached: Attached, image: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isAttached(image) && !FileManager.default.fileExists(atPath: attached.mount.path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    private static func isAttached(_ image: URL) -> Bool {
        guard let data = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { return false }
        let real = image.resolvingSymlinksInPath().path
        return images.contains { entry in
            guard let path = entry["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == real
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
